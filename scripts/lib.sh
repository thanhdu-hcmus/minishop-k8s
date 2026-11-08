#!/usr/bin/env bash

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export KUBECONFIG="$REPO_ROOT/.kube/config"
readonly CLUSTER_NAME=learn
readonly CONTEXT="kind-${CLUSTER_NAME}"

kubectl_for_minishop() {
  kubectl --context "$CONTEXT" "$@"
}

require_context() {
  kubectl config get-contexts "$CONTEXT" --no-headers | grep -q .
  kubectl_for_minishop cluster-info >/dev/null
}

# Host routed by the Git-owned Ingress webapp/minishop (chart values and
# manifests/20-webapp/ingress.yaml).
readonly MINISHOP_INGRESS_HOST=minishop.local

# ingress-nginx admission rejects a second Ingress for the same host and path,
# which would stop a Helm upgrade part-way. Fail before anything is applied.
require_no_conflicting_ingress() {
  local conflicts
  conflicts=$(kubectl_for_minishop get ingress --all-namespaces -o \
    'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.rules[*].host}{"\n"}{end}' |
    awk -v host="$MINISHOP_INGRESS_HOST" '$1 != "webapp/minishop" {
      for (i = 2; i <= NF; i++) if ($i == host) { print $1; next }
    }') || {
    printf '%s\n' 'Could not list Ingresses to check for a host conflict.' >&2
    return 1
  }
  if [[ -n "$conflicts" ]]; then
    printf 'Ingress %s already routes %s; retire it first (docs/legacy-retirement-runbook.md).\n' \
      "${conflicts//$'\n'/ }" "$MINISHOP_INGRESS_HOST" >&2
    return 1
  fi
}
