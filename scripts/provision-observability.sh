#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"
require_context

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 69.8.2 \
  --wait --timeout 10m

kubectl_for_minishop apply --filename "$REPO_ROOT/manifests/09-observability/backend-monitoring.yaml"
