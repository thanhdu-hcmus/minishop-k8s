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
# replaced by the same tag with its pinned digest. Re-running is safe: the
# CRDs use server-side apply and the operator manifest is applied as is.

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

# Pin the operator image by digest. The checksum fixed the file, so exactly
# one image line with the tag is expected; anything else stops the install.
image_line="image: \"$ECK_OPERATOR_IMAGE\""
[[ "$(grep -cF -- "$image_line" "$work/operator.yaml")" -eq 1 ]] ||
  die "expected one '$image_line' line in operator.yaml"
[[ "$(grep -c 'image:' "$work/operator.yaml")" -eq 1 ]] ||
  die "operator.yaml has an image line this script does not pin"
sed -i "s|$image_line|image: \"$ECK_OPERATOR_IMAGE@$ECK_OPERATOR_DIGEST\"|" "$work/operator.yaml"
grep -qF -- "$ECK_OPERATOR_IMAGE@$ECK_OPERATOR_DIGEST" "$work/operator.yaml" ||
  die "could not pin the operator image digest"

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

printf 'ECK %s is ready in context %s.\n' "$ECK_VERSION" "$LOGGING_CONTEXT"
