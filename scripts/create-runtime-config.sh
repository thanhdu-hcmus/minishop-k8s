#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"
require_context

if [[ -z ${POSTGRES_PASSWORD:-} ]]; then
  if kubectl_for_minishop get secret postgres-creds --namespace data >/dev/null 2>&1; then
    printf 'postgres-creds already exists. Set POSTGRES_PASSWORD to update runtime configuration.\n' >&2
    exit 1
  fi
  POSTGRES_PASSWORD=$(openssl rand -base64 32)
fi

if [[ -z $POSTGRES_PASSWORD ]]; then
  printf 'POSTGRES_PASSWORD must not be empty.\n' >&2
  exit 1
fi

kubectl_for_minishop create secret generic postgres-creds --namespace data \
  --from-literal=username=kumademo \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --type=kubernetes.io/basic-auth \
  --dry-run=client --output=yaml | kubectl_for_minishop apply --filename -
kubectl_for_minishop create secret generic postgres-app-creds --namespace webapp \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --dry-run=client --output=yaml | kubectl_for_minishop apply --filename -
kubectl_for_minishop create configmap minishop-postgres-schema --namespace webapp \
  --from-file=database.sql="$REPO_ROOT/vendor/kuma-demo/database.sql" \
  --dry-run=client --output=yaml | kubectl_for_minishop apply --filename -

printf 'Runtime Secrets and schema ConfigMap applied.\n'
