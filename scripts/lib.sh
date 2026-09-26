#!/usr/bin/env bash

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export KUBECONFIG="$REPO_ROOT/.kube/config"
readonly CLUSTER_NAME=learn
readonly CONTEXT="kind-${CLUSTER_NAME}"

kubectl_for_minishop() {
  kubectl --context "$CONTEXT" "$@"
}

require_context() {
  kubectl config get-contexts "$CONTEXT" --no-headers | grep -q .
  kubectl_for_minishop cluster-info >/dev/null
}
