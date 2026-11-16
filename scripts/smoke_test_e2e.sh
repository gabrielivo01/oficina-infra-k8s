#!/usr/bin/env bash
# Smoke test E2E da Saga (Fase 4, etapa 7.3): abre uma OS pela API e a acompanha ate FINALIZADA, usando o gateway
# fake do Billing (APP_PAGAMENTO_FAKE_STATUS_INICIAL=APROVADO, ver deploy_servicos_kind.sh) e os endpoints do
# mecanico no Execution. Termina com a Saga CONCLUIDA. Requer curl e jq.
set -euo pipefail

usage() {
  cat <<EOF
Uso: scripts/smoke_test_e2e.sh

Variaveis de ambiente:
  OS_URL, EXECUTION_URL, BILLING_URL  URLs dos servicos. Se ausentes, o script abre port-forward
                                      para os Services do namespace "oficina" (portas 18080-18082).
  STAFF_LOGIN, STAFF_SENHA            Usuario de staff do OS Service (padrao: admin / admin123, do seeder)
  TIMEOUT                             Espera maxima de cada etapa, em segundos (padrao: 120)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

STAFF_LOGIN="${STAFF_LOGIN:-admin}"
STAFF_SENHA="${STAFF_SENHA:-admin123}"
TIMEOUT="${TIMEOUT:-120}"
NAMESPACE="oficina"
PIDS=()

log() { echo "[smoke] $*"; }
falhar() { echo "[smoke] FALHA: $*" >&2; exit 1; }

encerrar() {
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
}
trap encerrar EXIT

port_forward() {
  local servico="$1" porta_local="$2" porta_servico="$3"
  kubectl -n "$NAMESPACE" port-forward "svc/$servico" "$porta_local:$porta_servico" >/dev/null 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:$porta_local/actuator/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  falhar "port-forward para $servico nao respondeu"
}

if [[ -z "${OS_URL:-}" ]]; then
  port_forward oficina-app 18080 80
  OS_URL="http://127.0.0.1:18080"
fi
if [[ -z "${EXECUTION_URL:-}" ]]; then
  port_forward oficina-execution-service 18081 8080
  EXECUTION_URL="http://127.0.0.1:18081"
fi
if [[ -z "${BILLING_URL:-}" ]]; then
  port_forward oficina-billing-service 18082 8082
  BILLING_URL="http://127.0.0.1:18082"
fi

# chamada <metodo> <url> [corpo-json]: imprime o corpo da resposta; falha em status >= 400.
chamada() {
  local metodo="$1" url="$2" corpo="${3:-}"
  local args=(-fsS --max-time 15 -X "$metodo" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")
  [[ -n "$corpo" ]] && args+=(-d "$corpo")
  curl "${args[@]}" "$url" || falhar "$metodo $url"
}

# aguardar <descricao> <comando que imprime "ok" quando a condicao vale>
aguardar() {
  local descricao="$1"
  shift
  local fim=$((SECONDS + TIMEOUT))
  while ((SECONDS < fim)); do
    if [[ "$("$@" 2>/dev/null || true)" == "ok" ]]; then
      log "ok: $descricao"
      return 0
    fi
    sleep 2
  done
  falhar "tempo esgotado aguardando: $descricao"
}

status_da_os() {
  [[ "$(chamada GET "$OS_URL/ordens-servico/$OS_ID" | jq -r .status)" == "$1" ]] && echo ok
}

tarefa_id() {
  chamada GET "$EXECUTION_URL/tarefas?status=$1" \
    | jq -r --arg os "$OS_ID" --arg tipo "$2" '.[] | select(.osId == $os and .tipo == $tipo) | .id' | head -n 1
}

tarefa_existe() {
  [[ -n "$(tarefa_id "$1" "$2")" ]] && echo ok
}

log "login de staff"
TOKEN="$(curl -fsS --max-time 15 -H "Content-Type: application/json" \
  -d "{\"login\":\"$STAFF_LOGIN\",\"senha\":\"$STAFF_SENHA\"}" "$OS_URL/auth/login" | jq -r .token)"
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || falhar "login sem token"

SUFIXO="$(date +%s)"
# CPF, e-mail e placa variam a cada execucao (sao unicos no OS Service); os 2 digitos verificadores sao calculados.
CPF="$(printf '%09d' $((SUFIXO % 1000000000)))"
CPF="$(python3 -c "
import sys
b=[int(c) for c in sys.argv[1]]
d1=(sum(v*(10-i) for i,v in enumerate(b))*10)%11%10
d2=(sum(v*(11-i) for i,v in enumerate(b+[d1]))*10)%11%10
print(sys.argv[1]+str(d1)+str(d2))" "$CPF")"
PLACA="SMK$(printf '%04d' $((SUFIXO % 10000)))"

log "cadastro de cliente e veiculo"
CLIENTE_ID="$(chamada POST "$OS_URL/clientes" \
  "{\"cpf\":\"$CPF\",\"nome\":\"Cliente Smoke\",\"telefone\":\"11999999999\",\"email\":\"smoke-$SUFIXO@example.com\"}" \
  | jq -r .id)"
VEICULO_ID="$(chamada POST "$OS_URL/veiculos" \
  "{\"clienteId\":\"$CLIENTE_ID\",\"placa\":\"$PLACA\",\"marca\":\"Fiat\",\"modelo\":\"Uno\",\"ano\":2020}" \
  | jq -r .id)"

log "abertura da OS"
OS_ID="$(chamada POST "$OS_URL/ordens-servico" "{\"clienteId\":\"$CLIENTE_ID\",\"veiculoId\":\"$VEICULO_ID\"}" \
  | jq -r .id)"
log "OS $OS_ID"

aguardar "tarefa de diagnostico na fila do Execution" tarefa_existe NA_FILA DIAGNOSTICO
DIAGNOSTICO_ID="$(tarefa_id NA_FILA DIAGNOSTICO)"
chamada POST "$EXECUTION_URL/tarefas/$DIAGNOSTICO_ID/iniciar-diagnostico" >/dev/null
aguardar "OS em EM_DIAGNOSTICO" status_da_os EM_DIAGNOSTICO
chamada POST "$EXECUTION_URL/tarefas/$DIAGNOSTICO_ID/diagnostico/concluir" '{"itens":[
  {"tipo":"SERVICO","descricao":"Troca de oleo","valorUnitario":80.00,"quantidade":1},
  {"tipo":"PECA","descricao":"Filtro de oleo","valorUnitario":25.50,
   "pecaId":"c0a8012e-0003-4000-8000-000000000003","quantidade":1}]}' >/dev/null
