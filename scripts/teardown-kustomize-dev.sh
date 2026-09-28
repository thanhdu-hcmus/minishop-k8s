#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_context

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

kubectl kustomize "$REPO_ROOT/kustomize/teardown/dev" \
  --load-restrictor LoadRestrictionsNone >"$rendered"
kubectl_for_minishop delete --ignore-not-found=true --wait=true -f "$rendered"

printf '%s\n' 'MiniShop runtime resources removed; namespaces, secrets, PVCs, shared storage, and platform resources were retained.'
