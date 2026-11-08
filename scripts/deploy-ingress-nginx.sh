#!/usr/bin/env bash

# Install the pinned ingress-nginx kind provider manifest. Its controller runs
# on the node labelled ingress-ready=true and binds hostPorts 80 and 443, which
# cluster/kind-config.yaml publishes on the host. With minishop.local resolving
# to 127.0.0.1, http://minishop.local then reaches the chart Ingress without a
# port-forward. Re-running is safe: apply is idempotent for the same manifest.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

for command_name in curl kubectl sha256sum; do
  command -v "$command_name" >/dev/null || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

# v1.12.4 matches the controller already running in kind-learn. Upstream
# archived kubernetes/ingress-nginx in March 2026; see ADR 0011 before bumping.
# The checksum pins the manifest content, whose images are digest-pinned.
readonly INGRESS_NGINX_VERSION="v1.12.4"
readonly INGRESS_NGINX_MANIFEST_SHA256="458724636702c34320774f011e642b4a80212e2f79f98f14763fa06a3169cd93"
readonly INGRESS_NGINX_MANIFEST_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

require_context

ingress_nodes=$(kubectl_for_minishop get nodes --selector ingress-ready=true -o name)
if [[ -z "$ingress_nodes" ]]; then
  printf '%s\n' 'No node is labelled ingress-ready=true; create the cluster from cluster/kind-config.yaml.' >&2
  exit 1
fi

manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT
curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
  --output "$manifest" "$INGRESS_NGINX_MANIFEST_URL"
if ! printf '%s  %s\n' "$INGRESS_NGINX_MANIFEST_SHA256" "$manifest" | sha256sum --check --status; then
  printf 'ingress-nginx %s manifest checksum mismatch; refusing to apply it.\n' \
    "$INGRESS_NGINX_VERSION" >&2
  exit 1
fi

kubectl_for_minishop apply -f "$manifest"
kubectl_for_minishop -n ingress-nginx rollout status deployment/ingress-nginx-controller \
  --timeout=180s

# The admission patch Job injects the webhook CA. Until it does, the API server
# cannot call the webhook and rejects every Ingress create or update.
for attempt in {1..36}; do
  ca_bundle=$(kubectl_for_minishop get validatingwebhookconfiguration ingress-nginx-admission \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}')
  if [[ -n "$ca_bundle" ]]; then
    break
  fi
  if ((attempt == 36)); then
    printf '%s\n' 'The ingress-nginx admission webhook has no CA bundle after 180s.' >&2
    exit 1
  fi
  sleep 5
done

printf 'ingress-nginx %s is ready in context %s.\n' "$INGRESS_NGINX_VERSION" "$CONTEXT"
