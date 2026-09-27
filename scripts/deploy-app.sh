#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_context

kubectl_for_minishop -n data get secret minishop-data-credentials >/dev/null
kubectl_for_minishop -n data rollout status statefulset/minishop-postgresql --timeout=180s
kubectl_for_minishop -n data rollout status statefulset/minishop-redis --timeout=180s

kubectl_for_minishop apply -f "$REPO_ROOT/manifests/20-webapp/namespace.yaml"
kubectl_for_minishop -n webapp get secret minishop-app-credentials >/dev/null
kubectl_for_minishop apply \
  -f "$REPO_ROOT/manifests/20-webapp/backend.yaml" \
  -f "$REPO_ROOT/manifests/20-webapp/frontend.yaml" \
  -f "$REPO_ROOT/manifests/20-webapp/networkpolicy.yaml"

kubectl_for_minishop -n webapp rollout status deployment/minishop-backend --timeout=180s
kubectl_for_minishop -n webapp rollout status deployment/minishop-frontend --timeout=180s
