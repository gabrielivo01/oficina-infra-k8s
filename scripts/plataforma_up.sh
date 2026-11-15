#!/usr/bin/env bash
# Sobe a plataforma da oficina num cluster kind: ingress-nginx, RabbitMQ,
# Jaeger, OTel Collector e kube-prometheus-stack (perfil enxuto "kind").
# Idempotente (pode rodar de novo sobre um cluster existente) e nao interativo
# (funciona no GitHub Actions: sem prompts, sem sudo).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Uso: scripts/plataforma_up.sh

Cria (se nao existir) o cluster kind definido em kind/cluster.yaml e instala:
  - ingress-nginx               (k8s/plataforma/ingress-nginx)
  - RabbitMQ, Jaeger, OTel      (k8s/plataforma, namespace "plataforma")
  - kube-prometheus-stack       (scripts/install_observability_stack.sh, perfil kind)
Ao final, espera todos os pods ficarem Running/Completed e testa as UIs pelo ingress.

Requer: docker, kind, kubectl, helm (curl opcional, para o teste do ingress).

Variaveis de ambiente opcionais:
  CLUSTER_NAME                   Nome do cluster kind (padrao: oficina)
  KIND_NODE_IMAGE                Imagem dos nos (padrao: a da versao do kind)
  KUBE_PROMETHEUS_STACK_VERSION  Versao do chart (padrao: 93.1.2)
  WAIT_TIMEOUT                   Tempo maximo de cada espera, em segundos (padrao: 600s)
  INGRESS_HTTP_PORT              Porta HTTP do ingress no host, igual ao hostPort de
                                 kind/cluster.yaml (padrao: 8081)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

CLUSTER_NAME="${CLUSTER_NAME:-oficina}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"
KUBE_PROMETHEUS_STACK_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-93.1.2}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600s}"
INGRESS_HTTP_PORT="${INGRESS_HTTP_PORT:-8081}"
CONTEXT="kind-$CLUSTER_NAME"
MONITORING_NAMESPACE="monitoring"
HELM_RELEASE_NAME="kube-prometheus-stack"

log() { echo "==> $*"; }
fail() { echo "ERRO: $*" >&2; exit 1; }

[[ "$WAIT_TIMEOUT" =~ ^[0-9]+s$ ]] || fail "WAIT_TIMEOUT deve estar em segundos (ex.: 600s)."

for cmd in docker kind kubectl helm; do
  command -v "$cmd" >/dev/null 2>&1 || fail "comando '$cmd' e obrigatorio e nao foi encontrado."
done
docker info >/dev/null 2>&1 || fail "o Docker nao esta acessivel (daemon parado ou sem permissao)."

# retry <tentativas> <intervalo_s> <comando...>
retry() {
  local tentativas="$1" intervalo="$2" n=1
  shift 2
  until "$@"; do
    if (( n >= tentativas )); then
      return 1
    fi
    echo "    falhou (tentativa $n/$tentativas); nova tentativa em ${intervalo}s"
    n=$((n + 1))
    sleep "$intervalo"
  done
}

# Pods que ainda nao estao Running com todos os containers prontos (nem Completed).
pods_nao_prontos() {
  kubectl get pods -A --no-headers 2>/dev/null | awk '{
    split($3, r, "/");
    if (!(($4 == "Running" && r[1] == r[2]) || $4 == "Completed")) print "    " $1 "/" $2 " " $3 " " $4
  }'
}

aguardar_pods() {
  local limite=$(( ${WAIT_TIMEOUT%s} ))
  local inicio=$SECONDS pendentes
  while true; do
    pendentes="$(pods_nao_prontos)"
    [[ -z "$pendentes" ]] && return 0
    if (( SECONDS - inicio >= limite )); then
      echo "Pods ainda nao prontos apos ${WAIT_TIMEOUT}:" >&2
      echo "$pendentes" >&2
      return 1
    fi
    sleep 10
  done
}

aplicar_plataforma() {
  kubectl kustomize --load-restrictor=LoadRestrictionsNone "$ROOT_DIR/k8s/plataforma" | kubectl apply -f -
}

# 1. Cluster
clusters="$(kind get clusters 2>/dev/null || true)"
if grep -qx "$CLUSTER_NAME" <<<"$clusters"; then
  log "Cluster kind '$CLUSTER_NAME' ja existe; reaproveitando"
