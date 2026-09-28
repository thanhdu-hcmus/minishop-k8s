#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

command -v kubectl >/dev/null || {
  printf '%s\n' 'Missing required command: kubectl' >&2
  exit 1
}
command -v docker >/dev/null || {
  printf '%s\n' 'Missing required command: docker' >&2
  exit 1
}

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

validate_kustomization() {
  local name=$1
  local path=$2

  kubectl kustomize "$path" --load-restrictor LoadRestrictionsNone >"$rendered"
  printf 'Validating %s...\n' "$name"
  docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 \
    -summary -strict -ignore-missing-schemas - <"$rendered"
}

validate_kustomization dev "$REPO_ROOT/kustomize/overlays/dev"
validate_kustomization prod "$REPO_ROOT/kustomize/overlays/prod"
validate_kustomization dev-teardown "$REPO_ROOT/kustomize/teardown/dev"

printf '%s\n' 'Kustomize overlays and dev teardown render and validate.'
