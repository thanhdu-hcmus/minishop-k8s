#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"

for command_name in docker kind kubectl helm; do
  command -v "$command_name" >/dev/null || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

docker info --format '{{.ServerVersion}}' >/dev/null
kind version >/dev/null
kubectl version --client >/dev/null
helm version --short >/dev/null

printf 'Preflight passed for context %s.\n' "$CONTEXT"
