#!/usr/bin/env bash
#
# Test the data-tier NetworkPolicies (Issue #40, part 4) on a throwaway kind
# cluster. The cluster has its own name, its own kubeconfig file in a private
# scratch directory, and the node image cluster/kind-config.yaml pins, so it
# runs the same kindnet (with its kube-network-policies controller) as
# kind-learn. kind-learn and ./.kube/config are never used. The cluster is
# deleted on exit.
#
# Usage:
#   bash scripts/test-data-network-policy.sh [--keep-cluster]
#       Deploys the chart's PostgreSQL, Redis, backend, seed Job and
#       NetworkPolicy templates with random throwaway passwords, plus a
#       stand-in for the legacy redis-0 in data, and checks that:
#       - the seed Job completes and the backend serves /ready, /items and
#         /items/<index>/reviews (allowed paths);
#       - a Pod in webapp without backend labels, Pods in another namespace
#         (with and without backend labels) and a Pod in data cannot open
#         TCP 5432 or 6379 on the data Pods, by Service name or Pod IP, while
#         all of them reach the unselected legacy stand-in;
#       - the data Pods cannot open connections out (egress is denied);
#       - the node a data Pod runs on still reaches it, and the data Pods stay
#         Ready with no restarts or failed probes;
#       - backup-data.sh, restore-data.sh and rotate-data-credentials.sh work
#         under the policies;
#       - removing the two data policies opens the denied paths, and putting
#         them back closes them again, so the policies cause the denials;
#       - no password appears in any output.
#       --keep-cluster leaves the cluster for inspection.
#
# Password handling: the initial passwords are generated here, and the
# rotated ones are read after the rotation from a new backend Pod's
# environment into private files (never printed). Every log of a called
# script is checked against both, plain and base64, at the end, and a log
# printed on failure is checked first and withheld if it holds one. Limit: if
# the rotation itself fails, its new passwords are unknown here, so its log
# is checked against the initial ones only (the rotation script redacts its
# own output). This script's own output holds only names, IPs and results.

set -euo pipefail
# Tracing would print commands that handle password files.
set +x

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=data-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/data-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

keep_cluster=false
case "${1:-}" in
  '') ;;
  --keep-cluster) keep_cluster=true; shift ;;
  -h | --help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
