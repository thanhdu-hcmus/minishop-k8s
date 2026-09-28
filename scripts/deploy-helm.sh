#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MINISHOP_KUBECONFIG=${MINISHOP_KUBECONFIG:-${KUBECONFIG:-}}
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=helm-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/helm-lib.sh"

values_file=${1:-values-dev.yaml}
case "$values_file" in
  values.yaml|values-dev.yaml|values-prod.yaml) ;;
  *)
    printf '%s\n' 'Usage: bash scripts/deploy-helm.sh [values.yaml|values-dev.yaml|values-prod.yaml]' >&2
    exit 2
    ;;
esac

require_helm_prerequisites
require_helm_cluster
require_runtime_prerequisites
helm_release=$(helm_for_minishop list --filter '^minishop$' --short --namespace webapp)
if [[ -z "$helm_release" ]]; then
  require_kustomize_handoff
fi
bash "$SCRIPT_DIR/validate-helm.sh"

helm_for_minishop upgrade --install minishop /chart \
  --namespace webapp --values "/chart/$values_file" --wait --timeout 5m

for workload in statefulset/minishop-postgresql statefulset/minishop-redis; do
  kubectl_for_minishop -n data rollout status "$workload" --timeout=180s
done
for workload in deployment/minishop-backend deployment/minishop-frontend; do
  kubectl_for_minishop -n webapp rollout status "$workload" --timeout=180s
done

hpa_minimum=$(kubectl_for_minishop -n webapp get hpa minishop-backend \
  --ignore-not-found -o jsonpath='{.spec.minReplicas}')
if [[ -n "$hpa_minimum" ]]; then
  printf 'Waiting for the platform HPA minimum of %s backend replicas.\n' "$hpa_minimum"
  for attempt in {1..36}; do
    ready_replicas=$(kubectl_for_minishop -n webapp get deployment minishop-backend \
      -o jsonpath='{.status.readyReplicas}')
    ready_replicas=${ready_replicas:-0}
    if (( ready_replicas >= hpa_minimum )); then
      break
    fi
    if (( attempt == 36 )); then
      printf 'Backend did not reach the platform HPA minimum (%s ready).\n' \
        "$ready_replicas" >&2
      exit 1
    fi
    sleep 5
  done
  printf 'The active platform HPA keeps the backend at %s or more replicas.\n' \
    "$hpa_minimum"
fi

printf '%s\n' 'MiniShop Helm runtime deployed; run bash scripts/validate-app.sh for end-to-end verification.'
