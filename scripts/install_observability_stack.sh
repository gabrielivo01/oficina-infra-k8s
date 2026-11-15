#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: scripts/install_observability_stack.sh

Installs kube-prometheus-stack (Prometheus + Grafana + Alertmanager +
node-exporter + kube-state-metrics) into the current kubectl context, then
applies the oficina-specific ServiceMonitor, PrometheusRule, and Grafana
dashboard ConfigMap under k8s/observability/ (namespace "oficina", created
if missing).

Requires: helm, kubectl (pointed at the target cluster).

Optional environment variables:
  MONITORING_NAMESPACE           Namespace for the stack (default: monitoring)
  HELM_RELEASE_NAME              Helm release name (default: kube-prometheus-stack)
  OBSERVABILITY_PROFILE          "default" (EKS) or "kind" (adds
                                 values-kube-prometheus-stack-kind.yaml: 1 replica,
                                 short retention, small resources, no Alertmanager)
                                 (default: default)
  KUBE_PROMETHEUS_STACK_VERSION  Chart version to pin (default: latest)
  HELM_WAIT                      "true" to wait until the release is ready
                                 (default: false)
  HELM_TIMEOUT                   Timeout used with HELM_WAIT (default: 10m)

Example:
  scripts/install_observability_stack.sh
  OBSERVABILITY_PROFILE=kind HELM_WAIT=true scripts/install_observability_stack.sh
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
# Namespace fixo dos manifests de k8s/observability/ (criado se nao existir,
# p.ex. num cluster kind recem-criado, antes do deploy dos servicos).
APP_NAMESPACE="oficina"
OBSERVABILITY_PROFILE="${OBSERVABILITY_PROFILE:-default}"
KUBE_PROMETHEUS_STACK_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-}"
HELM_WAIT="${HELM_WAIT:-false}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"

VALUES_ARGS=(-f "$ROOT_DIR/k8s/observability/values-kube-prometheus-stack.yaml")
case "$OBSERVABILITY_PROFILE" in
  default) ;;
  kind) VALUES_ARGS+=(-f "$ROOT_DIR/k8s/observability/values-kube-prometheus-stack-kind.yaml") ;;
  *)
    echo "ERROR: OBSERVABILITY_PROFILE must be 'default' or 'kind' (got '$OBSERVABILITY_PROFILE')." >&2
    exit 1
    ;;
esac

HELM_ARGS=()
if [[ -n "$KUBE_PROMETHEUS_STACK_VERSION" ]]; then
  HELM_ARGS+=(--version "$KUBE_PROMETHEUS_STACK_VERSION")
fi
if [[ "$HELM_WAIT" == "true" ]]; then
  HELM_ARGS+=(--wait --timeout "$HELM_TIMEOUT")
fi

echo "Adding prometheus-community Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update prometheus-community >/dev/null

echo "Installing/upgrading $HELM_RELEASE_NAME in namespace $MONITORING_NAMESPACE (profile: $OBSERVABILITY_PROFILE)"
helm upgrade --install "$HELM_RELEASE_NAME" prometheus-community/kube-prometheus-stack \
  --namespace "$MONITORING_NAMESPACE" \
  --create-namespace \
  "${VALUES_ARGS[@]}" \
  "${HELM_ARGS[@]}"

echo "Ensuring namespace $APP_NAMESPACE exists"
kubectl create namespace "$APP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "Applying oficina ServiceMonitor, PrometheusRule and Grafana dashboard"
kubectl apply -f "$ROOT_DIR/k8s/observability/servicemonitor-oficina-app.yaml"
kubectl apply -f "$ROOT_DIR/k8s/observability/prometheusrule-oficina.yaml"
kubectl apply -f "$ROOT_DIR/k8s/observability/grafana-dashboard-oficina.yaml"

echo "Done. Grafana (admin / see values-kube-prometheus-stack*.yaml adminPassword):"
echo "  kubectl -n $MONITORING_NAMESPACE port-forward svc/$HELM_RELEASE_NAME-grafana 3000:80"
