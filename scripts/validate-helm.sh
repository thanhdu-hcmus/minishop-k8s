#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=helm-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/helm-lib.sh"

require_docker

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

for values_file in values.yaml values-dev.yaml values-prod.yaml; do
  printf 'Linting and rendering %s...\n' "$values_file"
  helm_cli_for_minishop lint /chart --values "/chart/$values_file"
  helm_cli_for_minishop template minishop /chart --namespace webapp \
    --values "/chart/$values_file" >"$rendered"
  docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 \
    -summary -strict -ignore-missing-schemas - <"$rendered"
done

if helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set images.backend.digest=mutable-tag >/dev/null 2>&1; then
  printf '%s\n' 'Chart schema accepted a non-digest backend image reference.' >&2
  exit 1
fi

if helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set ingress.host=Not_A_Host >/dev/null 2>&1; then
  printf '%s\n' 'Chart schema accepted an invalid Ingress host.' >&2
  exit 1
fi

without_ingress=$(helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set ingress.enabled=false)
if grep -Eq '^kind: Ingress$|name: minishop-frontend-from-ingress$' <<<"$without_ingress"; then
  printf '%s\n' 'Disabling the Ingress still rendered its Ingress or NetworkPolicy.' >&2
  exit 1
fi

without_seed=$(helm_cli_for_minishop template minishop /chart --namespace webapp)
if grep -Eq '^kind: Job$|name: minishop-seed' <<<"$without_seed"; then
  printf '%s\n' 'The seed Job or its NetworkPolicy rendered without seed.enabled.' >&2
  exit 1
fi

printf '%s\n' 'Linting and rendering values.yaml with seed.enabled=true...'
helm_cli_for_minishop lint /chart --set seed.enabled=true
helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set seed.enabled=true >"$rendered"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 \
  -summary -strict -ignore-missing-schemas - <"$rendered"
for expected in '^kind: Job$' '^  name: minishop-seed-[0-9a-f]{8}$' \
  '^  name: minishop-seed$' '^  ttlSecondsAfterFinished: [0-9]+$' \
  '^  backoffLimit: [0-9]+$'; do
  if ! grep -Eq "$expected" "$rendered"; then
    printf 'Enabling the seed Job did not render %s.\n' "$expected" >&2
    exit 1
  fi
done

if helm_cli_for_minishop template minishop /chart --namespace webapp \
  --set seed.enabled=yes >/dev/null 2>&1; then
  printf '%s\n' 'Chart schema accepted a non-boolean seed.enabled.' >&2
  exit 1
fi

# The data-tier NetworkPolicies (#40) render by default. Each selects only the
# chart's data Pods, denies all egress, and admits peers that match both the
# webapp namespace and a MiniShop pod label set in one `from` entry; the seed
# peer appears only with seed.enabled.
data_policies() { # extra helm arguments
  helm_cli_for_minishop template minishop /chart --namespace webapp \
    --show-only templates/networkpolicy.yaml "$@" |
    awk 'BEGIN { RS = "\n---\n" } /\n  namespace: data\n/ { print "---"; print }'
}

expect_count() { # description expected-count extended-regex text
  local found
  found=$(grep -Ec -- "$3" <<<"$4" || true)
  if [[ "$found" != "$2" ]]; then
    printf 'Data NetworkPolicies: expected %s %s, found %s.\n' "$2" "$1" "$found" >&2
    exit 1
  fi
}

for seed in false true; do
  rendered_data=$(data_policies --set "seed.enabled=$seed")
  peers=1
  [[ "$seed" == true ]] && peers=2
  expect_count "data-namespace policies (seed=$seed)" 2 '^kind: NetworkPolicy$' "$rendered_data"
  expect_count "minishop-postgresql policies" 1 '^  name: minishop-postgresql$' "$rendered_data"
  expect_count "minishop-redis policies" 1 '^  name: minishop-redis$' "$rendered_data"
  expect_count "PostgreSQL Pod selectors" 1 '^      app.kubernetes.io/name: minishop-postgresql$' "$rendered_data"
  expect_count "Redis Pod selectors" 1 '^      app.kubernetes.io/name: minishop-redis$' "$rendered_data"
  expect_count "Egress policy types" 2 '^    - Egress$' "$rendered_data"
  expect_count "egress rules" 0 '^  egress:' "$rendered_data"
  expect_count "port 5432 rules" 1 '^          port: 5432$' "$rendered_data"
  expect_count "port 6379 rules" 1 '^          port: 6379$' "$rendered_data"
  expect_count "namespace-scoped peers (seed=$seed)" $((2 * peers)) \
    '^        - namespaceSelector:$' "$rendered_data"
  expect_count "webapp namespace selectors (seed=$seed)" $((2 * peers)) \
    '^              kubernetes.io/metadata.name: webapp$' "$rendered_data"
  expect_count "peers without a namespaceSelector" 0 '^ +- (podSelector|ipBlock):' "$rendered_data"
  expect_count "backend peers" 2 '^              app.kubernetes.io/component: minishop-backend$' "$rendered_data"
  expect_count "seed peers (seed=$seed)" $((2 * (peers - 1))) \
    '^              app.kubernetes.io/component: seed$' "$rendered_data"
  # Every peer (backend and seed) carries the full MiniShop label set.
  expect_count "peer name=minishop labels (seed=$seed)" $((2 * peers)) \
    '^              app.kubernetes.io/name: minishop$' "$rendered_data"
  expect_count "peer part-of=minishop labels (seed=$seed)" $((2 * peers)) \
    '^              app.kubernetes.io/part-of: minishop$' "$rendered_data"
  # One `from` rule per policy and no other list item at rule level, so an
  # empty (allow-all) ingress rule fails.
  expect_count "ingress from rules" 2 '^    - from:$' "$rendered_data"
  expect_count "Ingress policy types" 2 '^    - Ingress$' "$rendered_data"
  expect_count "rule-level list items (2 policyTypes + 1 rule per policy)" 6 '^    - ' "$rendered_data"
done

printf '%s\n' 'Helm defaults, dev, prod, and seed values lint, render, and pass schema validation.'
