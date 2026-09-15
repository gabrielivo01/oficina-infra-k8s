#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: scripts/install_observability_stack.sh

Installs kube-prometheus-stack (Prometheus + Grafana + Alertmanager +
node-exporter + kube-state-metrics) into the current kubectl context, then
applies the oficina-specific ServiceMonitor, PrometheusRule, and Grafana
dashboard ConfigMap under k8s/observability/.

Requires: helm, kubectl (pointed at the target cluster).

Optional environment variables:
  MONITORING_NAMESPACE   Namespace for the stack (default: monitoring)
  HELM_RELEASE_NAME      Helm release name (default: kube-prometheus-stack)

Example:
  scripts/install_observability_stack.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for cmd in helm kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: command '$cmd' is required but not installed." >&2
    exit 1
  fi
done

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-kube-prometheus-stack}"

echo "Adding prometheus-community Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo "Installing/upgrading $HELM_RELEASE_NAME in namespace $MONITORING_NAMESPACE"
helm upgrade --install "$HELM_RELEASE_NAME" prometheus-community/kube-prometheus-stack \
  --namespace "$MONITORING_NAMESPACE" \
  --create-namespace \
  -f "$ROOT_DIR/k8s/observability/values-kube-prometheus-stack.yaml"

echo "Applying oficina ServiceMonitor, PrometheusRule and Grafana dashboard"
kubectl apply -f "$ROOT_DIR/k8s/observability/servicemonitor-oficina-app.yaml"
kubectl apply -f "$ROOT_DIR/k8s/observability/prometheusrule-oficina.yaml"
kubectl apply -f "$ROOT_DIR/k8s/observability/grafana-dashboard-oficina.yaml"

echo "Done. Grafana (admin / see values-kube-prometheus-stack.yaml adminPassword):"
echo "  kubectl -n $MONITORING_NAMESPACE port-forward svc/$HELM_RELEASE_NAME-grafana 3000:80"
