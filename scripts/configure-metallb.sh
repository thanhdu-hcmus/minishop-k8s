#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"
require_context

if [[ -z ${METALLB_ADDRESS_POOL:-} ]]; then
  printf 'Set METALLB_ADDRESS_POOL to an unused range on the Kind Docker network.\n' >&2
  exit 1
fi

cat <<EOF | kubectl_for_minishop apply --filename -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: minishop-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_ADDRESS_POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: minishop-pool
  namespace: metallb-system
spec:
  ipAddressPools:
    - minishop-pool
EOF
