#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"
require_context

kubectl_for_minishop apply --filename "$REPO_ROOT/manifests/00-namespaces/namespaces.yaml"
kubectl_for_minishop apply --filename "$REPO_ROOT/manifests/02-config-secrets/runtime-config.yaml"
if ! kubectl_for_minishop get secret postgres-creds --namespace data >/dev/null 2>&1; then
  "$REPO_ROOT/scripts/create-runtime-config.sh"
fi
kubectl_for_minishop get secret postgres-app-creds --namespace webapp >/dev/null
kubectl_for_minishop get configmap minishop-postgres-schema --namespace webapp >/dev/null
kubectl_for_minishop apply --filename "$REPO_ROOT/manifests/04-stateful/data.yaml"
kubectl_for_minishop rollout status statefulset/redis --namespace data --timeout=5m
kubectl_for_minishop wait cluster/minishop-postgres --namespace data --for=condition=Ready --timeout=10m
kubectl_for_minishop apply --filename "$REPO_ROOT/manifests/06-security/rbac.yaml"
kubectl_for_minishop apply --filename "$REPO_ROOT/manifests/03-workloads/app.yaml"
kubectl_for_minishop wait job/db-migration --namespace webapp --for=condition=complete --timeout=5m
kubectl_for_minishop rollout status deployment/backend --namespace webapp --timeout=5m
kubectl_for_minishop rollout status deployment/frontend --namespace webapp --timeout=5m
kubectl_for_minishop apply --filename "$REPO_ROOT/manifests/05-networking/ingress.yaml"
kubectl_for_minishop apply --filename "$REPO_ROOT/manifests/07-scaling/backend-hpa.yaml"
kubectl_for_minishop apply --filename "$REPO_ROOT/manifests/08-cronjobs/report-cronjob.yaml"

printf 'MiniShop core deployment completed.\n'
