#!/usr/bin/env bash
# Destroi o cluster kind da plataforma (e tudo o que roda nele).
# Idempotente: se o cluster nao existir, nao faz nada.
set -euo pipefail

usage() {
  cat <<EOF
Uso: scripts/plataforma_down.sh

Apaga o cluster kind criado por scripts/plataforma_up.sh.

Variaveis de ambiente opcionais:
  CLUSTER_NAME  Nome do cluster kind (padrao: oficina)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

CLUSTER_NAME="${CLUSTER_NAME:-oficina}"

command -v kind >/dev/null 2>&1 || { echo "ERRO: comando 'kind' e obrigatorio e nao foi encontrado." >&2; exit 1; }

clusters="$(kind get clusters 2>/dev/null || true)"
if grep -qx "$CLUSTER_NAME" <<<"$clusters"; then
  echo "==> Apagando cluster kind '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "==> Cluster kind '$CLUSTER_NAME' nao existe; nada a fazer"
fi
