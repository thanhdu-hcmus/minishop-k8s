#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="$REPO_ROOT/.tools/bin:$PATH"
export KUBECONFIG="$REPO_ROOT/.kube/config"
CONTEXT=kind-learn

kubectl_for_minishop() {
  kubectl --context "$CONTEXT" "$@"
}

require_context() {
  kubectl config get-contexts "$CONTEXT" --no-headers | grep -q .
  kubectl_for_minishop cluster-info >/dev/null
}
