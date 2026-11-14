#!/usr/bin/env bash
#
# Test the ECK logging stack (Issue #59, ADR 0017) end to end on a throwaway
# kind cluster: a control plane and two workers from the node image that
# cluster/kind-config.yaml pins, so it runs kind-learn's Kubernetes version
# and kindnet (with its NetworkPolicy controller). The cluster has its own
# name and its own kubeconfig in a private scratch directory; kind-learn and
# ./.kube/config are never used. The cluster is deleted on exit.
#
# Usage:
#   bash scripts/test-logging.sh [--keep-cluster]
#       Refuses to start with less than 6 GiB of available memory (the stack
#       and the three nodes need about 5 GiB). Then it:
#       - runs deploy-eck.sh, deploy-logging.sh and validate-logging.sh
#         against the throwaway cluster, with a stand-in backend Pod (the
#         chart's pinned backend image and labels) in webapp;
#       - checks each NetworkPolicy path: Filebeat and Kibana reach
#         Elasticsearch; Pods outside the stack cannot reach Elasticsearch or
#         Kibana; the stack Pods cannot open other connections; Kibana answers
#         through kubectl port-forward;
#       - checks Filebeat's RBAC (no Secret access) and that it logs no
#         permission errors;
#       - records CPU and memory per Pod from the kubelet summary API;
#       - re-runs deploy-logging.sh and validate-logging.sh after a Filebeat
#         Pod restart (idempotency, registry);
#       - runs teardown-logging.sh without --yes (no change), then with
#         --yes --remove-eck, and checks the stand-in MiniShop Pods survive;
#       - checks that no output holds the elastic password. The password is
#         read once, from inside the Elasticsearch container into a private
#         file, only for that check.
#       --keep-cluster leaves the cluster for inspection.

# In-container probe commands are single-quoted on purpose.
# shellcheck disable=SC2016

set -euo pipefail
set +x

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=logging-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/logging-lib.sh"


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

readonly CLUSTER=minishop-logging-test
readonly CONTEXT="kind-$CLUSTER"
readonly LIVE_NODE=learn-control-plane
readonly MIN_AVAILABLE_MIB=6144
readonly FORWARD_PORT=15601

logging_require_commands docker kind kubectl curl python3 sha256sum
available_mib=$(awk '$1 == "MemAvailable:" { print int($2 / 1024) }' /proc/meminfo)
((available_mib >= MIN_AVAILABLE_MIB)) ||
  die "only ${available_mib} MiB of memory available; this test needs ${MIN_AVAILABLE_MIB} MiB"
