#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ -z "${MINISHOP_POSTGRES_PASSWORD:-}" || -z "${MINISHOP_REDIS_PASSWORD:-}" ]]; then
  printf '%s\n' 'MINISHOP_POSTGRES_PASSWORD and MINISHOP_REDIS_PASSWORD must be set.' >&2
  exit 1
fi

require_context

kubectl_for_minishop -n webapp create secret generic minishop-app-credentials \
  --from-literal=postgres-password="$MINISHOP_POSTGRES_PASSWORD" \
  --from-literal=redis-password="$MINISHOP_REDIS_PASSWORD" \
  --dry-run=client \
  -o yaml | kubectl_for_minishop apply -f -
