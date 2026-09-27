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

for overlay in dev prod; do
  kubectl kustomize "$REPO_ROOT/kustomize/overlays/$overlay" \
    --load-restrictor LoadRestrictionsNone >"$rendered"
  printf 'Validating %s overlay...\n' "$overlay"
  docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 \
    -summary -strict -ignore-missing-schemas - <"$rendered"
done

printf '%s\n' 'Dev and prod Kustomize overlays rendered and validated.'
