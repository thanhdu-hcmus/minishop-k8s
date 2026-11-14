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
#                  ECK CRDs. Refused while any resource of any
#                  *.k8s.elastic.co CRD exists outside the logging namespace,
#                  because deleting a CRD deletes every resource of that kind
#                  in the cluster. If the CRDs or their resources cannot be
#                  listed, the script stops before changing anything.
#
# Tested with a stubbed kubectl by scripts/test-teardown-logging.sh.
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

# Every *.k8s.elastic.co CRD in the cluster, however many there are: a
# partial or failed install must not skip the guard below. Any listing error
# stops the script before it changes anything (fail closed).
crd_list=$(logging_kubectl get crd -o name) || die "could not list CRDs; nothing was changed"
elastic_crds=$(sed -n 's|^customresourcedefinition\.apiextensions\.k8s\.io/||p' <<<"$crd_list" |
  grep -E '\.k8s\.elastic\.co$' || true)

# elastic_resources: "NAMESPACE CRD/NAME" for every resource of every Elastic
# CRD, listed per CRD (not through the "elastic" category, which a broken
# CRD may lack). Returns 1 if any listing fails.
elastic_resources() {
  local crd out
  for crd in $elastic_crds; do
    out=$(logging_kubectl get "$crd" --all-namespaces --no-headers \
      -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name') || return 1
    if [[ -n "$out" ]]; then
      awk -v crd="$crd" '{ print $1, crd "/" $2 }' <<<"$out"
    fi
  done
}

resources=""
if [[ -n "$elastic_crds" ]]; then
  resources=$(elastic_resources) || die "could not list Elastic resources; nothing was changed"
fi
others=$(awk -v ns="$LOGGING_NAMESPACE" '$1 != ns' <<<"$resources")

if [[ "$confirmed" != true ]]; then
  printf 'Dry run in context %s. With --yes this would delete:\n' "$LOGGING_CONTEXT"
  printf '  namespace %s and everything in it (logs, PVC, Secrets, NetworkPolicies)\n' "$LOGGING_NAMESPACE"
  printf '  ClusterRole and ClusterRoleBinding logging-filebeat\n'
  if [[ "$remove_eck" == true ]]; then
    printf '  the ECK %s operator (namespace %s, RBAC, webhook) and its CRDs (%s found)\n' \
      "$ECK_VERSION" "$ECK_NAMESPACE" "$(grep -c . <<<"$elastic_crds" || true)"
    if [[ -n "$others" ]]; then
      printf '  but --remove-eck would be refused: Elastic resources exist outside %s:\n' "$LOGGING_NAMESPACE"
      printf '    %s\n' "${others//$'\n'/$'\n'    }"
    fi
  fi
  if [[ -n "$resources" ]]; then
    printf 'Elastic resources:\n'
    printf '  %s\n' "${resources//$'\n'/$'\n'  }"
  else
    printf 'Elastic resources: none\n'
  fi
  printf 'Nothing was changed. Re-run with --yes to delete.\n'
  exit 0
fi

# Refuse --remove-eck before deleting anything if other Elastic resources
# depend on the CRDs: deleting a CRD deletes every resource of that kind.
if [[ "$remove_eck" == true && -n "$others" ]]; then
  die "Elastic resources exist outside $LOGGING_NAMESPACE; not removing ECK. Nothing was deleted:"$'\n'"$others"
fi

printf 'Deleting the logging stack in context %s\n' "$LOGGING_CONTEXT"
if logging_kubectl get namespace "$LOGGING_NAMESPACE" >/dev/null 2>&1; then
  # The operator removes each workload before its resource is gone. Only
  # kinds whose CRD exists are deleted.
  for target in "beats.beat.k8s.elastic.co $LOGGING_BEAT_NAME" \
    "kibanas.kibana.k8s.elastic.co $LOGGING_KIBANA_NAME" \
    "elasticsearches.elasticsearch.k8s.elastic.co $LOGGING_ES_NAME"; do
    if grep -qx -- "${target% *}" <<<"$elastic_crds"; then
      logging_kubectl -n "$LOGGING_NAMESPACE" delete "${target% *}" "${target#* }" \
        --ignore-not-found --wait=true --timeout=300s
    fi
  done
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
