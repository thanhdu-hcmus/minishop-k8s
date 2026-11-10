#!/usr/bin/env bash
#
# Test rotate-data-credentials.sh on a throwaway kind cluster (Issue #40,
# part 3). The cluster has its own name and its own kubeconfig file in a
# private scratch directory, so kind-learn and ./.kube/config are never used.
# It runs the chart's PostgreSQL, Redis, backend, seed Job and NetworkPolicy
# templates with random throwaway passwords, and is deleted on exit.
#
# Usage:
#   bash scripts/test-data-rotation.sh [--keep-cluster]
#       Checks that the script refuses to run without --context, without a
#       recent backup, when the two Secrets disagree, when an old value is not
#       plain base64, with a state directory that is not private, and while
#       another run holds the lock; that a dry run changes nothing; that a
#       failure after ALTER ROLE rolls back, and so does a concurrent Secret
#       change (409 Conflict); that a rotation succeeds (old passwords
#       rejected, data intact, /items served) and how long clients see
#       failures; that a failed rollback leaves a work directory from which
#       --recover converges on the old or on the new passwords, and refuses a
#       conflicting --only; that --only postgresql and --only redis each leave
#       the other password alone; and that no password appears in any output.
#       --keep-cluster leaves the cluster for inspection.

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

readonly CLUSTER=minishop-rotation-test
readonly CONTEXT="kind-$CLUSTER"
readonly LIVE_NODE=learn-control-plane
# Same Helm image as scripts/helm-lib.sh; the node image is the one
# cluster/kind-config.yaml pins.
readonly HELM_IMAGE=alpine/helm:3.17.3
NODE_IMAGE=$(awk '$1 == "image:" { print $2; exit }' "$DATA_REPO_ROOT/cluster/kind-config.yaml")
readonly NODE_IMAGE
[[ "$NODE_IMAGE" == kindest/node:*@sha256:* ]] || die "no pinned node image in cluster/kind-config.yaml"
BACKEND_IMAGE=$(data_chart_image backend) || die "no pinned backend image"
readonly BACKEND_IMAGE

data_require_commands docker kind kubectl base64 sha256sum flock
umask 077
unset KUBECONFIG
scratch=$(mktemp -d)
kc="$scratch/kubeconfig"
logs="$scratch/logs"
mkdir -m 700 "$logs" "$scratch/creds" "$scratch/bin"
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
now_ms() { date +%s%3N; }

# rotate LOG-NAME ARGS... runs the rotation script against the throwaway
# cluster, with all its output in $logs/LOG-NAME.
rotate() {
  local log="$logs/$1"
  shift
  bash "$SCRIPT_DIR/rotate-data-credentials.sh" --kubeconfig "$kc" --context "$CONTEXT" \
    --state-dir "$scratch/state" --backup-dir "$scratch/backups" "$@" >"$log" 2>&1
}

# expect_failure DESCRIPTION PATTERN LOG-NAME ARGS...: rotate must fail with
# PATTERN in its output.
expect_failure() {
  local description=$1 pattern=$2 log=$3
  shift 3
  if rotate "$log" "$@"; then
    cat "$logs/$log" >&2
    die "$description: the command succeeded"
  fi
  grep -Eq -- "$pattern" "$logs/$log" || { cat "$logs/$log" >&2; die "$description: wrong error"; }
  pass "$description"
}

expect_success() { # description log args...
  local description=$1 log=$2
  shift 2
  rotate "$log" "$@" || { cat "$logs/$log" >&2; die "$description: failed"; }
  pass "$description"
}

# --- Checks the test makes itself (values are streamed, never printed) --------
secret_file() { # namespace secret key file
  k -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d >"$4"
}

secret_sha() { # namespace secret key
  k -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d | sha256sum | cut -c1-64
}

file_sha() { sha256sum <"$1" | cut -c1-64; }

