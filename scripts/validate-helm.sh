#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=helm-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/helm-lib.sh"

require_docker

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

for values_file in values.yaml values-dev.yaml values-prod.yaml; do
  printf 'Linting and rendering %s...\n' "$values_file"
  helm_cli_for_minishop lint /chart --values "/chart/$values_file"
  helm_cli_for_minishop template minishop /chart --namespace webapp \
    --values "/chart/$values_file" >"$rendered"
  docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 \
    -summary -strict -ignore-missing-schemas - <"$rendered"
done

if helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set images.backend.digest=mutable-tag >/dev/null 2>&1; then
  printf '%s\n' 'Chart schema accepted a non-digest backend image reference.' >&2
  exit 1
fi

printf '%s\n' 'Helm defaults, dev, and prod values lint, render, and pass schema validation.'
