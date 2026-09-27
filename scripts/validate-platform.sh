#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

for command_name in kubectl curl; do
  command -v "$command_name" >/dev/null || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

require_context

kubectl_for_minishop apply --dry-run=server \
  -f "$REPO_ROOT/manifests/20-webapp/networkpolicy.yaml" \
  -f "$REPO_ROOT/manifests/30-platform/rbac.yaml" \
  -f "$REPO_ROOT/manifests/30-platform/autoscaling.yaml" \
  -f "$REPO_ROOT/manifests/30-platform/monitoring.yaml"

expect_authorization() {
  local expected="$1"
  local verb="$2"
  local resource="$3"
  local namespace="$4"
  local actual

  actual=$(kubectl_for_minishop auth can-i "$verb" "$resource" \
    --as=developer \
    --as-group=minishop:developers \
    --as-group=system:authenticated \
    --namespace="$namespace" || true)
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected developer access %s for %s %s in %s; got %s.\n' \
      "$expected" "$verb" "$resource" "$namespace" "$actual" >&2
    return 1
  fi
}

for namespace in webapp data; do
  expect_authorization yes get pods "$namespace"
  expect_authorization yes list pods "$namespace"
  expect_authorization yes get pods/log "$namespace"
  expect_authorization no get secrets "$namespace"
  expect_authorization no list deployments.apps "$namespace"
done
expect_authorization no list pods default

for resource in secrets pods; do
  verb="get"
  [[ "$resource" == pods ]] && verb="list"
  actual=$(kubectl_for_minishop auth can-i "$verb" "$resource" \
    --as=system:serviceaccount:webapp:minishop-backend \
    --namespace=webapp || true)
  if [[ "$actual" != no ]]; then
    printf 'Backend ServiceAccount unexpectedly has %s access to %s.\n' \
      "$verb" "$resource" >&2
    exit 1
  fi
done

kubectl_for_minishop -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl_for_minishop top nodes >/dev/null
kubectl_for_minishop top pods -n webapp >/dev/null

if [[ "$(kubectl_for_minishop -n webapp get hpa minishop-backend -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}')" != True ]]; then
  printf 'Backend HPA does not report active CPU metrics.\n' >&2
  exit 1
fi

if [[ "$(kubectl_for_minishop -n webapp get hpa minishop-backend -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')" == "" ]]; then
  printf 'Backend HPA CPU utilization is not populated.\n' >&2
  exit 1
fi

cleanup_load_test() {
  kubectl_for_minishop -n webapp delete \
    -f "$REPO_ROOT/deploy/30-platform/hpa-load-test.yaml" \
    --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
}
trap cleanup_load_test EXIT

kubectl_for_minishop apply -f "$REPO_ROOT/deploy/30-platform/hpa-load-test.yaml"
load_scaled_up=false
for ((attempt = 0; attempt < 36; attempt += 1)); do
  replicas=$(kubectl_for_minishop -n webapp get deployment minishop-backend \
    -o jsonpath='{.spec.replicas}')
  if (( replicas > 3 )); then
    load_scaled_up=true
    break
  fi
  sleep 5
done
if [[ "$load_scaled_up" != true ]]; then
  printf 'Backend HPA did not scale above its minimum under controlled load.\n' >&2
  exit 1
fi

kubectl_for_minishop -n webapp wait --for=condition=complete \
  job/minishop-hpa-load-test --timeout=240s
kubectl_for_minishop -n webapp delete -f "$REPO_ROOT/deploy/30-platform/hpa-load-test.yaml" \
  --wait=true --timeout=60s

scaled_down=false
for ((attempt = 0; attempt < 48; attempt += 1)); do
  replicas=$(kubectl_for_minishop -n webapp get deployment minishop-backend \
    -o jsonpath='{.spec.replicas}')
  ready_replicas=$(kubectl_for_minishop -n webapp get deployment minishop-backend \
    -o jsonpath='{.status.readyReplicas}')
  if [[ "$replicas" == 3 && "$ready_replicas" == 3 ]]; then
    scaled_down=true
    break
  fi
  sleep 5
done
if [[ "$scaled_down" != true ]]; then
  printf 'Backend HPA did not settle back to its three-replica minimum.\n' >&2
  exit 1
fi

monitoring_pod=$(kubectl_for_minishop -n monitoring get pods \
  -l app.kubernetes.io/name=prometheus,operator.prometheus.io/name=monitoring-kube-prometheus-prometheus \
  -o jsonpath='{.items[0].metadata.name}')
if [[ -z "$monitoring_pod" ]]; then
  printf 'Prometheus pod was not found.\n' >&2
  exit 1
fi

metrics_response=$(kubectl_for_minishop -n monitoring exec "$monitoring_pod" -c prometheus -- \
  wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=up%7Bnamespace%3D%22webapp%22%2Cservice%3D%22minishop-backend%22%7D')
if [[ "$metrics_response" != *'"status":"success"'* || "$metrics_response" != *'"1"'* ]]; then
  printf 'Prometheus did not report the MiniShop backend scrape as healthy.\n' >&2
  exit 1
fi

backend_pod=$(kubectl_for_minishop -n webapp get pods \
  -l app.kubernetes.io/component=minishop-backend,app.kubernetes.io/name=minishop \
  -o jsonpath='{.items[0].metadata.name}')
restart_count=$(kubectl_for_minishop -n webapp get pod "$backend_pod" \
  -o jsonpath='{.status.containerStatuses[?(@.name=="backend")].restartCount}')
kubectl_for_minishop -n webapp exec "$backend_pod" -c backend -- \
  sh -c 'kill -TERM 1' >/dev/null
restart_observed=false
for ((attempt = 0; attempt < 36; attempt += 1)); do
  current_restart_count=$(kubectl_for_minishop -n webapp get pod "$backend_pod" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="backend")].restartCount}')
  if (( current_restart_count > restart_count )); then
    restart_observed=true
    break
  fi
  sleep 5
done
if [[ "$restart_observed" != true ]]; then
  printf 'Controlled backend container restart was not observed.\n' >&2
  exit 1
fi

alert_firing=false
for ((attempt = 0; attempt < 18; attempt += 1)); do
  alert_response=$(kubectl_for_minishop -n monitoring exec "$monitoring_pod" \
    -c prometheus -- wget -qO- \
    'http://127.0.0.1:9090/api/v1/query?query=ALERTS%7Balertname%3D%22MiniShopBackendRestart%22%2Calertstate%3D%22firing%22%7D')
  if [[ "$alert_response" == *'"status":"success"'* && "$alert_response" == *'"1"'* ]]; then
    alert_firing=true
    break
  fi
  sleep 5
done
if [[ "$alert_firing" != true ]]; then
  printf 'Prometheus did not report the backend-restart alert as firing.\n' >&2
  exit 1
fi

printf 'RBAC, metrics-server, HPA scale-up/down, backend scraping, and restart alert are verified.\n'
