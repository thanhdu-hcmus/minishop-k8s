#!/usr/bin/env bash

MINISHOP_HELM_IMAGE=alpine/helm:3.17.3
MINISHOP_KUBECONFIG=${MINISHOP_KUBECONFIG:-"${KUBECONFIG:-$REPO_ROOT/.kube/config}"}

require_docker() {
  command -v docker >/dev/null || {
    printf '%s\n' 'Missing required command: docker' >&2
    return 1
  }
}

require_helm_prerequisites() {
  require_docker
  command -v kubectl >/dev/null || {
    printf '%s\n' 'Missing required command: kubectl' >&2
    return 1
  }
  [[ -r "$MINISHOP_KUBECONFIG" ]] || {
    printf '%s\n' 'Kubeconfig is not readable; set MINISHOP_KUBECONFIG to its path.' >&2
    return 1
  }
}

helm_cli_for_minishop() {
  docker run --rm \
    --volume "$REPO_ROOT/charts/minishop:/chart:ro" \
    "$MINISHOP_HELM_IMAGE" "$@"
}

helm_for_minishop() {
  docker run --rm --network host \
    --volume "$MINISHOP_KUBECONFIG:/root/.kube/config:ro" \
    --volume "$REPO_ROOT/charts/minishop:/chart:ro" \
    --env KUBECONFIG=/root/.kube/config \
    "$MINISHOP_HELM_IMAGE" --kube-context "$CONTEXT" "$@"
}

kubectl_for_minishop() {
  KUBECONFIG="$MINISHOP_KUBECONFIG" kubectl --context "$CONTEXT" "$@"
}

require_helm_cluster() {
  kubectl_for_minishop config get-contexts "$CONTEXT" --no-headers | grep -q .
  kubectl_for_minishop cluster-info >/dev/null
}

require_runtime_prerequisites() {
  local namespace
  local existing
  local hpa_minimum
  local missing=()

  for namespace in data webapp; do
    existing=$(kubectl_for_minishop get namespace "$namespace" --ignore-not-found \
      -o 'jsonpath={.metadata.name}')
    if [[ -z "$existing" ]]; then
      missing+=("namespace/$namespace")
    fi
  done

  existing=$(kubectl_for_minishop -n data get secret minishop-data-credentials \
    --ignore-not-found -o 'jsonpath={.metadata.name}')
  if [[ -z "$existing" ]]; then
    missing+=("data/secret/minishop-data-credentials")
  fi
  existing=$(kubectl_for_minishop -n webapp get secret minishop-app-credentials \
    --ignore-not-found -o 'jsonpath={.metadata.name}')
  if [[ -z "$existing" ]]; then
    missing+=("webapp/secret/minishop-app-credentials")
  fi
  existing=$(kubectl_for_minishop -n webapp get serviceaccount minishop-backend \
    --ignore-not-found -o 'jsonpath={.metadata.name}')
  if [[ -z "$existing" ]]; then
    missing+=("webapp/serviceaccount/minishop-backend")
  fi

  if ((${#missing[@]} > 0)); then
    printf 'Required pre-existing runtime prerequisite(s) missing: %s\n' \
      "${missing[*]}" >&2
    return 1
  fi

  hpa_minimum=$(kubectl_for_minishop -n webapp get hpa minishop-backend \
    --ignore-not-found -o jsonpath='{.spec.minReplicas}')
  if [[ ! "$hpa_minimum" =~ ^[0-9]+$ ]] || ((hpa_minimum < 3)); then
    printf '%s\n' 'The pre-existing minishop-backend HPA must have minReplicas of at least 3.' >&2
    return 1
  fi
}

require_kustomize_handoff() {
  local existing
  for existing in \
    "data/statefulset/minishop-postgresql" \
    "data/statefulset/minishop-redis" \
    "webapp/deployment/minishop-backend" \
    "webapp/deployment/minishop-frontend"; do
    local namespace=${existing%%/*}
    local resource=${existing#*/}
    local resource_name
    resource_name=$(kubectl_for_minishop -n "$namespace" get "$resource" \
      --ignore-not-found -o 'jsonpath={.metadata.name}')
    if [[ -n "$resource_name" ]]; then
      printf 'Kustomize runtime is still present (%s); run scripts/migrate-kustomize-to-helm.sh first.\n' \
        "$existing" >&2
      return 1
    fi
  done
}
