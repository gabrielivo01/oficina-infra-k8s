#!/usr/bin/env bash
# Implanta os 3 servicos da Fase 4 (OS, Execution, Billing) no cluster kind criado por plataforma_up.sh e espera
# os rollouts e os health checks. Usado pelo cd.yml de cada servico e para demo local. Idempotente.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Uso: scripts/deploy_servicos_kind.sh

Variaveis de ambiente:
  OFICINA_DIR        Checkout do repo oficina            (padrao: ../oficina)
  EXECUTION_DIR      Checkout do oficina-execution-service (padrao: ../oficina-execution-service)
  BILLING_DIR        Checkout do oficina-billing-service   (padrao: ../oficina-billing-service)
  IMAGE_OFICINA      Imagem do OS Service        (padrao: ghcr.io/gabrielivo01/oficina:latest)
  IMAGE_EXECUTION    Imagem do Execution Service (padrao: ghcr.io/gabrielivo01/oficina-execution-service:latest)
  IMAGE_BILLING      Imagem do Billing Service   (padrao: ghcr.io/gabrielivo01/oficina-billing-service:latest)
  JWT_SECRET         Segredo HS256 compartilhado pelos 3 servicos (padrao: gerado na primeira execucao)
  BILLING_FAKE_STATUS_INICIAL  Status inicial do gateway fake (padrao: APROVADO, para o smoke test)
  CLUSTER_NAME       Cluster kind (padrao: oficina)
  WAIT_TIMEOUT       Espera maxima de cada rollout (padrao: 600s)

Imagens presentes no Docker local sao carregadas no kind ("kind load"); as demais sao baixadas com
"docker pull" (o runner precisa de acesso de leitura ao GHCR) e carregadas.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

PROJECT_DIR="$(cd "$ROOT_DIR/.." && pwd)"
OFICINA_DIR="${OFICINA_DIR:-$PROJECT_DIR/oficina}"
EXECUTION_DIR="${EXECUTION_DIR:-$PROJECT_DIR/oficina-execution-service}"
BILLING_DIR="${BILLING_DIR:-$PROJECT_DIR/oficina-billing-service}"
IMAGE_OFICINA="${IMAGE_OFICINA:-ghcr.io/gabrielivo01/oficina:latest}"
IMAGE_EXECUTION="${IMAGE_EXECUTION:-ghcr.io/gabrielivo01/oficina-execution-service:latest}"
IMAGE_BILLING="${IMAGE_BILLING:-ghcr.io/gabrielivo01/oficina-billing-service:latest}"
BILLING_FAKE_STATUS_INICIAL="${BILLING_FAKE_STATUS_INICIAL:-APROVADO}"
CLUSTER_NAME="${CLUSTER_NAME:-oficina}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600s}"
NAMESPACE="oficina"

log() { echo "[deploy] $*"; }

aleatorio() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

carregar_imagem() {
  local imagem="$1"
  if ! docker image inspect "$imagem" >/dev/null 2>&1; then
    log "baixando $imagem"
    docker pull "$imagem"
  fi
  log "carregando $imagem no kind"
  kind load docker-image "$imagem" --name "$CLUSTER_NAME"
}

for dir in "$OFICINA_DIR" "$EXECUTION_DIR" "$BILLING_DIR"; do
  [[ -d "$dir/k8s/overlays/local" ]] || { echo "Overlay local nao encontrado em $dir" >&2; exit 1; }
done

carregar_imagem "$IMAGE_OFICINA"
carregar_imagem "$IMAGE_EXECUTION"
carregar_imagem "$IMAGE_BILLING"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Segredo JWT compartilhado: reaproveita o do Billing se ja existir (redeploy nao invalida tokens em uso).
if [[ -z "${JWT_SECRET:-}" ]]; then
  JWT_SECRET="$(kubectl -n "$NAMESPACE" get secret oficina-billing-service -o jsonpath='{.data.JWT_SECRET}' 2>/dev/null \
    | base64 -d 2>/dev/null || true)"
  JWT_SECRET="${JWT_SECRET:-$(aleatorio 48)}"