aguardar "OS em AGUARDANDO_APROVACAO" status_da_os AGUARDANDO_APROVACAO

ORCAMENTO_ID="$(chamada GET "$BILLING_URL/orcamentos/$OS_ID" | jq -r .id)"
chamada POST "$BILLING_URL/orcamentos/$ORCAMENTO_ID/resposta" '{"aprovado":true,"observacao":"smoke test"}' >/dev/null
log "orcamento $ORCAMENTO_ID aprovado; gateway fake aprova o pagamento"

aguardar "OS em EM_EXECUCAO" status_da_os EM_EXECUCAO
REPARO_ID="$(tarefa_id EM_ANDAMENTO REPARO)"
[[ -n "$REPARO_ID" ]] || falhar "tarefa de reparo nao encontrada"
chamada POST "$EXECUTION_URL/tarefas/$REPARO_ID/progresso" '{"descricao":"Troca concluida"}' >/dev/null
chamada POST "$EXECUTION_URL/tarefas/$REPARO_ID/finalizar" >/dev/null
aguardar "OS em FINALIZADA" status_da_os FINALIZADA

SITUACAO="$(chamada GET "$OS_URL/ordens-servico/$OS_ID/saga" | jq -r .situacao)"
[[ "$SITUACAO" == "CONCLUIDA" ]] || falhar "Saga em $SITUACAO, esperado CONCLUIDA"
log "Saga da OS $OS_ID CONCLUIDA"
