#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=scripts/lib.sh
# shellcheck disable=SC1091
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
created=false
if kind get clusters | grep -Fxq "$CLUSTER_NAME"; then
  kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG"
else
  kind create cluster --name "$CLUSTER_NAME" \
    --config "$REPO_ROOT/cluster/kind-config.yaml" \
    --kubeconfig "$KUBECONFIG"
  created=true
fi

require_context

# The node image's kindnet limits starve kindnetd (Issue #50). Fix a new
# cluster here; an existing cluster is only checked, and the owner applies it.
if [[ "$created" == true ]]; then
  bash "$REPO_ROOT/scripts/tune-kindnet-resources.sh" --apply
else
  bash "$REPO_ROOT/scripts/tune-kindnet-resources.sh" ||
    printf 'Warning: kindnet check failed; see docs/troubleshooting.md#kindnet-xtables-lock\n' >&2
fi
printf 'Cluster %s is ready through context %s.\n' "$CLUSTER_NAME" "$CONTEXT"