set_secret_key() { # namespace secret key file
  { printf '{"data":{"%s":"' "$3"; base64 -w0 <"$4"; printf '"}}'; } |
    k -n "$1" patch secret "$2" --type merge --patch-file /dev/stdin >/dev/null
}

# Both Secrets hold the content of the given files.
secrets_hold() { # postgres-file redis-file
  local ns_secret
  for ns_secret in data/minishop-data-credentials webapp/minishop-app-credentials; do
    [[ "$(secret_sha "${ns_secret%/*}" "${ns_secret#*/}" postgres-password)" == "$(file_sha "$1")" &&
      "$(secret_sha "${ns_secret%/*}" "${ns_secret#*/}" redis-password)" == "$(file_sha "$2")" ]] || return 1
  done
}

# shellcheck disable=SC2016
pg_logs_in() { # password file: log in over TCP, the clients' path
  local ip
  ip=$(k -n data get pod minishop-postgresql-0 -o 'jsonpath={.status.podIP}')
  { cat "$1"; echo; } | k -n data exec -i minishop-postgresql-0 -c postgresql -- sh -c '
    IFS= read -r PGPASSWORD || true; export PGPASSWORD
    psql -X -At -h "$1" -U minishop -d minishop -c "SELECT 1"' login "$ip" >/dev/null 2>&1
}

# shellcheck disable=SC2016
redis_logs_in() { # password file
  { cat "$1"; echo; } | k -n data exec -i minishop-redis-0 -c redis -- sh -c '
    IFS= read -r REDISCLI_AUTH || true; export REDISCLI_AUTH
    redis-cli --no-auth-warning PING' 2>/dev/null | tr -d '\r' | grep -qx PONG
}

# shellcheck disable=SC2016
role_digest() { # md5 of the stored SCRAM verifier, over the trusted socket
  k -n data exec -i minishop-postgresql-0 -c postgresql -- sh -c \
    'psql -X -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT md5(rolpassword) FROM pg_authid WHERE rolname = current_user"' </dev/null
}

# Pods and Secret versions; a dry run must leave all of them unchanged.
snapshot() {
  k -n data get secret minishop-data-credentials -o 'jsonpath={.metadata.resourceVersion}{"\n"}' 2>/dev/null
  k -n webapp get secret minishop-app-credentials -o 'jsonpath={.metadata.resourceVersion}{"\n"}' 2>/dev/null
  k -n data get pods -o 'jsonpath={range .items[*]}{.metadata.uid}{"\n"}{end}'
  k -n webapp get pods -o 'jsonpath={range .items[*]}{.metadata.uid}{"\n"}{end}'
  role_digest
}

backend_pods() {
  k -n webapp get pods -l app.kubernetes.io/component=minishop-backend \
    -o 'jsonpath={range .items[*]}{.metadata.uid}{"\n"}{end}' | sort
}

pod_uid() { k -n data get pod "$1" -o 'jsonpath={.metadata.uid}'; }

state_dirs() {
  find "$scratch/state" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true
}

# --- Refusals that need no cluster ------------------------------------------------
if bash "$SCRIPT_DIR/rotate-data-credentials.sh" --apply >"$logs/no-context" 2>&1; then
  die "the script ran without --context"
fi
grep -q 'there is no default' "$logs/no-context" || { cat "$logs/no-context" >&2; die "wrong error without --context"; }
pass "refuses to run without --context"
if bash "$SCRIPT_DIR/rotate-data-credentials.sh" --context "$CONTEXT" --kubeconfig "$scratch/none" \
  >"$logs/no-kubeconfig" 2>&1; then
  die "the script ran with a context missing from the kubeconfig"
fi
grep -q 'is not in kubeconfig' "$logs/no-kubeconfig" || die "wrong error for an unknown context"
pass "refuses a context that is not in the kubeconfig"

