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
#       recent backup, and when the two Secrets disagree; that a dry run
#       changes nothing; that a failure after ALTER ROLE rolls back; that a
#       rotation succeeds (old passwords rejected, data intact, /items
#       served); that a failed rollback leaves a work directory from which
#       --recover restores the old passwords; that --only postgresql leaves
#       Redis alone; and that no password appears in any output.
#       --keep-cluster leaves the cluster for inspection.

set -euo pipefail

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

data_require_commands docker kind kubectl base64 sha256sum
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

# --- Checks the test makes itself (never printing a value) --------------------
secret_file() { # namespace secret key file
  local b64
  b64=$(k -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null)
  base64 -d <<<"$b64" >"$4"
}

secret_sha() { # namespace secret key
  k -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d | sha256sum | cut -c1-64
}

file_sha() { sha256sum <"$1" | cut -c1-64; }

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
  k -n data get secret minishop-data-credentials -o 'jsonpath={.metadata.resourceVersion}{"\n"}'
  k -n webapp get secret minishop-app-credentials -o 'jsonpath={.metadata.resourceVersion}{"\n"}'
  k -n data get pods -o 'jsonpath={range .items[*]}{.metadata.uid}{"\n"}{end}'
  k -n webapp get pods -o 'jsonpath={range .items[*]}{.metadata.uid}{"\n"}{end}'
  role_digest
}

backend_pods() {
  k -n webapp get pods -l app.kubernetes.io/component=minishop-backend \
    -o 'jsonpath={range .items[*]}{.metadata.uid}{"\n"}{end}' | sort
}

state_dirs() { find "$scratch/state" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true; }

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
# (48 base64 characters), so the rotation is tested from that format.
for key in postgres-password redis-password; do
  head -c 36 /dev/urandom | base64 -w0 >"$scratch/creds/$key"
done
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
k apply -f "$scratch/rendered.yaml" >/dev/null
printf 'Waiting for the data stack, the backend and the seed Job (image pulls)\n'
k -n data rollout status statefulset/minishop-postgresql --timeout=600s >/dev/null
k -n data rollout status statefulset/minishop-redis --timeout=600s >/dev/null
k -n webapp rollout status deployment/minishop-backend --timeout=600s >/dev/null
k -n webapp wait job -l app.kubernetes.io/component=seed --for=condition=complete --timeout=900s >/dev/null
pass "throwaway MiniShop stack is up and seeded"

bash "$SCRIPT_DIR/backup-data.sh" --kubeconfig "$kc" --context "$CONTEXT" \
  --backup-dir "$scratch/backups" >"$logs/backup" 2>&1 || { cat "$logs/backup" >&2; die "backup failed"; }
redis_keys_before=$(DATA_KUBECONFIG=$kc DATA_CONTEXT=$CONTEXT data_redis_keyspace)
pass "backup taken with backup-data.sh"

# --- Refusals on the cluster ------------------------------------------------------------
expect_failure "refuses without a recent backup" 'no backup set of this target' no-backup \
  --apply --backup-dir "$scratch/no-backups"
cp "$scratch/creds/redis-password" "$scratch/creds/drift"
printf 'x' >>"$scratch/creds/drift"
{ printf '{"data":{"redis-password":"'; base64 -w0 <"$scratch/creds/drift"; printf '"}}'; } |
  k -n webapp patch secret minishop-app-credentials --type merge --patch-file /dev/stdin >/dev/null
expect_failure "refuses when the two Secrets disagree" 'differs between' drift --apply
{ printf '{"data":{"redis-password":"'; base64 -w0 <"$scratch/creds/redis-password"; printf '"}}'; } |
  k -n webapp patch secret minishop-app-credentials --type merge --patch-file /dev/stdin >/dev/null
secrets_hold "$scratch/creds/postgres-password" "$scratch/creds/redis-password" ||
  die "could not undo the drift"

# --- Dry run ----------------------------------------------------------------------------------
before=$(snapshot)
expect_success "dry run passes its checks" dry-run
grep -q 'Dry run: nothing was changed' "$logs/dry-run" || die "the dry run did not say so"
[[ "$(snapshot)" == "$before" ]] || die "the dry run changed a Secret, the role or a Pod"
[[ -z "$(state_dirs)" ]] || die "the dry run left a work directory"
pass "dry run changes nothing (Secret versions, role password, Pods) and leaves no files"

# --- Failure after ALTER ROLE: automatic rollback -----------------------------------------
# A kubectl wrapper first on PATH fails the next N calls that match a pattern
# and passes every other call to the real kubectl.
cat >"$scratch/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${FAIL_PATTERN:-}" && " $* " == *"$FAIL_PATTERN"* ]]; then
  left=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
  if [[ "$left" -gt 0 ]]; then
    echo $((left - 1)) >"$FAIL_COUNT_FILE"
    echo "injected failure: $FAIL_PATTERN" >&2
    exit 1
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

