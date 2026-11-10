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

if helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set ingress.host=Not_A_Host >/dev/null 2>&1; then
  printf '%s\n' 'Chart schema accepted an invalid Ingress host.' >&2
  exit 1
fi

without_ingress=$(helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set ingress.enabled=false)
if grep -Eq '^kind: Ingress$|name: minishop-frontend-from-ingress$' <<<"$without_ingress"; then
  printf '%s\n' 'Disabling the Ingress still rendered its Ingress or NetworkPolicy.' >&2
  exit 1
fi

without_seed=$(helm_cli_for_minishop template minishop /chart --namespace webapp)
if grep -Eq '^kind: Job$|name: minishop-seed' <<<"$without_seed"; then
  printf '%s\n' 'The seed Job or its NetworkPolicy rendered without seed.enabled.' >&2
  exit 1
fi

printf '%s\n' 'Linting and rendering values.yaml with seed.enabled=true...'
helm_cli_for_minishop lint /chart --set seed.enabled=true
helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set seed.enabled=true >"$rendered"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 \
  -summary -strict -ignore-missing-schemas - <"$rendered"
for expected in '^kind: Job$' '^  name: minishop-seed-[0-9a-f]{8}$' \
  '^  name: minishop-seed$' '^  ttlSecondsAfterFinished: [0-9]+$' \
  '^  backoffLimit: [0-9]+$'; do
  if ! grep -Eq "$expected" "$rendered"; then
    printf 'Enabling the seed Job did not render %s.\n' "$expected" >&2
    exit 1
  fi
done

if helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set seed.enabled=yes >/dev/null 2>&1; then
  printf '%s\n' 'Chart schema accepted a non-boolean seed.enabled.' >&2
  exit 1
fi

printf '%s\n' 'Helm defaults, dev, prod, and seed values lint, render, and pass schema validation.'