# --- Throwaway cluster --------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  die "a kind cluster named $CLUSTER exists, maybe from an interrupted run; delete it with kind delete cluster --name $CLUSTER"
fi
printf 'Creating kind cluster %s (kubeconfig in a scratch directory)\n' "$CLUSTER"
cluster_created=true
kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --kubeconfig "$kc" --wait 180s \
  >"$logs/kind" 2>&1 || { cat "$logs/kind" >&2; die "kind create cluster failed"; }
if k get node "$LIVE_NODE" >/dev/null 2>&1; then
  die "the test cluster has the kind-learn node $LIVE_NODE; stopping"
fi

k create namespace data >/dev/null
k create namespace webapp >/dev/null
k -n webapp create serviceaccount minishop-backend >/dev/null
# Throwaway passwords in the shape create-*-credentials.sh users chose
# (48 base64 characters), so the rotation is tested from that format. The
# Secrets are created with `kubectl apply`, like create-*-credentials.sh, so
# they carry the last-applied-configuration annotation.
for key in postgres-password redis-password; do
  head -c 36 /dev/urandom | base64 -w0 >"$scratch/creds/$key"
done
for ns_secret in data/minishop-data-credentials webapp/minishop-app-credentials; do
  k -n "${ns_secret%/*}" create secret generic "${ns_secret#*/}" \
    --from-file=postgres-password="$scratch/creds/postgres-password" \
    --from-file=redis-password="$scratch/creds/redis-password" \
    --dry-run=client -o yaml 2>/dev/null | k apply -f - >/dev/null
done
k -n data get secret minishop-data-credentials \
  -o 'jsonpath={.metadata.annotations}' 2>/dev/null | grep last-applied-configuration >/dev/null ||
  die "the test Secrets lack the last-applied-configuration annotation"

docker run --rm --volume "$DATA_REPO_ROOT/charts/minishop:/chart:ro" "$HELM_IMAGE" \
  template minishop /chart --namespace webapp \
  --set seed.enabled=true --set replicas.backend=2 \
  --show-only templates/postgresql.yaml --show-only templates/redis.yaml \
  --show-only templates/backend.yaml --show-only templates/seed-job.yaml \
  --show-only templates/networkpolicy.yaml >"$scratch/rendered.yaml"
k apply -f "$scratch/rendered.yaml" >/dev/null
printf 'Waiting for the data stack, the backend and the seed Job (image pulls)\n'
k -n data rollout status statefulset/minishop-postgresql --timeout=600s >/dev/null
k -n data rollout status statefulset/minishop-redis --timeout=600s >/dev/null
k -n webapp rollout status deployment/minishop-backend --timeout=600s >/dev/null
k -n webapp wait job -l app.kubernetes.io/component=seed --for=condition=complete --timeout=900s >/dev/null
pass "throwaway MiniShop stack is up and seeded"

# A client next to the frontend: with the frontend's labels the chart's
# NetworkPolicies let it reach the backend Service. It requests /items
# (PostgreSQL) and /items/0/reviews (Redis) every 250 ms and logs
# "<epoch ms> <path> <status or ERR>".
cat >"$scratch/prober.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: rotation-prober
  namespace: webapp
  labels:
    app.kubernetes.io/component: frontend
    app.kubernetes.io/name: minishop
    app.kubernetes.io/part-of: minishop
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: prober
      image: $BACKEND_IMAGE
      command:
        - node
        - -e
        - |
          const http = require("http");
          const get = path => new Promise(resolve => {
            const request = http.get({ host: "minishop-backend", port: 3001, path, timeout: 2000 }, response => {
              response.resume();
              response.on("end", () => resolve(String(response.statusCode)));
            });
            request.on("timeout", () => request.destroy(new Error("timeout")));
            request.on("error", () => resolve("ERR"));
          });
          (async () => {
            for (;;) {
              for (const path of ["/items?q=", "/items/0/reviews"]) {
                console.log(Date.now() + " " + path + " " + await get(path));
              }
              await new Promise(resolve => setTimeout(resolve, 250));
            }
          })();
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { cpu: 100m, memory: 64Mi }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
        readOnlyRootFilesystem: true
