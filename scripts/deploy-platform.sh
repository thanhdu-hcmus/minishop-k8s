#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

for command_name in helm kubectl; do
  command -v "$command_name" >/dev/null || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

require_context
kubectl_for_minishop -n webapp get deployment minishop-backend >/dev/null
kubectl_for_minishop -n webapp get secret minishop-app-credentials >/dev/null

readonly METRICS_SERVER_VERSION="v0.7.2"
readonly PROMETHEUS_STACK_CHART_VERSION="69.8.2"
readonly METRICS_SERVER_MANIFEST="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

kubectl_for_minishop apply -f "$METRICS_SERVER_MANIFEST"
if ! kubectl_for_minishop -n kube-system get deployment metrics-server \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="metrics-server")].args}' \
  | grep -Fq -- '--kubelet-insecure-tls'; then
  kubectl_for_minishop -n kube-system patch deployment metrics-server \
    --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl_for_minishop -n kube-system patch deployment metrics-server \
  --type=strategic \
  -p='{"spec":{"template":{"spec":{"containers":[{"name":"metrics-server","resources":{"requests":{"cpu":"100m","memory":"200Mi"},"limits":{"cpu":"250m","memory":"256Mi"}}}]}}}}'

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts \
  --force-update >/dev/null
helm upgrade --install monitoring \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version "$PROMETHEUS_STACK_CHART_VERSION" \
  --reuse-values \
  --values "$REPO_ROOT/deploy/30-platform/kube-prometheus-stack-values.yaml" \
  --wait \
  --timeout 10m

kubectl_for_minishop apply -f "$REPO_ROOT/manifests/30-platform/rbac.yaml"
if kubectl_for_minishop -n webapp get deployment minishop-backend >/dev/null 2>&1 \
  && [[ "$(kubectl_for_minishop -n webapp get deployment minishop-backend \
    -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/component}')" != "minishop-backend" ]]; then
  printf 'Replacing minishop-backend to migrate its immutable selector.\n'
  kubectl_for_minishop -n webapp delete deployment minishop-backend --wait=true --timeout=180s
fi
kubectl_for_minishop apply \
  -f "$REPO_ROOT/manifests/20-webapp/backend.yaml" \
  -f "$REPO_ROOT/manifests/20-webapp/networkpolicy.yaml"
kubectl_for_minishop apply -f "$REPO_ROOT/manifests/30-platform/autoscaling.yaml"
kubectl_for_minishop apply -f "$REPO_ROOT/manifests/30-platform/monitoring.yaml"

kubectl_for_minishop -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl_for_minishop -n webapp rollout status deployment/minishop-backend --timeout=180s
kubectl_for_minishop -n monitoring rollout status deployment/monitoring-kube-prometheus-operator --timeout=300s
kubectl_for_minishop -n monitoring rollout status deployment/monitoring-grafana --timeout=300s

printf 'MiniShop platform resources are deployed in context %s.\n' "$CONTEXT"