fi

# Secrets do Billing (script do proprio repo). A chave do replica set e a senha do Mongo sao geradas uma vez e
# preservadas: troca-las quebraria o volume ja inicializado.
if ! kubectl -n "$NAMESPACE" get secret oficina-billing-mongodb >/dev/null 2>&1; then
  export MONGO_ROOT_PASSWORD="${MONGO_ROOT_PASSWORD:-$(aleatorio 24)}"
  export MONGO_REPLICA_KEY="${MONGO_REPLICA_KEY:-$(aleatorio 48)}"
else
  export MONGO_ROOT_PASSWORD="$(kubectl -n "$NAMESPACE" get secret oficina-billing-mongodb \
    -o jsonpath='{.data.MONGO_ROOT_PASSWORD}' | base64 -d)"
  export MONGO_REPLICA_KEY="$(kubectl -n "$NAMESPACE" get secret oficina-billing-mongodb \
    -o jsonpath='{.data.MONGO_REPLICA_KEY}' | base64 -d)"
fi
JWT_SECRET="$JWT_SECRET" APP_PAGAMENTO_GATEWAY=fake bash "$BILLING_DIR/scripts/create-secret.sh"

log "aplicando overlays"
kubectl apply -k "$OFICINA_DIR/k8s/overlays/local"
kubectl apply -k "$EXECUTION_DIR/k8s/overlays/local"
kubectl apply -k "$BILLING_DIR/k8s/overlays/local"

# Mesmo segredo JWT nos 3 servicos (tokens de staff emitidos pelo OS valem no Execution e no Billing).
kubectl -n "$NAMESPACE" patch secret oficina-secret --type merge -p "{\"stringData\":{\"JWT_SECRET\":\"$JWT_SECRET\"}}"
kubectl -n "$NAMESPACE" patch secret oficina-execution-service --type merge \
  -p "{\"stringData\":{\"JWT_SECRET\":\"$JWT_SECRET\"}}"

kubectl -n "$NAMESPACE" set image deployment/oficina-app oficina-app="$IMAGE_OFICINA"
kubectl -n "$NAMESPACE" set image deployment/oficina-execution-service app="$IMAGE_EXECUTION"
kubectl -n "$NAMESPACE" set image deployment/oficina-billing-service app="$IMAGE_BILLING"
kubectl -n "$NAMESPACE" set env deployment/oficina-billing-service \
  APP_PAGAMENTO_FAKE_STATUS_INICIAL="$BILLING_FAKE_STATUS_INICIAL"

log "aguardando bancos"
kubectl -n "$NAMESPACE" rollout status deployment/oficina-postgres --timeout="$WAIT_TIMEOUT"
kubectl -n "$NAMESPACE" rollout status statefulset/execution-postgres --timeout="$WAIT_TIMEOUT"
kubectl -n "$NAMESPACE" rollout status statefulset/oficina-billing-mongodb --timeout="$WAIT_TIMEOUT"

# Secrets alterados depois do apply: reinicia para os pods lerem o valor novo.
kubectl -n "$NAMESPACE" rollout restart deployment/oficina-app deployment/oficina-execution-service \
  deployment/oficina-billing-service

log "aguardando servicos"
for deployment in oficina-app oficina-execution-service oficina-billing-service; do
  kubectl -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout="$WAIT_TIMEOUT"
done

log "health checks"
for alvo in oficina-app:80 oficina-execution-service:8080 oficina-billing-service:8082; do
  servico="${alvo%%:*}"
  kubectl -n "$NAMESPACE" run "health-$servico-$RANDOM" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 -- \
    curl -fsS --max-time 10 "http://$alvo/actuator/health/readiness"
  echo
done

log "servicos implantados"