else
  log "Criando cluster kind '$CLUSTER_NAME'"
  create_args=(--name "$CLUSTER_NAME" --config "$ROOT_DIR/kind/cluster.yaml" --wait 180s)
  if [[ -n "$KIND_NODE_IMAGE" ]]; then
    create_args+=(--image "$KIND_NODE_IMAGE")
  fi
  kind create cluster "${create_args[@]}"
fi
# Garante que kubectl/helm (inclusive no install_observability_stack.sh) apontem para este cluster.
kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null
[[ "$(kubectl config current-context)" == "$CONTEXT" ]] || fail "contexto atual nao e $CONTEXT."

# 2. Ingress
log "Instalando ingress-nginx"
kubectl apply -k "$ROOT_DIR/k8s/plataforma/ingress-nginx"
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout="$WAIT_TIMEOUT"

# 3. RabbitMQ, Jaeger, OTel Collector (o webhook do ingress pode levar alguns
#    segundos para aceitar Ingress novos, por isso o retry)
log "Aplicando RabbitMQ, Jaeger e OTel Collector (namespace plataforma)"
retry 10 6 aplicar_plataforma
kubectl -n plataforma rollout status statefulset/rabbitmq --timeout="$WAIT_TIMEOUT"
kubectl -n plataforma rollout status deployment/jaeger --timeout="$WAIT_TIMEOUT"
kubectl -n plataforma rollout status deployment/otel-collector --timeout="$WAIT_TIMEOUT"

# 4. Prometheus + Grafana (script existente, com o perfil enxuto do kind)
#    Uma execucao anterior interrompida no meio do Helm deixa o release em
#    pending-*, o que bloqueia novos upgrades: nesse caso ele e removido antes.
if helm list -n "$MONITORING_NAMESPACE" --pending -q | grep -qx "$HELM_RELEASE_NAME"; then
  log "Release $HELM_RELEASE_NAME preso em estado pendente; removendo para reinstalar"
  helm uninstall "$HELM_RELEASE_NAME" -n "$MONITORING_NAMESPACE" --wait --timeout "$WAIT_TIMEOUT"
fi
log "Instalando kube-prometheus-stack (perfil kind)"
OBSERVABILITY_PROFILE=kind \
  MONITORING_NAMESPACE="$MONITORING_NAMESPACE" \
  HELM_RELEASE_NAME="$HELM_RELEASE_NAME" \
  HELM_WAIT=true \
  HELM_TIMEOUT="$WAIT_TIMEOUT" \
  KUBE_PROMETHEUS_STACK_VERSION="$KUBE_PROMETHEUS_STACK_VERSION" \
  "$ROOT_DIR/scripts/install_observability_stack.sh"

# 5. Verificacao final
log "Aguardando todos os pods ficarem Running/Completed"
aguardar_pods

if command -v curl >/dev/null 2>&1; then
  log "Testando as UIs pelo ingress (http://127.0.0.1:$INGRESS_HTTP_PORT, header Host)"
  for alvo in grafana.localtest.me/api/health jaeger.localtest.me/ rabbitmq.localtest.me/; do
    host="${alvo%%/*}"
    caminho="/${alvo#*/}"
    retry 12 5 curl -fsS -o /dev/null -H "Host: $host" "http://127.0.0.1:${INGRESS_HTTP_PORT}${caminho}" \
      || fail "UI $host nao respondeu pelo ingress."
    echo "    $host OK"
  done
fi

kubectl get pods -A

cat <<EOF

Plataforma pronta no contexto $CONTEXT.
  Grafana   http://grafana.localtest.me:$INGRESS_HTTP_PORT   (admin / admin)
  Jaeger    http://jaeger.localtest.me:$INGRESS_HTTP_PORT
  RabbitMQ  http://rabbitmq.localtest.me:$INGRESS_HTTP_PORT  (oficina / oficina)
Sem ingress (port-forward):
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
  kubectl -n plataforma port-forward svc/jaeger 16686:16686
  kubectl -n plataforma port-forward svc/rabbitmq 15672:15672 5672:5672
Endpoints internos: rabbitmq.plataforma.svc:5672, otel-collector.plataforma.svc:4317 (gRPC) / :4318 (HTTP)
EOF