YAML
k apply -f "$scratch/prober.yaml" >/dev/null
k -n webapp wait pod rotation-prober --for=condition=Ready --timeout=180s >/dev/null

# probe_summary START-MS END-MS: requests and failures per path in the range.
probe_summary() {
  k -n webapp logs rotation-prober | awk -v a="$1" -v b="$2" '
    $1 >= a && $1 <= b { total[$2]++; if ($3 != "200") failed[$2]++ }
    END { for (p in total) printf "%s %d/%d failed; ", p, failed[p] + 0, total[p] }'
}

bash "$SCRIPT_DIR/backup-data.sh" --kubeconfig "$kc" --context "$CONTEXT" \
  --backup-dir "$scratch/backups" >"$logs/backup" 2>&1 || { cat "$logs/backup" >&2; die "backup failed"; }
redis_keys_before=$(DATA_KUBECONFIG=$kc DATA_CONTEXT=$CONTEXT data_redis_keyspace)
pass "backup taken with backup-data.sh"

# --- Refusals on the cluster ------------------------------------------------------------
expect_failure "refuses without a recent backup" 'no backup set of this target' no-backup \
  --apply --backup-dir "$scratch/no-backups"
cp "$scratch/creds/redis-password" "$scratch/creds/drift"
printf 'x' >>"$scratch/creds/drift"
set_secret_key webapp minishop-app-credentials redis-password "$scratch/creds/drift"
expect_failure "refuses when the two Secrets disagree" 'differs between' drift --apply
set_secret_key webapp minishop-app-credentials redis-password "$scratch/creds/redis-password"
# An old value with a quote could not be pasted back into ALTER ROLE.
printf "quote'in-the-old-password-123" >"$scratch/creds/quoted"
set_secret_key data minishop-data-credentials postgres-password "$scratch/creds/quoted"
expect_failure "refuses an old value outside [A-Za-z0-9+/=]" 'rotate manually' quoted --apply
set_secret_key data minishop-data-credentials postgres-password "$scratch/creds/postgres-password"
secrets_hold "$scratch/creds/postgres-password" "$scratch/creds/redis-password" ||
  die "could not undo the drift"
mkdir -m 755 "$scratch/open-state"
expect_failure "refuses an existing state directory that is not private" 'must be yours and mode 700' \
  open-state --state-dir "$scratch/open-state"
[[ "$(stat -c %a -- "$scratch/open-state")" == 755 ]] || die "the script chmodded an existing state directory"

# --- Dry run ----------------------------------------------------------------------------------
before=$(snapshot)
expect_success "dry run passes its checks" dry-run
grep -q 'Dry run: nothing was changed' "$logs/dry-run" || die "the dry run did not say so"
[[ "$(snapshot)" == "$before" ]] || die "the dry run changed a Secret, the role or a Pod"
[[ -z "$(state_dirs)" ]] || die "the dry run left a work directory"
pass "dry run changes nothing (Secret versions, role password, Pods) and leaves no files"

# --- The lock --------------------------------------------------------------------------------
exec {held}>>"$scratch/state/.lock"
flock -n "$held"
before=$(snapshot)
expect_failure "refuses --apply while another run holds the lock" 'holds .*\.lock' locked --apply
[[ "$(snapshot)" == "$before" ]] || die "the locked-out run changed something"
exec {held}>&-

# --- Failures after ALTER ROLE: automatic rollback ---------------------------------------
# A kubectl wrapper first on PATH acts on the next N calls that match a
# pattern: "fail" makes the call fail; "touch" first annotates the Secret the
# call patches, like a concurrent writer, then runs the call. Every other
# call goes to the real kubectl.
cat >"$scratch/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${FAIL_PATTERN:-}" && " $* " == *"$FAIL_PATTERN"* ]]; then
  left=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
  if [[ "$left" -gt 0 ]]; then
    echo $((left - 1)) >"$FAIL_COUNT_FILE"
    if [[ "${FAIL_MODE:-fail}" == touch ]]; then
      # Arguments: --kubeconfig K --context C -n NS patch secret NAME ...
      "$REAL_KUBECTL" "${@:1:6}" annotate secret "$9" --overwrite \
        "rotation-test/concurrent-writer=$left" >/dev/null 2>&1
    else
      echo "injected failure: $FAIL_PATTERN" >&2
      exit 1
    fi
  fi
