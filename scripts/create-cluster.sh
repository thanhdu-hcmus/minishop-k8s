#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

for command_name in docker kind kubectl; do
  command -v "$command_name" >/dev/null || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

docker info --format '{{.ServerVersion}}' >/dev/null
kind version >/dev/null
kubectl version --client >/dev/null

mkdir -p "$REPO_ROOT/.kube"
if kind get clusters | grep -Fxq "$CLUSTER_NAME"; then
  kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG"
else
  kind create cluster --name "$CLUSTER_NAME" \
    --config "$REPO_ROOT/cluster/kind-config.yaml" \
    --kubeconfig "$KUBECONFIG"
fi

require_context
printf 'Cluster %s is ready through context %s.\n' "$CLUSTER_NAME" "$CONTEXT"
