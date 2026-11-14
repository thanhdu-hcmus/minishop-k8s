#!/usr/bin/env bash
#
# Deploy the logging stack in manifests/40-logging (Issue #59, ADR 0017):
# the logging namespace and its NetworkPolicies, one-node Elasticsearch,
# Kibana, the retention (ILM) policy, and Filebeat with its cluster-wide
# read-only RBAC. Run scripts/deploy-eck.sh first. This changes the cluster;
# on kind-learn it needs the owner's approval. MiniShop is not touched.
#
# Usage:
#   bash scripts/deploy-logging.sh [--timeout SECONDS] [--context NAME] [--kubeconfig FILE]
#
# Order matters: Elasticsearch must accept the ILM policy before Filebeat
# starts, so Filebeat's index template links to the policy and Filebeat
# (setup.ilm.overwrite: false) never replaces it with its default. Re-running
# is safe: apply is idempotent and the policy PUT replaces the policy with the
# same content. No password is read or printed.
#   --timeout SECONDS    limit for each wait (default 600; first image pulls are slow)

set -euo pipefail
set +x

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=logging-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/logging-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  printf '%s\n' "$LOGGING_TARGET_USAGE" >&2
}

timeout=600
# LOGGING_CONTEXT and LOGGING_KUBECONFIG are read by logging-lib.sh.
# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout=${2:?--timeout needs a value}; shift 2 ;;
    --context) LOGGING_CONTEXT=${2:?--context needs a value}; shift 2 ;;
    --kubeconfig) LOGGING_KUBECONFIG=${2:?--kubeconfig needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive number of seconds"

logging_require_commands kubectl
logging_require_context
logging_eck_installed || die "ECK CRDs are missing; run scripts/deploy-eck.sh first"
[[ "$(logging_kubectl -n "$ECK_NAMESPACE" get statefulset elastic-operator \
  -o 'jsonpath={.status.readyReplicas}' 2>/dev/null)" == 1 ]] ||
  die "the ECK operator in $ECK_NAMESPACE is not ready; run scripts/deploy-eck.sh"
logging_check_api_cidr ||
  die "Filebeat could not reach the API server through its NetworkPolicy; nothing was applied"

printf 'Applying the logging namespace, NetworkPolicies, Elasticsearch and Kibana\n'
logging_kubectl apply -f "$LOGGING_MANIFESTS/namespace.yaml"
logging_kubectl apply \
  -f "$LOGGING_MANIFESTS/networkpolicy.yaml" \
  -f "$LOGGING_MANIFESTS/elasticsearch.yaml" \
  -f "$LOGGING_MANIFESTS/kibana.yaml"

# A one-node cluster with replica-free indices is green; yellow still serves
# reads and writes, so either is accepted.
logging_wait_health elasticsearch "$LOGGING_ES_NAME" "$timeout" 'green|yellow'

printf 'Applying ILM policy %s\n' "$LOGGING_ILM_POLICY"
logging_es_api PUT "/_ilm/policy/$LOGGING_ILM_POLICY" <"$LOGGING_MANIFESTS/ilm-policy.json" >/dev/null
policy=$(logging_es_api GET "/_ilm/policy/$LOGGING_ILM_POLICY?filter_path=*.policy.phases.delete.min_age" </dev/null)
[[ "$policy" == *'"min_age":"3d"'* ]] || die "ILM policy $LOGGING_ILM_POLICY has no 3d delete phase"

printf 'Applying Filebeat and its read-only cluster RBAC\n'
logging_kubectl apply -f "$LOGGING_MANIFESTS/filebeat-rbac.yaml"
logging_kubectl apply -f "$LOGGING_MANIFESTS/filebeat.yaml"

logging_wait_health kibana "$LOGGING_KIBANA_NAME" "$timeout" green
logging_wait_health beat "$LOGGING_BEAT_NAME" "$timeout" green

printf '%s\n' "Logging stack is deployed in context $LOGGING_CONTEXT." \
  "Check it with: bash scripts/validate-logging.sh" \
  "Kibana: kubectl -n $LOGGING_NAMESPACE port-forward service/${LOGGING_KIBANA_NAME}-kb-http 5601," \
  "then https://localhost:5601 as user elastic (see the operator guide for the password)."
