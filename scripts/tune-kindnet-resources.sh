#!/usr/bin/env bash
#
# Replace the resources and priority of the kind-provided kindnet DaemonSet
# (Issue #50).
#
# The node image kindest/node:v1.30.13 (kind v0.29.0) ships kindnet with
# requests = limits = 100m CPU / 50Mi memory and no priorityClassName. The
# kindnetd binary is 80 MB of file-backed code; once its page cache is charged
# to the container, the 50Mi cap forces constant reclaim and refault of that
# code, the 100m CPU cap throttles the reclaim, and kindnetd's iptables children
# (-S, -C) crawl while holding /run/xtables.lock. kube-proxy and the portmap CNI
# plugin then time out. Upstream kind removed both limits in v0.33.0
# (kubernetes-sigs/kind#4215; PRs #4220 and #4223, merged 2026-07-22) and has
# set priorityClassName system-node-critical since v0.30.0.
#
# Without limits equal to requests the Pod leaves Guaranteed QoS, so the patch
# also sets system-node-critical to keep it from being an early OOM victim.
# A DaemonSet that already has no limits (kind v0.33.0 or later) is left alone.
#
# kind applies the CNI manifest only when it creates a cluster, so the patched
# DaemonSet survives Docker and node container restarts.
#
# Usage:
#   bash scripts/tune-kindnet-resources.sh           # check only, changes nothing
#   bash scripts/tune-kindnet-resources.sh --apply   # patch and wait for rollout

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

readonly NAMESPACE=kube-system
readonly DAEMONSET=kindnet
readonly CONTAINER=kindnet-cni
readonly IMAGE_PREFIX=docker.io/kindest/kindnetd:
# The image the values below were measured against (resident heap about 13 MiB
# plus up to 80 MB of binary page cache).
readonly MEASURED_IMAGE=docker.io/kindest/kindnetd:v20250512-df8de77b
readonly CPU_REQUEST=100m
readonly MEMORY_REQUEST=128Mi
readonly MEMORY_LIMIT=256Mi
readonly PRIORITY_CLASS=system-node-critical
readonly ROLLOUT_TIMEOUT=180s

usage() {
  printf 'Usage: %s [--apply]\n' "$0" >&2
}

mode=check
case "${1:-}" in
  '') ;;
  --apply) mode=apply ;;
  -h | --help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage; exit 2; }

ds_field() {
  kubectl_for_minishop -n "$NAMESPACE" get daemonset "$DAEMONSET" -o "jsonpath=$1"
}

require_context

# Fail closed: refuse to patch anything that is not the kind-provided kindnet.
containers=$(ds_field '{.spec.template.spec.containers[*].name}') || {
  printf 'Could not read DaemonSet %s/%s (missing, or API error)\n' \
    "$NAMESPACE" "$DAEMONSET" >&2
  exit 1
}
if [[ "$containers" != "$CONTAINER" ]]; then
  printf 'Expected one container %s in %s/%s, found: %s\n' \
    "$CONTAINER" "$NAMESPACE" "$DAEMONSET" "$containers" >&2
  exit 1
fi
image=$(ds_field '{.spec.template.spec.containers[0].image}')
if [[ "$image" != "$IMAGE_PREFIX"* ]]; then
  printf 'Refusing: %s/%s runs %s, not %s*\n' "$NAMESPACE" "$DAEMONSET" "$image" "$IMAGE_PREFIX" >&2
  exit 1
fi
if [[ "$image" != "$MEASURED_IMAGE" ]]; then
  printf 'Warning: values were measured on %s; this cluster runs %s.\n' "$MEASURED_IMAGE" "$image" >&2
fi

current=$(ds_field '{.spec.template.spec.containers[0].resources}')
priority=$(ds_field '{.spec.template.spec.priorityClassName}')
printf 'Image:     %s\n' "$image"
printf 'Current:   %s; priorityClassName=%s\n' "${current:-<none>}" "${priority:-<none>}"
printf 'Desired:   requests cpu=%s memory=%s; limits memory=%s, no CPU limit; priorityClassName=%s\n' \
  "$CPU_REQUEST" "$MEMORY_REQUEST" "$MEMORY_LIMIT" "$PRIORITY_CLASS"

limit_cpu=$(ds_field '{.spec.template.spec.containers[0].resources.limits.cpu}')
limit_memory=$(ds_field '{.spec.template.spec.containers[0].resources.limits.memory}')
if [[ "$(ds_field '{.spec.template.spec.containers[0].resources.requests.cpu}')" == "$CPU_REQUEST" &&
  "$(ds_field '{.spec.template.spec.containers[0].resources.requests.memory}')" == "$MEMORY_REQUEST" &&
  "$limit_memory" == "$MEMORY_LIMIT" && -z "$limit_cpu" && "$priority" == "$PRIORITY_CLASS" ]]; then
  printf 'kindnet resources and priority are already tuned; nothing to do.\n'
  exit 0
fi
# kind v0.33.0 and later ship kindnet without limits; do not add one back.
if [[ -z "$limit_cpu" && -z "$limit_memory" ]]; then
  printf 'kindnet has no resource limits (the kind v0.33.0+ manifest); nothing to do.\n'
  if [[ "$priority" != "$PRIORITY_CLASS" ]]; then
    printf 'Warning: priorityClassName is %s, not %s.\n' "${priority:-<none>}" "$PRIORITY_CLASS" >&2
  fi
  exit 0
fi

# The test operation makes the patch fail instead of editing another container
# if the DaemonSet changed between the checks above and the patch. "add"
# replaces priorityClassName if it is already set.
patch=$(printf '[{"op":"test","path":"/spec/template/spec/containers/0/name","value":"%s"},{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"%s","memory":"%s"},"limits":{"memory":"%s"}}},{"op":"add","path":"/spec/template/spec/priorityClassName","value":"%s"}]' \
  "$CONTAINER" "$CPU_REQUEST" "$MEMORY_REQUEST" "$MEMORY_LIMIT" "$PRIORITY_CLASS")

result=$(kubectl_for_minishop -n "$NAMESPACE" patch daemonset "$DAEMONSET" --type=json \
  -p "$patch" --dry-run=server \
  -o 'jsonpath={.spec.template.spec.containers[0].resources}; priorityClassName={.spec.template.spec.priorityClassName}')
printf 'Server dry-run result: %s\n' "$result"

if [[ "$mode" != apply ]]; then
  printf 'Check only; nothing changed. Re-run with --apply to patch and roll out kindnet.\n'
  exit 0
fi

kubectl_for_minishop -n "$NAMESPACE" patch daemonset "$DAEMONSET" --type=json -p "$patch"
if ! kubectl_for_minishop -n "$NAMESPACE" rollout status daemonset "$DAEMONSET" \
  --timeout="$ROLLOUT_TIMEOUT"; then
  printf 'kindnet rollout did not finish within %s. Inspect it with\n' "$ROLLOUT_TIMEOUT" >&2
  printf '  KUBECONFIG=%s kubectl --context %s -n %s get pods -l app=kindnet -o wide\n' \
    "$KUBECONFIG" "$CONTEXT" "$NAMESPACE" >&2
  printf 'and roll back with\n  KUBECONFIG=%s kubectl --context %s -n %s rollout undo daemonset %s\n' \
    "$KUBECONFIG" "$CONTEXT" "$NAMESPACE" "$DAEMONSET" >&2
  exit 1
fi
printf 'kindnet resources and priority tuned and rolled out on every node.\n'
