#!/usr/bin/env bash
#
# Remove the logging stack (Issue #59, ADR 0017). THIS DELETES DATA: every
# log stored in Elasticsearch is lost with its volume. MiniShop (webapp,
# data), monitoring and every other namespace are not touched.
#
# Usage:
#   bash scripts/teardown-logging.sh --yes [--remove-eck] [--context NAME] [--kubeconfig FILE]
#
#   --yes          required; without it the script lists what it would delete
#                  and changes nothing
#   --remove-eck   also remove the ECK operator, its webhook, its RBAC and the
#                  ten ECK CRDs. Refused while any Elastic resource exists
#                  outside the logging namespace, because deleting a CRD
#                  deletes every resource of that kind in the cluster.
#
# Steps: delete the Beat, Kibana and Elasticsearch resources so ECK removes
# their workloads, then the logging namespace (its PVC, Secrets and
# NetworkPolicies go with it) and Filebeat's ClusterRole and binding.
# Filebeat's registry stays on each node in ECK's hostPath
# /var/lib/logging/filebeat/filebeat-data; a later deploy resumes from it.
# Re-running is safe: missing objects are skipped.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=logging-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/logging-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  printf '%s\n' "$LOGGING_TARGET_USAGE" >&2
}

confirmed=false
remove_eck=false
# LOGGING_CONTEXT and LOGGING_KUBECONFIG are read by logging-lib.sh.
# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) confirmed=true; shift ;;
    --remove-eck) remove_eck=true; shift ;;
    --context) LOGGING_CONTEXT=${2:?--context needs a value}; shift 2 ;;
    --kubeconfig) LOGGING_KUBECONFIG=${2:?--kubeconfig needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

logging_require_commands kubectl
logging_require_context

eck_present=false
logging_eck_installed && eck_present=true

if [[ "$confirmed" != true ]]; then
  printf 'Dry run in context %s. With --yes this would delete:\n' "$LOGGING_CONTEXT"
  printf '  namespace %s and everything in it (logs, PVC, Secrets, NetworkPolicies)\n' "$LOGGING_NAMESPACE"
  printf '  ClusterRole and ClusterRoleBinding logging-filebeat\n'
  if [[ "$remove_eck" == true ]]; then
    printf '  the ECK %s operator (namespace %s, RBAC, webhook) and its CRDs\n' "$ECK_VERSION" "$ECK_NAMESPACE"
  fi
  if [[ "$eck_present" == true ]]; then
    logging_kubectl -n "$LOGGING_NAMESPACE" get elastic 2>/dev/null || true
  fi
  printf 'Nothing was changed. Re-run with --yes to delete.\n'
  exit 0
fi

# Refuse --remove-eck before deleting anything if other Elastic resources
# depend on the CRDs.
if [[ "$remove_eck" == true && "$eck_present" == true ]]; then
  others=$(logging_kubectl get elastic --all-namespaces --no-headers \
    -o 'custom-columns=NS:.metadata.namespace,KIND:.kind,NAME:.metadata.name' |
    awk -v ns="$LOGGING_NAMESPACE" '$1 != ns') ||
    die "could not list Elastic resources; nothing was deleted"
  [[ -z "$others" ]] ||
    die "Elastic resources exist outside $LOGGING_NAMESPACE; not removing ECK. Nothing was deleted:"$'\n'"$others"
fi

printf 'Deleting the logging stack in context %s\n' "$LOGGING_CONTEXT"
if [[ "$eck_present" == true ]] && logging_kubectl get namespace "$LOGGING_NAMESPACE" >/dev/null 2>&1; then
  # The operator removes each workload before its resource is gone.
  logging_kubectl -n "$LOGGING_NAMESPACE" delete \
    -f "$LOGGING_MANIFESTS/filebeat.yaml" \
    -f "$LOGGING_MANIFESTS/kibana.yaml" \
    -f "$LOGGING_MANIFESTS/elasticsearch.yaml" \
    --ignore-not-found --wait=true --timeout=300s
fi
logging_kubectl delete namespace "$LOGGING_NAMESPACE" --ignore-not-found --wait=true --timeout=300s
logging_kubectl delete clusterrolebinding logging-filebeat --ignore-not-found
logging_kubectl delete clusterrole logging-filebeat --ignore-not-found

if [[ "$remove_eck" == true ]]; then
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
  # Delete exactly what deploy-eck.sh installed, from the same verified files.
  logging_download operator.yaml "$ECK_OPERATOR_SHA256" "$work/operator.yaml"
  logging_download crds.yaml "$ECK_CRDS_SHA256" "$work/crds.yaml"
  printf 'Removing the ECK %s operator and CRDs\n' "$ECK_VERSION"
  logging_kubectl delete -f "$work/operator.yaml" --ignore-not-found --wait=true --timeout=300s
  logging_kubectl delete -f "$work/crds.yaml" --ignore-not-found --wait=true --timeout=300s
fi

if logging_kubectl get namespace "$LOGGING_NAMESPACE" >/dev/null 2>&1; then
  die "namespace $LOGGING_NAMESPACE still exists"
fi
printf 'Logging stack removed from context %s.%s\n' "$LOGGING_CONTEXT" \
  "$([[ "$remove_eck" == true ]] && printf ' ECK removed.' || printf ' ECK kept.')"