fi
exec "$REAL_KUBECTL" "$@"
STUB
chmod 700 "$scratch/bin/kubectl"
REAL_KUBECTL=$(command -v kubectl)
export REAL_KUBECTL FAIL_COUNT_FILE="$scratch/fail-count"
with_failures() { # pattern count description error-pattern log args...
  local pattern=$1 count=$2
  shift 2
  echo "$count" >"$FAIL_COUNT_FILE"
  PATH="$scratch/bin:$PATH" FAIL_PATTERN=$pattern expect_failure "$@"
}

# check_rolled_back LOG: the old passwords are back everywhere.
check_rolled_back() {
  grep -q 'ok: role minishop has the new password' "$logs/$1" || die "$1: the role was not changed before the failure"
  secrets_hold "$scratch/creds/postgres-password" "$scratch/creds/redis-password" ||
    die "$1: the Secrets do not hold the old passwords after the rollback"
  pg_logs_in "$scratch/creds/postgres-password" || die "$1: the old PostgreSQL password does not log in"
  redis_logs_in "$scratch/creds/redis-password" || die "$1: the old Redis password does not log in"
  [[ "$(role_digest)" != "$role_before" ]] || die "$1: the role verifier did not change, so ALTER ROLE never ran"
  [[ "$(backend_pods)" == "$backend_before" ]] || die "$1: the rollback restarted Pods that were never restarted"
  [[ -z "$(state_dirs)" ]] || die "$1: a successful rollback left the work directory"
}

backend_before=$(backend_pods)
role_before=$(role_digest)
with_failures "patch secret minishop-app-credentials" 1 \
  "a failure after ALTER ROLE and the first Secret patch rolls back" 'Rolled back' rollback --apply
# Redaction hides passwords but keeps the names an operator needs.
grep -qF 'failed: injected failure: patch secret minishop-app-credentials' "$logs/rollback" ||
  die "the error output does not name the failed Secret"
check_rolled_back rollback
pass "after the rollback the old passwords work, both Secrets hold them, and no work files remain"

role_before=$(role_digest)
FAIL_MODE="touch" with_failures "patch secret minishop-app-credentials" 1 \
  "a concurrent change to a Secret fails the patch with 409 and rolls back" 'has been modified' conflict --apply
grep -q 'Rolled back' "$logs/conflict" || die "the 409 did not trigger the rollback"
check_rolled_back conflict
pass "after the 409 rollback the old passwords work everywhere"

# --- Happy path, with a client probing throughout ---------------------------------------
started_ms=$(now_ms)
expect_success "rotation of both passwords succeeds" rotate --apply
ended_ms=$(now_ms)
for line in 'ok: postgresql: the new password logs in, the previous one is rejected' \
  'ok: redis: the new password logs in, the previous one is rejected' \
  'Redis keys without a TTL are unchanged' '/items 200' 'client window:' 'Rotation complete'; do
  grep -qF "$line" "$logs/rotate" || { cat "$logs/rotate" >&2; die "missing from the output: $line"; }
done
window=$(sed -n 's/.*ok: client window: \([0-9.]*\) s.*/\1/p' "$logs/rotate")
sleep 2
probes=$(probe_summary "$started_ms" "$ended_ms")
printf 'MEASURED: client window %s s (ALTER ROLE until the backend rollout finished); prober during the whole run: %s\n' \
  "$window" "$probes"