[[ $# -eq 0 ]] || { usage; exit 2; }

readonly CLUSTER=minishop-netpol-test
readonly CONTEXT="kind-$CLUSTER"
readonly LIVE_NODE=learn-control-plane
readonly OTHER_NS=netpol-other
# Same Helm image as scripts/helm-lib.sh.
readonly HELM_IMAGE=alpine/helm:3.17.3
NODE_IMAGE=$(awk '$1 == "image:" { print $2; exit }' "$DATA_REPO_ROOT/cluster/kind-config.yaml")
readonly NODE_IMAGE
[[ "$NODE_IMAGE" == kindest/node:*@sha256:* ]] || die "no pinned node image in cluster/kind-config.yaml"
BACKEND_IMAGE=$(data_chart_image backend) || die "no pinned backend image"
REDIS_IMAGE=$(data_chart_image redis) || die "no pinned redis image"
readonly BACKEND_IMAGE REDIS_IMAGE

data_require_commands docker kind kubectl base64
umask 077
unset KUBECONFIG
scratch=$(mktemp -d)
kc="$scratch/kubeconfig"
logs="$scratch/logs"
mkdir -m 700 "$logs" "$scratch/creds" "$scratch/backups"
# Known passwords, plain and base64, one per line (grep -F -f patterns).
patterns="$scratch/patterns"
: >"$patterns"
cluster_created=false

cleanup() {
  local status=$?
  if [[ "$cluster_created" == true ]]; then
    if [[ "$keep_cluster" == true ]]; then
      printf 'Kept cluster %s; kubeconfig %s. Delete with: kind delete cluster --name %s\n' "$CLUSTER" "$kc" "$CLUSTER" >&2
      exit "$status"
    fi
    kind delete cluster --name "$CLUSTER" --kubeconfig "$kc" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$scratch"
  exit "$status"
}
trap cleanup EXIT

k() { kubectl --kubeconfig "$kc" --context "$CONTEXT" "$@"; }
pass() { printf 'PASS: %s\n' "$*"; }
pod_ip() { k -n "$1" get pod "$2" -o 'jsonpath={.status.podIP}'; }
pod_node() { k -n "$1" get pod "$2" -o 'jsonpath={.spec.nodeName}'; }

# add_patterns FILE...: record each password file, plain and base64. An
# empty file would add an empty pattern that matches everything, so refuse it.
add_patterns() {
  local file
  for file in "$@"; do
    [[ -s "$file" ]] || die "empty password file ${file##*/}"
    { cat "$file"; echo; base64 -w0 <"$file"; echo; } >>"$patterns"
  done
}

# show_log LOG: print a called script's log to stderr on failure, unless it
# holds a known password.
show_log() {
  if [[ -s "$patterns" ]] && grep -qF -f "$patterns" "$1"; then
    printf 'Not printing log %s: it contains a password.\n' "${1##*/}" >&2
  else
    cat "$1" >&2
  fi
}

# --- Throwaway cluster: two workers, so traffic also crosses nodes -------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  die "a kind cluster named $CLUSTER exists, maybe from an interrupted run; delete it with kind delete cluster --name $CLUSTER"
fi
cat >"$scratch/kind.yaml" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: $NODE_IMAGE
  - role: worker
    image: $NODE_IMAGE
  - role: worker
    image: $NODE_IMAGE
YAML
printf 'Creating kind cluster %s (kubeconfig in a scratch directory)\n' "$CLUSTER"
cluster_created=true
kind create cluster --name "$CLUSTER" --config "$scratch/kind.yaml" --kubeconfig "$kc" --wait 180s \
  >"$logs/kind" 2>&1 || { show_log "$logs/kind"; die "kind create cluster failed"; }
if k get node "$LIVE_NODE" >/dev/null 2>&1; then
  die "the test cluster has the kind-learn node $LIVE_NODE; stopping"
fi
kindnet_image=$(k -n kube-system get daemonset kindnet -o 'jsonpath={.spec.template.spec.containers[0].image}')
k -n kube-system rollout status daemonset/kindnet --timeout=180s >/dev/null
policy_controllers=0
for pod in $(k -n kube-system get pods -l app=kindnet -o name); do
  # Captured first: grep -q exiting early would SIGPIPE kubectl under pipefail.
  kindnet_log=$(k -n kube-system logs "$pod" 2>/dev/null) || kindnet_log=""
  if grep -q 'Starting controller.*kube-network-policies' <<<"$kindnet_log"; then
    policy_controllers=$((policy_controllers + 1))
  fi
done
[[ "$policy_controllers" -eq 3 ]] || die "kube-network-policies started in $policy_controllers of 3 kindnet Pods"
pass "kindnet $kindnet_image runs kube-network-policies on all three nodes"

for ns in data webapp "$OTHER_NS"; do k create namespace "$ns" >/dev/null; done
k -n webapp create serviceaccount minishop-backend >/dev/null
for key in postgres-password redis-password; do
  head -c 36 /dev/urandom | base64 -w0 >"$scratch/creds/$key"
done
add_patterns "$scratch/creds/postgres-password" "$scratch/creds/redis-password"
for ns_secret in data/minishop-data-credentials webapp/minishop-app-credentials; do
  k -n "${ns_secret%/*}" create secret generic "${ns_secret#*/}" \
    --from-file=postgres-password="$scratch/creds/postgres-password" \
    --from-file=redis-password="$scratch/creds/redis-password" >/dev/null
done

docker run --rm --volume "$DATA_REPO_ROOT/charts/minishop:/chart:ro" "$HELM_IMAGE" \
  template minishop /chart --namespace webapp \
  --set seed.enabled=true --set replicas.backend=2 \
  --show-only templates/postgresql.yaml --show-only templates/redis.yaml \
  --show-only templates/backend.yaml --show-only templates/seed-job.yaml \
  --show-only templates/networkpolicy.yaml >"$scratch/rendered.yaml"
grep -q '^  name: minishop-postgresql$' "$scratch/rendered.yaml" || die "the chart rendered no data policies"
awk 'BEGIN { RS = "\n---\n" } /\nkind: NetworkPolicy\n/ && /\n  namespace: data\n/ { print "---"; print }' \
  "$scratch/rendered.yaml" >"$scratch/data-policies.yaml"
[[ "$(grep -c '^kind: NetworkPolicy$' "$scratch/data-policies.yaml")" -eq 2 ]] ||
  die "could not extract the two data policies"
k apply -f "$scratch/rendered.yaml" >/dev/null

printf 'Waiting for the data stack, the backend and the seed Job (image pulls)\n'
k -n data rollout status statefulset/minishop-postgresql --timeout=600s >/dev/null
k -n data rollout status statefulset/minishop-redis --timeout=600s >/dev/null
k -n webapp rollout status deployment/minishop-backend --timeout=600s >/dev/null
k -n webapp wait job -l app.kubernetes.io/component=seed --for=condition=complete --timeout=900s >/dev/null
pass "the seed Job completed under the policies (PostgreSQL and Redis reached from the seed Pod)"

# --- Test Pods ----------------------------------------------------------------------------------
# Clients are pinned after the data Pods are placed: half on PostgreSQL's
# node, half on the other worker, so both same-node and cross-node paths run.
PG_NODE=$(k -n data get pod minishop-postgresql-0 -o 'jsonpath={.spec.nodeName}')
OTHER_NODE=$(k get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' | grep -vx "$PG_NODE" | head -n 1)
[[ -n "$PG_NODE" && -n "$OTHER_NODE" ]] || die "could not find two worker nodes"
readonly PG_NODE OTHER_NODE

# probe_pod NAMESPACE NAME NODE LABELS-YAML: a Node.js Pod that only sleeps;
# the probes run in it through kubectl exec.
probe_pod() {
  cat <<YAML
---
apiVersion: v1
kind: Pod
metadata:
  name: $2
  namespace: $1
  labels:
$4
spec:
  nodeName: $3
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: $BACKEND_IMAGE
      command: [node, -e, "setInterval(() => {}, 1 << 30)"]
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { cpu: 100m, memory: 64Mi }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
        readOnlyRootFilesystem: true
YAML
}
readonly PLAIN_LABELS='    app.kubernetes.io/name: netpol-probe'
readonly BACKEND_LABELS='    app.kubernetes.io/component: minishop-backend
    app.kubernetes.io/name: minishop
    app.kubernetes.io/part-of: minishop'
{
  probe_pod webapp plain "$OTHER_NODE" "$PLAIN_LABELS"
  probe_pod "$OTHER_NS" plain "$PG_NODE" "$PLAIN_LABELS"
  probe_pod "$OTHER_NS" backend-labels "$OTHER_NODE" "$BACKEND_LABELS"
  probe_pod data plain "$PG_NODE" "$PLAIN_LABELS"
  # A stand-in for the legacy redis-0: same labels, no policy selects it.
  cat <<YAML
---
apiVersion: v1
kind: Pod
metadata:
  name: legacy-redis
  namespace: data
  labels:
    app.kubernetes.io/component: redis
    app.kubernetes.io/name: minishop
spec:
  nodeName: $OTHER_NODE
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: redis
      image: $REDIS_IMAGE
      command: [redis-server, --save, "", --appendonly, "no", --protected-mode, "no"]
      ports:
        - containerPort: 6379
      readinessProbe:
        tcpSocket:
          port: 6379
        periodSeconds: 5
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { cpu: 100m, memory: 64Mi }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
        readOnlyRootFilesystem: true
YAML
} >"$scratch/test-pods.yaml"
k apply -f "$scratch/test-pods.yaml" >/dev/null
for ns_pod in webapp/plain "$OTHER_NS/plain" "$OTHER_NS/backend-labels" data/plain data/legacy-redis; do
  k -n "${ns_pod%/*}" wait pod "${ns_pod#*/}" --for=condition=Ready --timeout=300s >/dev/null
done


# --- Connection probes ---------------------------------------------------------------------------
# connect NAMESPACE POD HOST PORT prints OPEN, TIMEOUT or ERR <code>. The
# policies drop denied SYNs, so a denied connection times out.
readonly CONNECT_JS='const net = require("net");
const [host, port] = process.argv.slice(1);
const socket = net.connect({ host, port: Number(port), timeout: 3000 }, () => { console.log("OPEN"); socket.destroy(); });
socket.on("timeout", () => { console.log("TIMEOUT"); socket.destroy(); });
socket.on("error", error => console.log("ERR " + error.code));'
connect() {
  local container=probe
  [[ "$2" == minishop-backend-* ]] && container=backend
  k -n "$1" exec "$2" -c "$container" -- node -e "$CONNECT_JS" "$3" "$4" 2>&1 | tr -d '\r'
}

# expect NAMESPACE POD HOST PORT OPEN|TIMEOUT: retries for up to 20 s while
# policy changes propagate.
expect() {
  local result="" try
  for try in 1 2 3 4 5; do
    result=$(connect "$1" "$2" "$3" "$4")
    [[ "$result" == "$5" ]] && break
    [[ "$try" -lt 5 ]] && sleep 4
  done
  [[ "$result" == "$5" ]] || die "$1/$2 -> $3:$4: expected $5, got ${result:-no output}"
  printf '  %-26s -> %-46s %s\n' "$1/$2" "$3:$4" "$result"
}

PG_IP=$(pod_ip data minishop-postgresql-0)
REDIS_IP=$(pod_ip data minishop-redis-0)
LEGACY_IP=$(pod_ip data legacy-redis)
readonly PG_SVC=minishop-postgresql.data.svc.cluster.local
readonly REDIS_SVC=minishop-redis.data.svc.cluster.local
mapfile -t BACKENDS < <(k -n webapp get pods -l app.kubernetes.io/component=minishop-backend \
  --field-selector=status.phase=Running -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}')
[[ ${#BACKENDS[@]} -eq 2 ]] || die "expected 2 running backend Pods, found ${#BACKENDS[@]}"
printf 'Placement: postgresql %s, redis %s, backends %s %s; clients on %s: %s; on %s: %s\n' \
  "$PG_NODE" "$(pod_node data minishop-redis-0)" "$(pod_node webapp "${BACKENDS[0]}")" \
  "$(pod_node webapp "${BACKENDS[1]}")" "$PG_NODE" "$OTHER_NS/plain data/plain" \
  "$OTHER_NODE" "webapp/plain $OTHER_NS/backend-labels data/legacy-redis"

printf 'Allowed: the backend reaches both data Pods\n'
for backend in "${BACKENDS[@]}"; do
  expect webapp "$backend" "$PG_SVC" 5432 OPEN
  expect webapp "$backend" "$REDIS_SVC" 6379 OPEN
done

# The backend answers /ready, /items (PostgreSQL) and the first item's
# reviews (Redis) from inside its own Pod.
readonly ITEMS_JS='const http = require("http");
const get = path => new Promise((resolve, reject) => {
  http.get({ host: "127.0.0.1", port: 3001, path, timeout: 5000 }, response => {
    let body = "";
    response.on("data", chunk => { body += chunk; });
    response.on("end", () => resolve({ status: response.statusCode, body }));
  }).on("error", reject);
});
(async () => {
  const ready = await get("/ready");
  const items = await get("/items?q=");
  const rows = JSON.parse(items.body);
  const reviews = await get("/items/" + rows[0].data.index + "/reviews");
  console.log("ready=" + ready.status + " items=" + items.status + " count=" + rows.length + " reviews=" + reviews.status);
})().catch(error => { console.log("ERR " + error.message); process.exit(1); });'
backend_reads() { # backend Pod: prints ready=200 items=200 count=N reviews=200
  k -n webapp exec "$1" -c backend -- node -e "$ITEMS_JS" 2>&1 | tr -d '\r'
}
for backend in "${BACKENDS[@]}"; do
  reads=$(backend_reads "$backend")
  [[ "$reads" =~ ^ready=200\ items=200\ count=[1-9][0-9]*\ reviews=200$ ]] || die "$backend: $reads"
  printf '  %s: %s\n' "$backend" "$reads"
done
pass "the backend reads items (PostgreSQL) and reviews (Redis); the seeded rows are there"

# check_denied: every client that is not the backend or the seed Job is
# denied on 5432 and 6379, by Service name and by Pod IP, yet reaches the
# unselected legacy stand-in.
check_denied() {
  local client host
  for client in webapp/plain "$OTHER_NS/plain" "$OTHER_NS/backend-labels" data/plain; do
    for host in "$PG_SVC" "$PG_IP"; do expect "${client%/*}" "${client#*/}" "$host" 5432 TIMEOUT; done
    for host in "$REDIS_SVC" "$REDIS_IP"; do expect "${client%/*}" "${client#*/}" "$host" 6379 TIMEOUT; done
    expect "${client%/*}" "${client#*/}" "$LEGACY_IP" 6379 OPEN
  done
}
printf 'Denied: other Pods, in webapp, another namespace (also with backend labels) and data\n'
check_denied
pass "only the backend and the seed reach the data Pods; the legacy stand-in stays reachable"

# --- Egress from the data Pods -------------------------------------------------------------------
# bash /dev/tcp inside the data containers; timeout 4 ends a dropped SYN.
data_connect() { # pod container host port: prints OPEN, BLOCKED or FAILED rc=N
  local out rc=0
  out=$(k -n data exec "$1" -c "$2" -- timeout 4 bash -c "exec 3<>/dev/tcp/$3/$4 && echo OPEN" 2>/dev/null) ||
    rc=$?
  case "$rc" in
    0) printf '%s\n' "${out//$'\r'/}" ;;
    124) echo BLOCKED ;;
    *) echo "FAILED rc=$rc" ;;
  esac
}
for target in "minishop-postgresql-0 postgresql $LEGACY_IP 6379" "minishop-redis-0 redis $LEGACY_IP 6379" \
  "minishop-redis-0 redis $PG_IP 5432"; do
  read -r pod container host port <<<"$target"
  result=$(data_connect "$pod" "$container" "$host" "$port")
  [[ "$result" == BLOCKED ]] || die "data/$pod -> $host:$port: expected BLOCKED, got $result"
  printf '  %-26s -> %-46s %s\n' "data/$pod" "$host:$port" "$result"
done
# A Pod's connection to its own IP stays on loopback in its network namespace
# (rotate-data-credentials.sh logs in to PostgreSQL this way).
result=$(data_connect minishop-postgresql-0 postgresql "$PG_IP" 5432)
[[ "$result" == OPEN ]] || die "minishop-postgresql-0 cannot reach its own IP: $result"
printf '  %-26s -> %-46s %s\n' "data/minishop-postgresql-0" "own IP $PG_IP:5432" "$result"
pass "the data Pods cannot open connections out; a connection to their own IP works"

# --- The node and the kubelet --------------------------------------------------------------------
for pod_port in "minishop-postgresql-0 $PG_IP 5432" "minishop-redis-0 $REDIS_IP 6379"; do
  read -r pod ip port <<<"$pod_port"
  node=$(pod_node data "$pod")
  docker exec "$node" timeout 4 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null ||
    die "node $node cannot reach $pod on its own node"
  printf '  node %-21s -> %-46s OPEN\n' "$node" "$pod $ip:$port"
done
pass "the node a data Pod runs on reaches it (kubelet traffic is not filtered)"

# --- Probes stayed green -------------------------------------------------------------------------
# Checked before the data tools: a rotation briefly fails the old Redis
# Pod's probe by design, which says nothing about the policies.
restarts=$(k -n data get pods -l 'app.kubernetes.io/name in (minishop-postgresql,minishop-redis)' \
  -o 'jsonpath={range .items[*]}{.status.containerStatuses[0].ready} {.status.containerStatuses[0].restartCount}{"\n"}{end}' |
  sort -u)
[[ "$restarts" == "true 0" ]] || die "data containers not all ready with 0 restarts: $(tr '\n' ' ' <<<"$restarts")"
# Only the chart's data Pods; the legacy stand-in's own probe is not checked.
unhealthy=0
for pod in minishop-postgresql-0 minishop-redis-0; do
  count=$(k -n data get events --field-selector "reason=Unhealthy,involvedObject.name=$pod" -o name | wc -l)
  unhealthy=$((unhealthy + count))
done
[[ "$unhealthy" -eq 0 ]] || die "$unhealthy Unhealthy probe events on the data Pods"
pass "the data Pods are Ready with no container restarts and no failed probes"

# --- The exec-based data tools -------------------------------------------------------------------
bash "$SCRIPT_DIR/backup-data.sh" --kubeconfig "$kc" --context "$CONTEXT" \
  --backup-dir "$scratch/backups" >"$logs/backup" 2>&1 || { show_log "$logs/backup"; die "backup failed"; }
grep -q '^Backup .* complete' "$logs/backup" || { show_log "$logs/backup"; die "backup did not report completion"; }
pass "backup-data.sh completed"
set_dir=$(find "$scratch/backups" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
  -regex '.*/[0-9]{8}T[0-9]{6}Z$' | head -n 1)
[[ -n "$set_dir" ]] || die "no backup set found"
bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" --kubeconfig "$kc" --context "$CONTEXT" \
  >"$logs/restore" 2>&1 || { show_log "$logs/restore"; die "restore failed"; }
grep -q '^Restore of .* complete' "$logs/restore" || { show_log "$logs/restore"; die "restore did not report completion"; }
pass "restore-data.sh completed (pg_restore and the Redis REPLICAOF 127.0.0.1 sync)"
bash "$SCRIPT_DIR/rotate-data-credentials.sh" --kubeconfig "$kc" --context "$CONTEXT" \
  --state-dir "$scratch/state" --backup-dir "$scratch/backups" --apply >"$logs/rotate" 2>&1 ||
  { show_log "$logs/rotate"; die "rotation failed"; }
k -n webapp rollout status deployment/minishop-backend --timeout=300s >/dev/null
# The rotated passwords, from a new backend Pod's environment into private
# files, so the leak checks cover them too. Nothing is printed.
for var_key in POSTGRES_PASSWORD:postgres-password REDIS_PASSWORD:redis-password; do
  k -n webapp exec deployment/minishop-backend -c backend -- \
    node -e 'process.stdout.write(process.env[process.argv[1]] || "")' "${var_key%%:*}" \
    >"$scratch/creds/rotated-${var_key#*:}" 2>/dev/null || die "could not read the rotated ${var_key#*:}"
  if cmp -s "$scratch/creds/rotated-${var_key#*:}" "$scratch/creds/${var_key#*:}"; then
    die "the backend still has the initial ${var_key#*:}"
  fi
done
add_patterns "$scratch/creds/rotated-postgres-password" "$scratch/creds/rotated-redis-password"
for line in 'ok: postgresql: the new password logs in, the previous one is rejected' \
  'ok: redis: the new password logs in, the previous one is rejected' '/items 200' 'Rotation complete'; do
  grep -qF "$line" "$logs/rotate" || { show_log "$logs/rotate"; die "missing from the rotation output: $line"; }
done
pass "rotate-data-credentials.sh completed (TCP login to the Pod IP, backend /items check)"

reads=$(backend_reads deployment/minishop-backend)
[[ "$reads" =~ ^ready=200\ items=200\ count=[1-9][0-9]*\ reviews=200$ ]] || die "after rotation: $reads"
pass "after the rotation the new backend Pods still read items and reviews: $reads"

# Rotation replaced minishop-redis-0; its new Pod must pass its probes too.
for pod in minishop-postgresql-0 minishop-redis-0; do
  k -n data wait pod "$pod" --for=condition=Ready --timeout=120s >/dev/null
done
pass "after the data tools both data Pods are Ready"
# The rotation replaced minishop-redis-0, which has a new IP now.
PG_IP=$(pod_ip data minishop-postgresql-0)
REDIS_IP=$(pod_ip data minishop-redis-0)
printf 'Data Pods now: postgresql %s on %s, redis %s on %s\n' "$PG_IP" "$(pod_node data minishop-postgresql-0)" \
  "$REDIS_IP" "$(pod_node data minishop-redis-0)"

# --- The policies cause the denials --------------------------------------------------------------
k delete -f "$scratch/data-policies.yaml" >/dev/null
printf 'Without the data policies, the same clients connect\n'
for client in webapp/plain "$OTHER_NS/plain" data/plain; do
  expect "${client%/*}" "${client#*/}" "$PG_IP" 5432 OPEN
  expect "${client%/*}" "${client#*/}" "$REDIS_IP" 6379 OPEN
done
k apply -f "$scratch/data-policies.yaml" >/dev/null
printf 'With the policies back, they are denied again\n'
check_denied
pass "deleting the two data policies opens the denied paths; applying them closes them"

# --- No password in any output -------------------------------------------------------------------
[[ "$(wc -l <"$patterns")" -eq 8 ]] || die "expected 4 known passwords (8 patterns), found $(wc -l <"$patterns") patterns"
if grep -rlF -f "$patterns" "$logs" >"$scratch/leaks"; then
  die "a password appears in: $(tr '\n' ' ' <"$scratch/leaks")"
fi
pass "no initial or rotated password, in plain or base64 form, appears in any log"
printf 'All data NetworkPolicy tests passed.\n'
