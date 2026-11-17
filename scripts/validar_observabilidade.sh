#!/usr/bin/env bash
# Valida a observabilidade da Fase 4 no cluster kind, depois do smoke test (scripts/smoke_test_e2e.sh):
#   - Grafana: os 4 dashboards da oficina carregados e cada painel com dados no Prometheus;
#   - Prometheus: alvos dos 3 servicos e do RabbitMQ UP e ao menos uma Saga concluida;
#   - Jaeger: os 3 servicos reportando spans e um trace que atravessa OS, Execution e Billing pelo RabbitMQ.
# Grava as evidencias (resultados por painel, trace em JSON e resumo em Markdown) em OUT_DIR.
# Requer kubectl, curl e python3.
set -euo pipefail

usage() {
  cat <<EOF
Uso: scripts/validar_observabilidade.sh

Variaveis de ambiente:
  OUT_DIR           Diretorio das evidencias (padrao: ./evidencias-observabilidade)
  TIMEOUT           Espera maxima ate os paineis terem dados, em segundos (padrao: 300)
  GRAFANA_USUARIO   Usuario do Grafana (padrao: admin, perfil kind)
  GRAFANA_SENHA     Senha do Grafana (padrao: admin, perfil kind)
  CAPTURAR_TELAS    "true" para salvar telas dos dashboards e do trace em OUT_DIR/telas
                    (requer node e o pacote playwright com Chromium no NODE_PATH; padrao: false)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

OUT_DIR="${OUT_DIR:-$PWD/evidencias-observabilidade}"
TIMEOUT="${TIMEOUT:-300}"
GRAFANA_USUARIO="${GRAFANA_USUARIO:-admin}"
GRAFANA_SENHA="${GRAFANA_SENHA:-admin}"
CAPTURAR_TELAS="${CAPTURAR_TELAS:-false}"
PIDS=()

log() { echo "[observabilidade] $*"; }
falhar() { echo "[observabilidade] FALHA: $*" >&2; exit 1; }

for cmd in kubectl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || falhar "comando '$cmd' e obrigatorio e nao foi encontrado."
done

encerrar() {
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
}
trap encerrar EXIT

# port_forward <namespace> <service> <porta-local> <porta-do-service> <caminho-de-health>
port_forward() {
  local namespace="$1" servico="$2" porta_local="$3" porta_servico="$4" health="$5"
  kubectl -n "$namespace" port-forward "svc/$servico" "$porta_local:$porta_servico" >/dev/null 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 30); do
    curl -fsS -o /dev/null "http://127.0.0.1:$porta_local$health" 2>/dev/null && return 0
    sleep 1
  done
  falhar "port-forward para $namespace/$servico nao respondeu"
}

mkdir -p "$OUT_DIR"
port_forward monitoring kube-prometheus-stack-prometheus 19090 9090 /-/ready
port_forward monitoring kube-prometheus-stack-grafana 13000 80 /api/health
port_forward plataforma jaeger 26686 16686 /

log "consultando Grafana, Prometheus e Jaeger (evidencias em $OUT_DIR)"
STATUS=0
PROMETHEUS_URL="http://127.0.0.1:19090" \
  GRAFANA_URL="http://127.0.0.1:13000" \
  JAEGER_URL="http://127.0.0.1:26686" \
  GRAFANA_USUARIO="$GRAFANA_USUARIO" \
  GRAFANA_SENHA="$GRAFANA_SENHA" \
  OUT_DIR="$OUT_DIR" \
  TIMEOUT="$TIMEOUT" \
  python3 - <<'PY' || STATUS=$?
import base64, json, os, re, sys, time, urllib.parse, urllib.request

PROMETHEUS = os.environ["PROMETHEUS_URL"]
GRAFANA = os.environ["GRAFANA_URL"]
JAEGER = os.environ["JAEGER_URL"]
OUT_DIR = os.environ["OUT_DIR"]
TIMEOUT = int(os.environ["TIMEOUT"])
AUTH = "Basic " + base64.b64encode(
    f'{os.environ["GRAFANA_USUARIO"]}:{os.environ["GRAFANA_SENHA"]}'.encode()).decode()

DASHBOARDS = ["oficina-overview", "oficina-saga", "oficina-execution", "oficina-billing"]
SERVICOS = ["oficina", "oficina-execution-service", "oficina-billing-service"]
ALVOS = {
    "OS Service": 'up{job="oficina-app"}',
    "Execution Service": 'up{service="oficina-execution-service"}',
    "Billing Service": 'up{service="oficina-billing-service"}',
    "RabbitMQ": 'up{job="rabbitmq"}',
}
# Paineis de falha ficam vazios enquanto nada falha (o caminho feliz do smoke test nao gera essas series).
VAZIO_ESPERADO = re.compile(r"notificacoes_falhas|sagas_compensadas|falha_compensacao")

resumo = ["# Validação de observabilidade (kind)", ""]
erros = []