for ns_secret in data/minishop-data-credentials webapp/minishop-app-credentials; do
  if k -n "${ns_secret%/*}" get secret "${ns_secret#*/}" -o 'jsonpath={.metadata.annotations}' 2>/dev/null |
    grep last-applied-configuration >/dev/null; then
    die "$ns_secret still has the last-applied-configuration annotation"
  fi
done
secret_file data minishop-data-credentials postgres-password "$scratch/creds/pg-1"
secret_file data minishop-data-credentials redis-password "$scratch/creds/redis-1"
secrets_hold "$scratch/creds/pg-1" "$scratch/creds/redis-1" || die "the two Secrets differ after the rotation"
[[ "$(wc -c <"$scratch/creds/pg-1")" -eq 64 && "$(wc -c <"$scratch/creds/redis-1")" -eq 64 ]] ||
  die "the new passwords are not 64 characters"
! cmp -s "$scratch/creds/pg-1" "$scratch/creds/postgres-password" || die "the PostgreSQL password did not change"
! cmp -s "$scratch/creds/redis-1" "$scratch/creds/redis-password" || die "the Redis password did not change"
! cmp -s "$scratch/creds/pg-1" "$scratch/creds/redis-1" || die "PostgreSQL and Redis got the same password"
pg_logs_in "$scratch/creds/pg-1" || die "the new PostgreSQL password does not log in"
! pg_logs_in "$scratch/creds/postgres-password" || die "the old PostgreSQL password still logs in"
redis_logs_in "$scratch/creds/redis-1" || die "the new Redis password does not log in"
! redis_logs_in "$scratch/creds/redis-password" || die "the old Redis password still logs in"
[[ -z "$(comm -12 <(backend_pods) <(echo "$backend_before"))" ]] || die "an old backend Pod survived the rotation"
[[ "$(DATA_KUBECONFIG=$kc DATA_CONTEXT=$CONTEXT data_redis_keyspace)" == "$redis_keys_before" ]] ||
  die "Redis lost keys in the rotation"
[[ -z "$(state_dirs)" ]] || die "the rotation left its work directory"
pass "both Secrets agree, old passwords are rejected, Redis keys kept, backend replaced, annotation gone, no work files"

