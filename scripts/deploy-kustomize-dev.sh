#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_existing_secrets() {
  local namespace
  local secret_name
  local namespace_name
  local existing_secret
  local missing_secrets=()

  for namespace in data webapp; do
    if [[ "$namespace" == data ]]; then
      secret_name=minishop-data-credentials
    else
      secret_name=minishop-app-credentials
    fi

    namespace_name=$(kubectl_for_minishop get namespace "$namespace" \
      --ignore-not-found -o 'jsonpath={.metadata.name}')
    if [[ -z "$namespace_name" ]]; then
      missing_secrets+=("$namespace/$secret_name")
      continue
    fi

    existing_secret=$(kubectl_for_minishop -n "$namespace" get secret "$secret_name" \
      --ignore-not-found -o 'jsonpath={.metadata.name}')
    if [[ -z "$existing_secret" ]]; then
      missing_secrets+=("$namespace/$secret_name")
    fi
  done

  if ((${#missing_secrets[@]} > 0)); then
    printf 'Required Secret object(s) missing: %s\n' "${missing_secrets[*]}" >&2
    return 1
  fi
}

if [[ -n "${MINISHOP_POSTGRES_PASSWORD:-}" && -z "${MINISHOP_REDIS_PASSWORD:-}" ]] || \
  [[ -z "${MINISHOP_POSTGRES_PASSWORD:-}" && -n "${MINISHOP_REDIS_PASSWORD:-}" ]]; then
  printf '%s\n' 'Set both runtime password inputs together, or leave both unset to reuse existing Secrets.' >&2
  exit 1
fi

"$SCRIPT_DIR/validate-kustomize.sh"
require_context

if [[ -n "${MINISHOP_POSTGRES_PASSWORD:-}" ]]; then
  kubectl_for_minishop apply \
    -f "$REPO_ROOT/manifests/10-data/namespace.yaml" \
    -f "$REPO_ROOT/manifests/20-webapp/namespace.yaml"
  bash "$SCRIPT_DIR/create-data-credentials.sh"
  bash "$SCRIPT_DIR/create-app-credentials.sh"
else
  require_existing_secrets
fi

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

kubectl kustomize "$REPO_ROOT/kustomize/overlays/dev" \
  --load-restrictor LoadRestrictionsNone >"$rendered"
kubectl_for_minishop apply -f "$rendered"

kubectl_for_minishop -n data rollout status statefulset/minishop-postgresql --timeout=180s
kubectl_for_minishop -n data rollout status statefulset/minishop-redis --timeout=180s
kubectl_for_minishop -n webapp rollout status deployment/minishop-backend --timeout=180s
kubectl_for_minishop -n webapp rollout status deployment/minishop-frontend --timeout=180s

hpa_minimum=$(kubectl_for_minishop -n webapp get hpa minishop-backend \
  --ignore-not-found -o jsonpath='{.spec.minReplicas}')
if [[ -n "$hpa_minimum" ]]; then
  printf 'Waiting for the platform HPA minimum of %s backend replicas.\n' "$hpa_minimum"
  for attempt in {1..36}; do
    ready_replicas=$(kubectl_for_minishop -n webapp get deployment minishop-backend \
      -o jsonpath='{.status.readyReplicas}')
    ready_replicas=${ready_replicas:-0}
    if (( ready_replicas >= hpa_minimum )); then
      break
    fi
    if (( attempt == 36 )); then
      printf 'Backend did not reach the platform HPA minimum (%s ready).\n' \
        "$ready_replicas" >&2
      exit 1
    fi
    sleep 5
  done
  printf 'The active platform HPA keeps the backend at %s or more replicas.\n' \
    "$hpa_minimum"
fi

printf '%s\n' 'MiniShop dev overlay deployed; run bash scripts/validate-app.sh for end-to-end verification.'
