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

require_helm_prerequisites
require_helm_cluster
require_runtime_prerequisites
bash "$SCRIPT_DIR/validate-helm.sh"

helm_release=$(helm_for_minishop list --filter '^minishop$' --short --namespace webapp)
if [[ -n "$helm_release" ]]; then
  printf '%s\n' 'Helm release minishop already exists; use deploy-helm.sh to upgrade it.' >&2
  exit 1
fi

printf '%s\n' 'The pre-existing minishop-backend HPA remains outside the chart.'

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
kubectl kustomize "$REPO_ROOT/kustomize/teardown/dev" \
  --load-restrictor LoadRestrictionsNone >"$rendered"

printf '%s\n' 'Deleting only the Kustomize runtime objects listed by kustomize/teardown/dev.'
kubectl_for_minishop delete --ignore-not-found=true --wait=true -f "$rendered"

for resource in statefulset/minishop-postgresql statefulset/minishop-redis; do
  resource_name=$(kubectl_for_minishop -n data get "$resource" --ignore-not-found \
    -o 'jsonpath={.metadata.name}')
  if [[ -n "$resource_name" ]]; then
    printf 'Kustomize-owned runtime resource remains after deletion: data/%s\n' \
      "$resource" >&2
    exit 1
  fi
done

for resource in deployment/minishop-backend deployment/minishop-frontend; do
  resource_name=$(kubectl_for_minishop -n webapp get "$resource" --ignore-not-found \
    -o 'jsonpath={.metadata.name}')
  if [[ -n "$resource_name" ]]; then
    printf 'Kustomize-owned runtime resource remains after deletion: webapp/%s\n' \
      "$resource" >&2
    exit 1
  fi
done

printf '%s\n' 'Kustomize runtime removed; Secrets, PVCs, namespaces, and platform resources were not targeted.'