# --- Rollbacks that fail, then --recover ----------------------------------------------------
# Every backend restart fails: the forward run fails after Redis restarted,
# and the rollback cannot restart the backend either.
break_rotation() { # log
  with_failures "rollout restart deployment/minishop-backend" 2 \
    "a failed rollback reports the state and keeps the work directory ($1)" 'ROLLBACK INCOMPLETE' "$1" --apply
  grep -q -- '--recover' "$logs/$1" || die "$1: no recovery command printed"
  grep -q -- '--timeout 300' "$logs/$1" || die "$1: the recovery command drops --timeout"
  grep -q 'old password' "$logs/$1" || die "$1: the state report is missing"
  mapfile -t kept < <(state_dirs)
  [[ ${#kept[@]} -eq 1 ]] || die "$1: expected one kept work directory, found ${#kept[@]}"
  [[ "$(stat -c %a -- "${kept[0]}")" == 700 && -z "$(find "${kept[0]}" -type f ! -perm 600)" ]] ||
    die "$1: the kept work directory is not private"
}

break_rotation broken-old
expect_failure "--recover refuses an --only that differs from the work directory" 'conflicts with' \
  recover-conflict --apply --recover "${kept[0]}" --to old --only redis
expect_success "--recover --to old converges on the old passwords" recover-old \
  --apply --recover "${kept[0]}" --to old
grep -q 'Recovery complete' "$logs/recover-old" || die "recovery did not report completion"
secrets_hold "$scratch/creds/pg-1" "$scratch/creds/redis-1" || die "the Secrets are not back on the old passwords"
pg_logs_in "$scratch/creds/pg-1" || die "the PostgreSQL password from before the failed run does not log in"
redis_logs_in "$scratch/creds/redis-1" || die "the Redis password from before the failed run does not log in"
[[ ! -e "${kept[0]}" ]] || die "--recover did not remove the work directory"
pass "after --recover --to old the old passwords work everywhere and the work directory is gone"

break_rotation broken-new
cp "${kept[0]}/new/postgres-password" "$scratch/creds/pg-new"
cp "${kept[0]}/new/redis-password" "$scratch/creds/redis-new"
expect_success "--recover --to new finishes the rotation" recover-new \
  --apply --recover "${kept[0]}" --to new
secrets_hold "$scratch/creds/pg-new" "$scratch/creds/redis-new" || die "the Secrets do not hold the new passwords"
pg_logs_in "$scratch/creds/pg-new" || die "the new PostgreSQL password does not log in after --recover --to new"
! pg_logs_in "$scratch/creds/pg-1" || die "the previous PostgreSQL password still logs in"
redis_logs_in "$scratch/creds/redis-new" || die "the new Redis password does not log in after --recover --to new"
! redis_logs_in "$scratch/creds/redis-1" || die "the previous Redis password still logs in"
grep -q '/items 200' "$logs/recover-new" || die "--recover --to new did not check the backend"
[[ ! -e "${kept[0]}" ]] || die "--recover did not remove the work directory"
pass "after --recover --to new the new passwords work everywhere and the old ones are rejected"

# --- --only leaves the other password alone ------------------------------------------------
redis_uid=$(pod_uid minishop-redis-0)
expect_success "--only postgresql rotates PostgreSQL alone" only-pg --apply --only postgresql
secret_file data minishop-data-credentials postgres-password "$scratch/creds/pg-2"
secrets_hold "$scratch/creds/pg-2" "$scratch/creds/redis-new" || die "--only postgresql changed the Redis password"
! cmp -s "$scratch/creds/pg-2" "$scratch/creds/pg-new" || die "--only postgresql did not change the PostgreSQL password"
[[ "$(pod_uid minishop-redis-0)" == "$redis_uid" ]] || die "--only postgresql restarted Redis"
pass "--only postgresql kept the Redis password and Pod"

role_before=$(role_digest)
expect_success "--only redis rotates Redis alone" only-redis --apply --only redis
secret_file data minishop-data-credentials redis-password "$scratch/creds/redis-2"
secrets_hold "$scratch/creds/pg-2" "$scratch/creds/redis-2" || die "--only redis changed the PostgreSQL password"
! cmp -s "$scratch/creds/redis-2" "$scratch/creds/redis-new" || die "--only redis did not change the Redis password"
[[ "$(role_digest)" == "$role_before" ]] || die "--only redis ran ALTER ROLE"
[[ "$(pod_uid minishop-redis-0)" != "$redis_uid" ]] || die "--only redis did not restart Redis"
redis_logs_in "$scratch/creds/redis-2" || die "the new Redis password does not log in"
! redis_logs_in "$scratch/creds/redis-new" || die "the previous Redis password still logs in"
grep -q 'client window: .* from the statefulset/minishop-redis restart' "$logs/only-redis" ||
  die "--only redis measured the window from the wrong step"
pass "--only redis kept the PostgreSQL password and role, and restarted Redis"

# --- No password in any output ---------------------------------------------------------------
patterns="$scratch/patterns"
for file in "$scratch/creds"/*; do
  cat "$file"; echo
  base64 -w0 <"$file"; echo
done >"$patterns"
if grep -rlF -f "$patterns" "$logs" >"$scratch/leaks"; then
  die "a password appears in: $(tr '\n' ' ' <"$scratch/leaks")"
fi
# Generated passwords are 64 hex characters; the rotation prints no hashes,
# so no such run may appear in its output (this covers the rolled-back ones).
if grep -rlE '[0-9a-f]{64}' "$logs" --exclude=backup >"$scratch/leaks"; then
  die "a 64-character hex string appears in: $(tr '\n' ' ' <"$scratch/leaks")"
fi
pass "no password, in plain or base64 form, appears in any output"
printf 'All rotation tests passed.\n'