backend_before=$(backend_pods)
role_before=$(role_digest)
with_failures "patch secret minishop-app-credentials" 1 \
  "a failure after ALTER ROLE and the first Secret patch rolls back" 'Rolled back' rollback --apply
grep -q 'ok: role minishop has the new password' "$logs/rollback" || die "the role was not changed before the failure"
# Redaction hides passwords but keeps the names an operator needs.
grep -qF 'failed: injected failure: patch secret minishop-app-credentials' "$logs/rollback" ||
  die "the error output does not name the failed Secret"
secrets_hold "$scratch/creds/postgres-password" "$scratch/creds/redis-password" ||
  die "the Secrets do not hold the old passwords after the rollback"
pg_logs_in "$scratch/creds/postgres-password" || die "the old PostgreSQL password does not log in after the rollback"
redis_logs_in "$scratch/creds/redis-password" || die "the old Redis password does not log in after the rollback"
[[ "$(role_digest)" != "$role_before" ]] || die "the role verifier did not change, so ALTER ROLE never ran"
[[ "$(backend_pods)" == "$backend_before" ]] || die "the rollback restarted Pods that were never restarted"
[[ -z "$(state_dirs)" ]] || die "a successful rollback left the work directory"
pass "after the rollback the old passwords work, both Secrets hold them, and no work files remain"

# --- Happy path ------------------------------------------------------------------------------
expect_success "rotation of both passwords succeeds" rotate --apply
for line in 'ok: postgresql: the new password logs in, the previous one is rejected' \
  'ok: redis: the new password logs in, the previous one is rejected' \
  'Redis keys without a TTL are unchanged' '/items 200' 'Rotation complete'; do
  grep -qF "$line" "$logs/rotate" || { cat "$logs/rotate" >&2; die "missing from the output: $line"; }
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
pass "both Secrets agree, old passwords are rejected, Redis keys kept, backend replaced, no work files"

# --- Rollback that fails, then --recover ---------------------------------------------------
# Every backend restart fails: the forward run fails after Redis restarted,
# and the rollback cannot restart the backend either.
with_failures "rollout restart deployment/minishop-backend" 2 \
  "a failed rollback reports the state and keeps the work directory" 'ROLLBACK INCOMPLETE' broken --apply
grep -q -- '--recover' "$logs/broken" || die "no recovery command printed"
mapfile -t kept < <(state_dirs)
[[ ${#kept[@]} -eq 1 ]] || die "expected one kept work directory, found ${#kept[@]}"
[[ "$(stat -c %a -- "${kept[0]}")" == 700 && -z "$(find "${kept[0]}" -type f ! -perm 600)" ]] ||
  die "the kept work directory is not private"
grep -q 'old password' "$logs/broken" || die "the state report is missing"
expect_success "--recover --to old converges on the old passwords" recover \
  --apply --recover "${kept[0]}" --to old
grep -q 'Recovery complete' "$logs/recover" || die "recovery did not report completion"
secrets_hold "$scratch/creds/pg-1" "$scratch/creds/redis-1" || die "the Secrets are not back on the old passwords"
pg_logs_in "$scratch/creds/pg-1" || die "the PostgreSQL password from before the failed run does not log in"
redis_logs_in "$scratch/creds/redis-1" || die "the Redis password from before the failed run does not log in"
[[ ! -e "${kept[0]}" ]] || die "--recover did not remove the work directory"
pass "after --recover the old passwords work everywhere and the work directory is gone"

# --- --only postgresql leaves Redis alone ------------------------------------------------
redis_uid=$(k -n data get pod minishop-redis-0 -o 'jsonpath={.metadata.uid}')
expect_success "--only postgresql rotates PostgreSQL alone" only-pg --apply --only postgresql
secret_file data minishop-data-credentials postgres-password "$scratch/creds/pg-2"
secrets_hold "$scratch/creds/pg-2" "$scratch/creds/redis-1" || die "--only postgresql changed the Redis password"
! cmp -s "$scratch/creds/pg-2" "$scratch/creds/pg-1" || die "--only postgresql did not change the PostgreSQL password"
[[ "$(k -n data get pod minishop-redis-0 -o 'jsonpath={.metadata.uid}')" == "$redis_uid" ]] ||
  die "--only postgresql restarted Redis"
pass "--only postgresql kept the Redis password and Pod"

# --- No password in any output ---------------------------------------------------------------
patterns="$scratch/patterns"
for file in "$scratch/creds/postgres-password" "$scratch/creds/redis-password" \
  "$scratch/creds/pg-1" "$scratch/creds/redis-1" "$scratch/creds/pg-2"; do
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