NODE_IMAGE=$(awk '$1 == "image:" { print $2; exit }' "$LOGGING_REPO_ROOT/cluster/kind-config.yaml")
readonly NODE_IMAGE
[[ "$NODE_IMAGE" == kindest/node:*@sha256:* ]] || die "no pinned node image in cluster/kind-config.yaml"
BACKEND_IMAGE=$(awk '
  /^images:/ { in_images = 1; next }
  in_images && /^[^ #]/ { in_images = 0 }
  in_images && /^  [a-z]+:/ { key = $1; sub(/:$/, "", key); next }
  in_images && key == "backend" && $1 == "repository:" { repo = $2 }
  in_images && key == "backend" && $1 == "digest:" { digest = $2 }
  END { if (repo == "" || digest !~ /^sha256:[0-9a-f]+$/) exit 1; print repo "@" digest }
' "$LOGGING_REPO_ROOT/charts/minishop/values.yaml") || die "no pinned backend image in the chart values"
readonly BACKEND_IMAGE

umask 077
unset KUBECONFIG
scratch=$(mktemp -d)
kc="$scratch/kubeconfig"
logs="$scratch/logs"
mkdir -m 700 "$logs"
password_file="$scratch/elastic-password"
cluster_created=false
forward_pid=""

cleanup() {
  local status=$?
  if [[ -n "$forward_pid" ]]; then kill "$forward_pid" 2>/dev/null || true; fi
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

# The logging-lib.sh helpers target the throwaway cluster too.
# shellcheck disable=SC2034
LOGGING_CONTEXT=$CONTEXT
# shellcheck disable=SC2034
LOGGING_KUBECONFIG=$kc
k() { kubectl --kubeconfig "$kc" --context "$CONTEXT" "$@"; }
pass() { printf 'PASS: %s\n' "$*"; }
target=(--context "$CONTEXT" --kubeconfig "$kc")

# capture_password: once Elasticsearch runs, copy the elastic password from
# inside its container into a private file, for the leak check only.
capture_password() {
  [[ -s "$password_file" ]] && return 0
  local pod
  pod=$(logging_es_pod 2>/dev/null) || return 1
  k -n "$LOGGING_NAMESPACE" exec "$pod" -c elasticsearch -- cat /mnt/elastic-user/elastic \
    >"$password_file" 2>/dev/null || { rm -f -- "$password_file"; return 1; }
  [[ -s "$password_file" ]]
}

# holds_password FILE: 0 if FILE contains the password (plain or base64).
holds_password() {
  [[ -s "$password_file" ]] || return 1
  grep -qF -f <(cat "$password_file"; echo; base64 -w0 <"$password_file"; echo) "$1"
}

# show_log LOG: print a log on failure, unless it holds the password.
show_log() {
  capture_password || true
  if holds_password "$1"; then
    printf 'Not printing log %s: it contains the elastic password.\n' "${1##*/}" >&2
  else
    cat "$1" >&2
  fi
}

# run_step NAME COMMAND...: run a repository script with its output in a log.
run_step() {
  local name=$1
  shift
  printf 'Running %s\n' "$name"
  if ! "$@" >"$logs/$name" 2>&1; then
    show_log "$logs/$name"
    die "$name failed"
  fi
}

# --- Throwaway cluster ------------------------------------------------------------
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
printf 'Creating kind cluster %s (%s MiB available; kubeconfig in a scratch directory)\n' "$CLUSTER" "$available_mib"
cluster_created=true
kind create cluster --name "$CLUSTER" --config "$scratch/kind.yaml" --kubeconfig "$kc" --wait 180s \
  >"$logs/kind" 2>&1 || { show_log "$logs/kind"; die "kind create cluster failed"; }
if k get node "$LIVE_NODE" >/dev/null 2>&1; then
  die "the test cluster has the kind-learn node $LIVE_NODE; stopping"
fi
k -n kube-system rollout status daemonset/kindnet --timeout=180s >/dev/null
# A kindnet Pod can be Ready before it logs the controller start; retry.
for attempt in {1..12}; do
  policy_controllers=0
  for pod in $(k -n kube-system get pods -l app=kindnet -o name); do
    # Captured first: grep -q exiting early would SIGPIPE kubectl.
    kindnet_log=$(k -n kube-system logs "$pod" 2>/dev/null) || kindnet_log=""
    if grep -q 'Starting controller.*kube-network-policies' <<<"$kindnet_log"; then
      policy_controllers=$((policy_controllers + 1))
    fi
  done
  [[ "$policy_controllers" -eq 3 ]] && break
  ((attempt < 12)) || die "kube-network-policies started in $policy_controllers of 3 kindnet Pods after 60s"
  sleep 5
done
pass "kindnet $(k -n kube-system get daemonset kindnet -o 'jsonpath={.spec.template.spec.containers[0].image}') enforces NetworkPolicy on all three nodes"

# --- Stand-in MiniShop Pods ---------------------------------------------------------
# node_pod NAME LABELS-YAML SCRIPT: a Pod from the backend image running SCRIPT.
node_pod() {
  cat <<YAML
---
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: webapp
  labels:
$2
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: backend
      image: $BACKEND_IMAGE
      command: [node, -e, '$3']
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { cpu: 100m, memory: 64Mi }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
        readOnlyRootFilesystem: true
YAML
}
k create namespace webapp >/dev/null
{
  node_pod backend-standin '    app.kubernetes.io/component: minishop-backend
    app.kubernetes.io/name: minishop
    app.kubernetes.io/part-of: minishop' 'setInterval(() => {}, 1 << 30)'
  # Plain client and listener: no policy selects them (webapp has none here).
  node_pod plain '    app.kubernetes.io/name: logging-probe' \
    'require("net").createServer((s) => s.end()).listen(8080)'
} | k apply -f - >/dev/null
k -n webapp wait pod --all --for=condition=Ready --timeout=300s >/dev/null
pass "stand-in backend and probe Pods run in webapp"
webapp_uids=$(k -n webapp get pods -o 'jsonpath={range .items[*]}{.metadata.uid}{"\n"}{end}' | sort)

# --- Deploy and validate ------------------------------------------------------------
run_step deploy-eck bash "$SCRIPT_DIR/deploy-eck.sh" "${target[@]}"
pass "deploy-eck.sh installed ECK $ECK_VERSION ($(k get crd -l app.kubernetes.io/name=eck-operator-crds -o name | wc -l) CRDs)"
run_step deploy-logging bash "$SCRIPT_DIR/deploy-logging.sh" "${target[@]}" --timeout 900
capture_password || die "could not read the elastic password for the leak check"
pass "deploy-logging.sh: Elasticsearch, ILM policy, Kibana and Filebeat are up"
run_step validate-logging bash "$SCRIPT_DIR/validate-logging.sh" "${target[@]}"
grep '^PASS' "$logs/validate-logging" | sed 's/^/  validate-logging.sh /'

yellow=$(logging_es_api GET '/_cat/indices?health=yellow&h=index,rep&expand_wildcards=all' </dev/null) || yellow="unknown"
printf 'Elasticsearch health %s; yellow indices: %s\n' \
  "$(logging_resource_field elasticsearch "$LOGGING_ES_NAME" '{.status.health}')" "${yellow:-none}"

# --- Placement, labels, security contexts --------------------------------------------
k -n "$LOGGING_NAMESPACE" get pods -o wide >"$logs/pods"
k -n "$LOGGING_NAMESPACE" get pods -o \
  'jsonpath={range .items[*]}{.metadata.name}{"\n"}{range .spec.initContainers[*]}{"  init "}{.name}{" "}{.resources}{" "}{.securityContext}{"\n"}{end}{range .spec.containers[*]}{"  "}{.name}{" "}{.resources}{" "}{.securityContext}{"\n"}{end}{end}' \
  >"$logs/containers"
cat "$logs/pods" "$logs/containers"
if grep '^  ' "$logs/containers" | grep -v '"limits"' | grep -q .; then
  die "a logging container has no resource limits (see above)"
fi
pass "every logging container, init containers included, has resource limits"

es_pod=$(logging_es_pod)
kb_pod=$(k -n "$LOGGING_NAMESPACE" get pods -l "kibana.k8s.elastic.co/name=$LOGGING_KIBANA_NAME" -o 'jsonpath={.items[0].metadata.name}')
fb_pods=$(k -n "$LOGGING_NAMESPACE" get pods -l "beat.k8s.elastic.co/name=$LOGGING_BEAT_NAME" -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}')
fb_pod=${fb_pods%%$'\n'*}
[[ "$(wc -l <<<"$fb_pods")" -eq 3 ]] || die "expected 3 Filebeat Pods (control plane and two workers)"
pod_ip() { k -n "$1" get pod "$2" -o 'jsonpath={.status.podIP}'; }
es_ip=$(pod_ip "$LOGGING_NAMESPACE" "$es_pod")
kb_ip=$(pod_ip "$LOGGING_NAMESPACE" "$kb_pod")
plain_ip=$(pod_ip webapp plain)
api_ip=$(k get endpoints kubernetes -n default -o 'jsonpath={.subsets[0].addresses[0].ip}')

# ECK's module hints on the Elasticsearch and Kibana Pods must not stop
# their own logs from being collected.
for pod in "$es_pod" "$kb_pod"; do
  docs=$(logging_es_api POST '/filebeat-*/_count?filter_path=count' \
    <<<"{\"query\":{\"term\":{\"kubernetes.pod.name\":\"$pod\"}}}")
  docs=${docs#*\"count\":}
  docs=${docs%%[!0-9]*}
  [[ "${docs:-0}" -ge 1 ]] || die "no log documents from $pod"
  pass "$pod logs are collected ($docs documents)"
done

# --- NetworkPolicy paths -------------------------------------------------------------
# node_probe POD HOST PORT (webapp Pods): OPEN, TIMEOUT or REFUSED.
node_probe() {
  k -n webapp exec "$1" -- node -e '
    const s = require("net").connect({ host: process.argv[1], port: Number(process.argv[2]) });
    s.setTimeout(3000);
    s.on("connect", () => { console.log("OPEN"); process.exit(0); });
    s.on("timeout", () => { console.log("TIMEOUT"); process.exit(0); });
    s.on("error", (e) => { console.log(e.code === "ECONNREFUSED" ? "REFUSED" : "ERROR " + e.code); process.exit(0); });
  ' "$2" "$3"
}
# stack_probe POD CONTAINER HOST PORT (logging Pods, bash /dev/tcp).
stack_probe() {
  k -n "$LOGGING_NAMESPACE" exec "$1" -c "$2" -- bash -c '
    timeout 4 bash -c "</dev/tcp/$1/$2" 2>/dev/null && { echo OPEN; exit 0; }
    [ $? -eq 124 ] && echo TIMEOUT || echo REFUSED' probe "$3" "$4" 2>/dev/null || echo "NO-SHELL"
}
expect() { # EXPECTED ACTUAL DESCRIPTION
  [[ "$2" == "$1" ]] || die "$3: expected $1, got $2"
  pass "$3: $2"
}
expect OPEN "$(node_probe plain "$plain_ip" 8080)" "control: webapp/plain -> its own listener :8080"
expect TIMEOUT "$(node_probe plain "$es_ip" 9200)" "webapp/plain -> Elasticsearch :9200 (not an allowed client)"
expect TIMEOUT "$(node_probe plain "$es_ip" 9300)" "webapp/plain -> Elasticsearch transport :9300"
expect TIMEOUT "$(node_probe plain "$kb_ip" 5601)" "webapp/plain -> Kibana :5601 (no ingress rule)"
expect TIMEOUT "$(node_probe backend-standin "$es_ip" 9200)" "webapp backend -> Elasticsearch :9200"
expect OPEN "$(stack_probe "$kb_pod" kibana "$es_ip" 9200)" "Kibana -> Elasticsearch :9200"
expect OPEN "$(stack_probe "$fb_pod" filebeat "$es_ip" 9200)" "Filebeat -> Elasticsearch :9200"
expect TIMEOUT "$(stack_probe "$fb_pod" filebeat "$kb_ip" 5601)" "Filebeat -> Kibana :5601"
expect TIMEOUT "$(stack_probe "$es_pod" elasticsearch "$plain_ip" 8080)" "Elasticsearch -> webapp/plain :8080 (egress)"
expect TIMEOUT "$(stack_probe "$kb_pod" kibana "$plain_ip" 8080)" "Kibana -> webapp/plain :8080 (egress)"
expect TIMEOUT "$(stack_probe "$fb_pod" filebeat "$plain_ip" 8080)" "Filebeat -> webapp/plain :8080 (egress)"
expect TIMEOUT "$(stack_probe "$es_pod" elasticsearch "$api_ip" 6443)" "Elasticsearch -> API server :6443 (egress)"
expect OPEN "$(stack_probe "$fb_pod" filebeat "$api_ip" 6443)" "Filebeat -> API server $api_ip:6443"
operator_es=$(k -n "$ECK_NAMESPACE" logs statefulset/elastic-operator --since=10m 2>/dev/null |
  grep -c 'dial tcp.*9200.*i/o timeout') || true
expect 0 "${operator_es:-0}" "ECK operator -> Elasticsearch timeouts in the last 10m"

k -n "$LOGGING_NAMESPACE" port-forward "service/${LOGGING_KIBANA_NAME}-kb-http" "$FORWARD_PORT:5601" \
  >"$logs/port-forward" 2>&1 &
forward_pid=$!
# Kibana 9.4 serves a redacted /api/status without credentials; its other
# APIs need a login. No credential is sent.
status=""
for _ in {1..20}; do
  status=$(curl --silent --insecure --output "$scratch/kibana-status" --write-out '%{http_code}' \
    "https://127.0.0.1:$FORWARD_PORT/api/status" 2>/dev/null) || status=""
  [[ "$status" == 200 ]] && break
  sleep 1
done
expect 200 "$status" "Kibana /api/status through kubectl port-forward"
grep -q '"level":"available"' "$scratch/kibana-status" || die "Kibana status is not available"
pass "Kibana reports overall status available"
status=$(curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
  "https://127.0.0.1:$FORWARD_PORT/api/data_views" 2>/dev/null) || status=""
expect 401 "$status" "Kibana /api/data_views without credentials"
kill "$forward_pid" 2>/dev/null || true
wait "$forward_pid" 2>/dev/null || true
forward_pid=""

# --- Filebeat RBAC -------------------------------------------------------------------
fb_sa=system:serviceaccount:$LOGGING_NAMESPACE:filebeat
expect yes "$(k auth can-i list pods --all-namespaces --as="$fb_sa" || true)" "Filebeat may list pods"
expect no "$(k auth can-i get secrets --all-namespaces --as="$fb_sa" || true)" "Filebeat may get secrets"
expect no "$(k auth can-i create pods -n "$LOGGING_NAMESPACE" --as="$fb_sa" || true)" "Filebeat may create pods"
fb_errors=0
for pod in $fb_pods; do
  n=$(k -n "$LOGGING_NAMESPACE" logs "$pod" 2>/dev/null | grep -ciE 'forbidden|permission denied|read-only file system') || true
  fb_errors=$((fb_errors + ${n:-0}))
done
expect 0 "$fb_errors" "Filebeat log lines with forbidden, permission denied or read-only file system"

# --- Resource usage ------------------------------------------------------------------
sleep 30
mkdir "$logs/summary"
for node in $(k get nodes -o name); do
  k get --raw "/api/v1/nodes/${node#node/}/proxy/stats/summary" >"$logs/summary/${node#node/}.json"
done
python3 -I - "$LOGGING_NAMESPACE" "$ECK_NAMESPACE" "$logs/summary"/*.json <<'PY'
import json, sys
namespaces, paths = sys.argv[1:3], sys.argv[3:]
total_mem = total_cpu = 0
for path in paths:
    with open(path) as handle:
        for pod in json.load(handle).get("pods", []):
            ref = pod["podRef"]
            if ref["namespace"] not in namespaces:
                continue
            mem = sum(c.get("memory", {}).get("workingSetBytes", 0) for c in pod.get("containers", []))
            cpu = sum(c.get("cpu", {}).get("usageNanoCores", 0) for c in pod.get("containers", []))
            total_mem += mem
            total_cpu += cpu
            print(f"  usage {ref['namespace']}/{ref['name']}: {mem / 2**20:.0f} MiB, {cpu / 1e6:.0f}m CPU")
print(f"  usage total: {total_mem / 2**20:.0f} MiB, {total_cpu / 1e6:.0f}m CPU")
PY

# --- Idempotency and restart -----------------------------------------------------------
k -n "$LOGGING_NAMESPACE" delete pod "$fb_pod" --wait=true >/dev/null
run_step deploy-logging-rerun bash "$SCRIPT_DIR/deploy-logging.sh" "${target[@]}"
run_step validate-logging-rerun bash "$SCRIPT_DIR/validate-logging.sh" "${target[@]}"
pass "deploy-logging.sh re-run and validate-logging.sh pass after a Filebeat Pod restart"

# --- Teardown --------------------------------------------------------------------------
run_step teardown-dry-run bash "$SCRIPT_DIR/teardown-logging.sh" "${target[@]}" --remove-eck
[[ "$(k get namespace "$LOGGING_NAMESPACE" -o 'jsonpath={.status.phase}')" == Active ]] ||
  die "teardown-logging.sh without --yes changed the cluster"
pass "teardown-logging.sh without --yes changed nothing"
run_step teardown bash "$SCRIPT_DIR/teardown-logging.sh" "${target[@]}" --yes --remove-eck
for object in "namespace/$LOGGING_NAMESPACE" "namespace/$ECK_NAMESPACE" clusterrole/logging-filebeat \
  clusterrolebinding/logging-filebeat clusterrole/elastic-operator \
  validatingwebhookconfiguration/elastic-webhook.k8s.elastic.co; do
  if k get "$object" >/dev/null 2>&1; then die "$object still exists after teardown"; fi
done
[[ -z "$(k get crd -o name | grep 'k8s.elastic.co' || true)" ]] || die "ECK CRDs remain after teardown"
# local-path deletes the released volume asynchronously.
for attempt in {1..24}; do
  [[ -z "$(k get pv -o name)" ]] && break
  ((attempt < 24)) || die "a PersistentVolume remains 120s after teardown"
  sleep 5
done
after_uids=$(k -n webapp get pods -o 'jsonpath={range .items[*]}{.metadata.uid}{"\n"}{end}' | sort)
[[ "$after_uids" == "$webapp_uids" ]] || die "webapp Pods changed during the test"
k -n webapp wait pod --all --for=condition=Ready --timeout=30s >/dev/null
pass "teardown removed the stack, its RBAC, ECK, CRDs and the volume; webapp Pods untouched"

# --- Password leak check ---------------------------------------------------------------
while IFS= read -r log; do
  if holds_password "$log"; then die "log ${log##*/} contains the elastic password"; fi
done < <(find "$logs" -type f)
pass "no captured output contains the elastic password ($(find "$logs" -type f | wc -l) files)"
printf 'All logging tests passed.\n'
