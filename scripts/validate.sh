#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"

kubectl kustomize "$REPO_ROOT/kustomize/base" >/dev/null
kubectl kustomize "$REPO_ROOT/kustomize/overlays/dev" >/dev/null
kubectl kustomize "$REPO_ROOT/kustomize/overlays/prod" >/dev/null

if command -v helm >/dev/null; then
  helm lint "$REPO_ROOT/charts/minishop"
  helm template minishop "$REPO_ROOT/charts/minishop" >/dev/null
else
  printf 'SKIP Helm validation: helm is not installed.\n'
fi

if command -v yamllint >/dev/null; then
  yamllint "$REPO_ROOT/manifests" "$REPO_ROOT/kustomize" "$REPO_ROOT/charts"
else
  printf 'SKIP yamllint: yamllint is not installed.\n'
fi

printf 'Static validation passed.\n'
