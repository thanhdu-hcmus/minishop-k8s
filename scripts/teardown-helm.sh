#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MINISHOP_KUBECONFIG=${MINISHOP_KUBECONFIG:-${KUBECONFIG:-}}
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=helm-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/helm-lib.sh"

require_helm_prerequisites
require_helm_cluster

helm_for_minishop uninstall minishop --namespace webapp --wait

printf '%s\n' 'MiniShop Helm runtime removed; namespaces, Secrets, PVCs, storage, and platform resources were retained.'
