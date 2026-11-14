#!/usr/bin/env bash
#
# Install the pinned ECK (Elastic Cloud on Kubernetes) operator and its CRDs
# (Issue #59, ADR 0017). This changes the cluster: it adds ten cluster-wide
# CRDs, the elastic-system namespace, cluster-wide RBAC for the operator, and
# a validating webhook. Run it on kind-learn only with the owner's approval.
#
# Usage:
#   bash scripts/deploy-eck.sh [--context NAME] [--kubeconfig FILE]
#
# Both manifests come from Elastic's download host and are refused unless
# their SHA-256 matches the pinned value. The operator image tag is then
# replaced by the same tag with its pinned digest, and the operator's
# eck.yaml gets `namespaces: [logging]`, so it watches, caches and reconciles
# only logging (and elastic-system). That does not narrow its cluster-wide
# RBAC (ADR 0017). Re-running is safe: the CRDs use server-side apply and the
# operator manifest is applied as patched.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=logging-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/logging-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  printf '%s\n' "$LOGGING_TARGET_USAGE" >&2
}

# LOGGING_CONTEXT and LOGGING_KUBECONFIG are read by logging-lib.sh.
# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) LOGGING_CONTEXT=${2:?--context needs a value}; shift 2 ;;
    --kubeconfig) LOGGING_KUBECONFIG=${2:?--kubeconfig needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

logging_require_commands curl kubectl sha256sum
logging_require_context

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
logging_download crds.yaml "$ECK_CRDS_SHA256" "$work/crds.yaml"
logging_download operator.yaml "$ECK_OPERATOR_SHA256" "$work/operator.yaml"

# Pin the operator image by digest and limit the namespaces it manages to
# logging (exact-match edits; see logging_patch_operator).
logging_patch_operator "$work/operator.yaml"

printf 'Installing ECK %s CRDs in context %s\n' "$ECK_VERSION" "$LOGGING_CONTEXT"
# The CRDs are too large for client-side apply's last-applied annotation.
# This script is their only manager, so it takes ownership of every field.
logging_kubectl apply --server-side --force-conflicts --field-manager=minishop-deploy-eck \
  -f "$work/crds.yaml"
logging_kubectl wait --for=condition=Established --timeout=120s \
  crd -l app.kubernetes.io/name=eck-operator-crds
logging_eck_installed || die "expected $ECK_CRD_COUNT established ECK CRDs"

printf 'Installing the ECK %s operator\n' "$ECK_VERSION"
logging_kubectl apply -f "$work/operator.yaml"
logging_kubectl -n "$ECK_NAMESPACE" rollout status statefulset/elastic-operator --timeout=300s

running_image=$(logging_kubectl -n "$ECK_NAMESPACE" get statefulset elastic-operator \
  -o 'jsonpath={.spec.template.spec.containers[?(@.name=="manager")].image}')
[[ "$running_image" == "$ECK_OPERATOR_IMAGE@$ECK_OPERATOR_DIGEST" ]] ||
  die "the operator runs $running_image, not the pinned digest"

# The applied ConfigMap carries the namespace scope, and the running operator
# logs it when it starts (it restarts itself if the file changed).
operator_config=$(logging_kubectl -n "$ECK_NAMESPACE" get configmap elastic-operator \
  -o 'jsonpath={.data.eck\.yaml}')
grep -qxF -- "namespaces: $ECK_MANAGED_NAMESPACES" <<<"$operator_config" ||
  die "the operator ConfigMap does not set namespaces: $ECK_MANAGED_NAMESPACES"
for attempt in {1..24}; do
  operator_log=$(logging_kubectl -n "$ECK_NAMESPACE" logs statefulset/elastic-operator 2>/dev/null) ||
    operator_log=""
  scope=$(grep 'Operator configured to manage' <<<"$operator_log" | tail -n 1) || scope=""
  [[ "$scope" == *"\"namespaces\":[\"$LOGGING_NAMESPACE\"]"* ]] && break
  ((attempt < 24)) || die "the operator did not report managing namespaces $ECK_MANAGED_NAMESPACES within 120s"
  sleep 5
done
printf 'The operator manages namespaces %s (plus %s); its RBAC is still cluster-wide.\n' \
  "$ECK_MANAGED_NAMESPACES" "$ECK_NAMESPACE"

printf 'ECK %s is ready in context %s.\n' "$ECK_VERSION" "$LOGGING_CONTEXT"