def get_json(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def prometheus(expr):
    url = f"{PROMETHEUS}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    return get_json(url)["data"]["result"]


def salvar(nome, conteudo):
    with open(os.path.join(OUT_DIR, nome), "w", encoding="utf-8") as f:
        json.dump(conteudo, f, ensure_ascii=False, indent=2)


def paineis(painel_lista):
    for p in painel_lista:
        yield from paineis(p.get("panels", []))
        for alvo in p.get("targets", []):
            if alvo.get("expr"):
                yield p.get("title", "?"), alvo["expr"]


# 1. Dashboards carregados no Grafana (pelo sidecar) e suas consultas
consultas = []
for uid in DASHBOARDS:
    try:
        dashboard = get_json(f"{GRAFANA}/api/dashboards/uid/{uid}", {"Authorization": AUTH})["dashboard"]
    except Exception as exc:  # noqa: BLE001
        erros.append(f"dashboard {uid} não encontrado no Grafana ({exc})")
        continue
    for titulo, expr in paineis(dashboard.get("panels", [])):
        consultas.append((dashboard["title"], titulo, expr))

# 2. Paineis com dados: as janelas de rate/increase precisam de algumas coletas apos o smoke test
fim = time.time() + TIMEOUT
while True:
    resultados = [(d, t, e, prometheus(e)) for d, t, e in consultas]
    pendentes = [r for r in resultados if not r[3] and not VAZIO_ESPERADO.search(r[2])]
    concluidas = sum(float(s["value"][1]) for s in prometheus("oficina_sagas_concluidas_total"))
    if (not pendentes and concluidas >= 1) or time.time() >= fim:
        break
    print(f"[observabilidade] aguardando dados: {len(pendentes)} painel(is) vazio(s), sagas concluidas={concluidas:g}",
          flush=True)
    time.sleep(15)

salvar("paineis_prometheus.json", [
    {"dashboard": d, "painel": t, "expr": e, "series": len(r), "resultado": r} for d, t, e, r in resultados])
resumo += ["## Grafana: painéis", "", "| Dashboard | Painel | Séries | Situação |", "|---|---|---|---|"]
for d, t, e, r in resultados:
    if r:
        situacao = "OK"
    elif VAZIO_ESPERADO.search(e):
        situacao = "sem dados (esperado: nenhuma falha)"
    else:
        situacao = "SEM DADOS"
        erros.append(f"painel sem dados: {d} / {t} ({e})")
    resumo.append(f"| {d} | {t} | {len(r)} | {situacao} |")
if concluidas < 1:
    erros.append("oficina_sagas_concluidas_total não registrou a Saga do smoke test")

# 3. Alvos do Prometheus
resumo += ["", "## Prometheus: alvos e Saga", "", "| Alvo | Situação |", "|---|---|"]
for nome, expr in ALVOS.items():
    series = prometheus(expr)
    ok = bool(series) and all(s["value"][1] == "1" for s in series)
    resumo.append(f"| {nome} (`{expr}`) | {'UP' if ok else 'DOWN/ausente'} ({len(series)} instância(s)) |")
    if not ok:
        erros.append(f"alvo {nome} não está UP")
resumo.append(f"| Sagas concluídas (`oficina_sagas_concluidas_total`) | {concluidas:g} |")

# 4. Jaeger: servicos e um trace que atravessa os 3 servicos
servicos_jaeger = get_json(f"{JAEGER}/api/services").get("data") or []
resumo += ["", "## Jaeger: traces", "", f"Serviços com spans: {', '.join(sorted(servicos_jaeger))}", ""]
for servico in SERVICOS:
    if servico not in servicos_jaeger:
        erros.append(f"serviço {servico} sem spans no Jaeger")

melhor = None
for servico in SERVICOS:
    if servico not in servicos_jaeger:
        continue
    url = f"{JAEGER}/api/traces?" + urllib.parse.urlencode({"service": servico, "lookback": "1h", "limit": 200})
    for trace in get_json(url).get("data") or []:
        nomes = {p["serviceName"] for p in trace["processes"].values()}
        chave = (len(nomes & set(SERVICOS)), len(trace["spans"]))
        if melhor is None or chave > melhor[0]:
            melhor = (chave, trace, nomes)

if melhor is None:
    erros.append("nenhum trace encontrado no Jaeger")
else:
    (_, total_spans), trace, nomes = melhor
    processos = trace["processes"]
    salvar("trace_jaeger.json", {"data": [trace]})
    resumo.append(f"Trace com mais serviços: `{trace['traceID']}`, {total_spans} spans, serviços: "
                  f"{', '.join(sorted(nomes))}")
    resumo += ["", "| Serviço | Operação |", "|---|---|"]
    for span in sorted(trace["spans"], key=lambda s: s["startTime"])[:40]:
        resumo.append(f"| {processos[span['processID']]['serviceName']} | {span['operationName']} |")
    if not set(SERVICOS) <= nomes:
        erros.append(f"nenhum trace atravessa os 3 serviços (o melhor tem {', '.join(sorted(nomes))})")

resumo += ["", "## Resultado", ""]
resumo += [f"- FALHA: {e}" for e in erros] or ["- Todas as verificações passaram."]
texto = "\n".join(resumo) + "\n"
with open(os.path.join(OUT_DIR, "resumo.md"), "w", encoding="utf-8") as f:
    f.write(texto)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
        f.write(texto)
print(texto)
sys.exit(1 if erros else 0)
PY

if [[ "$CAPTURAR_TELAS" == "true" ]]; then
  log "capturando telas do Grafana e do Jaeger"
  GRAFANA_URL="http://127.0.0.1:13000" \
    JAEGER_URL="http://127.0.0.1:26686" \
    GRAFANA_USUARIO="$GRAFANA_USUARIO" \
    GRAFANA_SENHA="$GRAFANA_SENHA" \
    OUT_DIR="$OUT_DIR" \
    node "$(dirname "${BASH_SOURCE[0]}")/capturar_telas_observabilidade.cjs" \
    || log "aviso: captura de telas falhou (a validacao acima continua valida)"
fi
((STATUS == 0)) || falhar "verificacoes com falha (ver $OUT_DIR/resumo.md)"
log "observabilidade validada"
