#!/usr/bin/env bash
#
# Restore a backup set made by backup-data.sh into a target you name
# (Issue #40), then check that row counts, per-table row digests, key counts
# and key-set digests match the set's manifest.
#
# The restore replaces data. It refuses to run without an explicit target, and
# refuses the live cluster kind-learn unless --allow-kind-learn is given.
#
# PostgreSQL: pg_restore --clean --if-exists --no-owner --no-privileges
#   --single-transaction into the target's application database, as the
#   target's application user. Tables in the dump are dropped and recreated in
#   one transaction, so a failure leaves the database as it was. Tables that
#   exist only in the target are left alone (reported as a warning).
# Redis: the snapshot is copied into the Redis container, served by a
#   temporary redis-server bound to 127.0.0.1 with a one-time password, and the
#   target Redis replicates from it (REPLICAOF) and is then promoted back
#   (REPLICAOF NO ONE). This loads the snapshot without restarting the Pod, and
#   Redis rewrites its AOF from the new data set. While it syncs the target is
#   a read-only replica; if the restore fails part-way, Redis may be left empty
#   until the restore is run again.
#
# Usage:
#   bash scripts/restore-data.sh --from DIR TARGET [options]
#
#   --from DIR              a complete backup set (<backup-dir>/<UTC stamp>)
# TARGET, one of:
#   --context NAME          kube context of the target cluster (no default)
#     --kubeconfig PATH     kubeconfig (default ./.kube/config)
#     --namespace NAME      namespace (default data)
#     --pg-pod NAME         PostgreSQL pod (default minishop-postgresql-0)
#     --redis-pod NAME      Redis pod (default minishop-redis-0)
#   --docker --pg-container NAME --redis-container NAME
# Options:
#   --only postgresql|redis restore one component (default both)
#   --allow-kind-learn      permit the live kind-learn cluster as the target;
#                           this overwrites its data (owner decision only)
#   --sync-timeout SECONDS  limit for the Redis sync and AOF rewrite (default 300)

# DATA_* variables set here are read by data-lib.sh, and in-container commands
# are single-quoted on purpose: they expand inside the container.
# shellcheck disable=SC2016,SC2034

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=data-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/data-lib.sh"

readonly LIVE_CONTEXT=kind-learn
readonly REDIS_RESTORE_PORT=16379

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

from=""
only=""
allow_live=false
sync_timeout=300
docker_target=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) from=${2:?--from needs a value}; shift 2 ;;
    --context) DATA_CONTEXT=${2:?--context needs a value}; shift 2 ;;
    --kubeconfig) DATA_KUBECONFIG=${2:?--kubeconfig needs a value}; shift 2 ;;
    --namespace) DATA_NAMESPACE=${2:?--namespace needs a value}; shift 2 ;;
    --pg-pod) DATA_PG_POD=${2:?--pg-pod needs a value}; shift 2 ;;
    --redis-pod) DATA_REDIS_POD=${2:?--redis-pod needs a value}; shift 2 ;;
    --docker) docker_target=true; shift ;;
    --pg-container) DATA_PG_CONTAINER=${2:?--pg-container needs a value}; shift 2 ;;
    --redis-container) DATA_REDIS_CONTAINER=${2:?--redis-container needs a value}; shift 2 ;;
    --only) only=${2:?--only needs a value}; shift 2 ;;
    --allow-kind-learn) allow_live=true; shift ;;
    --sync-timeout) sync_timeout=${2:?--sync-timeout needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$from" ]] || { usage; die "--from is required"; }
case "$only" in
  '') components=(postgresql redis) ;;
  postgresql | redis) components=("$only") ;;
  *) die "--only must be postgresql or redis" ;;
esac
[[ "$sync_timeout" =~ ^[1-9][0-9]*$ ]] || die "--sync-timeout must be a positive integer"

# --- Target: explicit, and never kind-learn by accident ------------------------
if [[ "$docker_target" == true ]]; then
  [[ -z "$DATA_CONTEXT" ]] || die "use either --context or --docker, not both"
  DATA_TARGET=docker
  data_require_commands docker
  for component in "${components[@]}"; do
    case "$component" in
      postgresql) [[ -n "$DATA_PG_CONTAINER" ]] || die "--docker needs --pg-container" ;;
      redis) [[ -n "$DATA_REDIS_CONTAINER" ]] || die "--docker needs --redis-container" ;;
    esac
  done
else
  [[ -n "$DATA_CONTEXT" ]] || die "name the target with --context NAME or --docker; there is no default"
  data_require_commands kubectl
  # Match the context name and the cluster it points at, so an alias of the
  # live cluster is caught too. Both checks run before any API call.
  target_cluster=$(kubectl --kubeconfig "$DATA_KUBECONFIG" config view \
    -o "jsonpath={.contexts[?(@.name==\"$DATA_CONTEXT\")].context.cluster}") ||
    die "could not read kubeconfig $DATA_KUBECONFIG"
  [[ -n "$target_cluster" ]] || die "context $DATA_CONTEXT is not in $DATA_KUBECONFIG"
  if [[ "$DATA_CONTEXT" == "$LIVE_CONTEXT" || "$target_cluster" == "$LIVE_CONTEXT" ]] &&
    [[ "$allow_live" != true ]]; then
    die "refusing to restore into the live cluster $LIVE_CONTEXT (context $DATA_CONTEXT); this overwrites its data. Pass --allow-kind-learn only on an owner decision (docs/decisions/0013-data-backup-restore.md)"
  fi
fi

umask 077
data_require_commands sha256sum awk comm realpath

# --- Backup set: complete and intact -------------------------------------------
[[ -d "$from" ]] || die "$from is not a directory"
from=$(realpath -- "$from")
for file in "$DATA_PG_FILE" "$DATA_REDIS_FILE" "$DATA_MANIFEST_FILE" "$DATA_SUMS_FILE"; do
  [[ -f "$from/$file" ]] || die "$from has no $file; not a complete backup set"
done
(cd "$from" && sha256sum --check --strict --quiet "$DATA_SUMS_FILE") ||
  die "checksum mismatch in $from; refusing to restore"
for file in "$DATA_PG_FILE" "$DATA_REDIS_FILE" "$DATA_MANIFEST_FILE"; do
  grep -Eq "^[0-9a-f]{64}  $file\$" "$from/$DATA_SUMS_FILE" || die "$DATA_SUMS_FILE does not cover $file"
done
manifest_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2) }' "$from/$DATA_MANIFEST_FILE"
}
[[ "$(manifest_value format)" == "$DATA_BACKUP_FORMAT" ]] || die "unknown backup format in $from"
printf 'Backup set %s: checksums OK (source %s)\n' "$(manifest_value created_utc)" "$(manifest_value source)"
printf 'Target: %s\n' "$(data_target_label)"
for component in "${components[@]}"; do
  data_require_component "$component"
done
started=$SECONDS

# --- PostgreSQL -------------------------------------------------------------------
# Lines of "expected" missing from "actual" (both "name=value" lists).
missing_lines() {
  comm -23 <(sort <<<"$1") <(sort <<<"$2")
}

restore_postgresql() {
  local expected expected_md5 stats actual extra missing
  expected=$(sed -n 's/^postgresql_rows\.//p' "$from/$DATA_MANIFEST_FILE")
  expected_md5=$(sed -n 's/^postgresql_md5\.//p' "$from/$DATA_MANIFEST_FILE")
  [[ -n "$expected" && -n "$expected_md5" ]] || die "manifest has no PostgreSQL row counts or digests"
  printf 'PostgreSQL: restoring %s (target %s)\n' "$DATA_PG_FILE" "$(data_pg_server_version)"
  # lock_timeout stops the restore waiting forever behind a client's lock.
  data_exec postgresql sh -ec "$DATA_PG_ENV"' export PGOPTIONS="-c lock_timeout=30s";
    exec pg_restore --clean --if-exists --no-owner --no-privileges \
      --single-transaction --exit-on-error -d "$POSTGRES_DB"' \
    <"$from/$DATA_PG_FILE" || die "pg_restore failed; the transaction was rolled back"
  stats=$(data_pg_table_stats) || die "could not count PostgreSQL rows after the restore"
  actual=$(data_pg_counts "$stats")
  # Every table in the backup must have exactly the recorded rows.
  missing=$(missing_lines "$expected" "$actual")
  if [[ -n "$missing" ]]; then
    printf '  expected %s\n  restored %s\n' "$(tr '\n' ' ' <<<"$missing")" "$(tr '\n' ' ' <<<"$actual")" >&2
    die "PostgreSQL row counts do not match the backup"
  fi
  missing=$(missing_lines "$expected_md5" "$(data_pg_digests "$stats")")
  [[ -z "$missing" ]] || die "PostgreSQL row digests differ from the backup for: $(cut -d= -f1 <<<"$missing" | tr '\n' ' ')"
  extra=$(comm -13 <(cut -d= -f1 <<<"$expected" | sort) <(cut -d= -f1 <<<"$actual" | sort))
  [[ -z "$extra" ]] || printf '  warning: tables not in the backup were left as they are: %s\n' "$(tr '\n' ' ' <<<"$extra")"
  printf '  rows and row digests match the backup: %s\n' "$(tr '\n' ' ' <<<"$expected" | sed 's/ $//')"
}

# --- Redis ------------------------------------------------------------------------
# Runs inside the Redis container with the snapshot on stdin.
# Arguments: expected sha256, temporary port, timeout in seconds, and the
# expected key count ("-" when keys with a TTL may have expired).
readonly REDIS_RESTORE_SCRIPT='
set -eu
export REDISCLI_AUTH="$REDIS_PASSWORD"
sha=$1 port=$2 timeout=$3
dir=/data/.minishop-restore
replicating=false
tmp_pw=""
cleanup() {
  status=$?
  if [ "$replicating" = true ]; then
    redis-cli REPLICAOF NO ONE >/dev/null 2>&1 || true
    redis-cli CONFIG SET masterauth "" >/dev/null 2>&1 || true
  fi
  if [ -n "$tmp_pw" ]; then
    REDISCLI_AUTH="$tmp_pw" redis-cli -p "$port" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
  fi
  rm -rf "$dir"
  exit "$status"
}
field() { redis-cli "$@" | tr -d "\r"; }
tmp_field() { REDISCLI_AUTH="$tmp_pw" redis-cli -p "$port" "$@" | tr -d "\r"; }
wait_for() { # description, shell condition
  i=0
  until eval "$2"; do
    i=$((i + 1))
    if [ "$i" -gt "$timeout" ]; then echo "timed out waiting for $1" >&2; exit 1; fi
    sleep 1
  done
}
if [ -e "$dir" ]; then
  echo "$dir is left from an interrupted restore; check no temporary redis-server runs on port $port, then remove it" >&2
  exit 1
fi
if redis-cli -p "$port" PING >/dev/null 2>&1; then
  echo "port $port is in use in the Redis container" >&2
  exit 1
fi
trap cleanup EXIT
trap "exit 1" INT TERM
umask 077
mkdir "$dir"
cat >"$dir/dump.rdb"
echo "$sha  $dir/dump.rdb" | sha256sum -c --quiet - || { echo "snapshot changed in transfer" >&2; exit 1; }
tmp_pw=$(od -An -tx1 -N24 /dev/urandom | tr -d " \n")
printf "requirepass %s\n" "$tmp_pw" | redis-server - --port "$port" --bind 127.0.0.1 \
  --dir "$dir" --dbfilename dump.rdb --appendonly no --save "" \
  --daemonize yes --logfile "$dir/server.log" --pidfile "$dir/server.pid" >/dev/null
wait_for "the temporary server" \
  "tmp_field INFO persistence 2>/dev/null | grep -qx loading:0"
loaded=0
for n in $(tmp_field INFO keyspace | sed -n "s/^db[0-9]*:keys=\([0-9]*\),.*/\1/p"); do
  loaded=$((loaded + n))
done
if [ "$4" != - ] && [ "$loaded" != "$4" ]; then
  echo "the temporary server did not load the expected $4 keys" >&2
  exit 1
fi
printf "%s" "$tmp_pw" | redis-cli -x CONFIG SET masterauth >/dev/null
replicating=true
redis-cli REPLICAOF 127.0.0.1 "$port" >/dev/null
wait_for "the replication sync" \
  "field INFO replication | grep -qx master_link_status:up && field INFO replication | grep -qx master_sync_in_progress:0 && field INFO persistence | grep -qx loading:0"
redis-cli REPLICAOF NO ONE >/dev/null
redis-cli CONFIG SET masterauth "" >/dev/null
replicating=false
if field INFO persistence | grep -qx aof_enabled:1; then
  wait_for "the AOF rewrite" \
    "field INFO persistence | grep -qx aof_rewrite_in_progress:0 && field INFO persistence | grep -qx aof_rewrite_scheduled:0"
  field INFO persistence | grep -qx aof_last_bgrewrite_status:ok || { echo "AOF rewrite failed" >&2; exit 1; }
  field INFO persistence | grep -qx aof_last_write_status:ok || { echo "AOF write failed" >&2; exit 1; }
fi
field INFO replication | grep -qx role:master || { echo "Redis did not return to master" >&2; exit 1; }
'

restore_redis() {
  local sha expected actual expected_total expires actual_total
  sha=$(awk -v f="$DATA_REDIS_FILE" '$2 == f { print $1 }' "$from/$DATA_SUMS_FILE")
  expected=$(sed -n 's/^redis_keys\.//p' "$from/$DATA_MANIFEST_FILE")
  expected_total=$(manifest_value redis_keys_total)
  expires=$(manifest_value redis_expires)
  [[ "$expected_total" =~ ^[0-9]+$ && "$expires" =~ ^[0-9]+$ ]] || die "manifest has no Redis key counts"
  printf 'Redis: restoring %s (target %s) by replication from a temporary server\n' \
    "$DATA_REDIS_FILE" "$(data_redis_version)"
  local load_check=-
  [[ "$expires" -ne 0 ]] || load_check=$expected_total
  data_exec redis sh -c "$REDIS_RESTORE_SCRIPT" restore "$sha" "$REDIS_RESTORE_PORT" \
    "$sync_timeout" "$load_check" <"$from/$DATA_REDIS_FILE" || die "Redis restore failed"
  actual=$(data_redis_keyspace) || die "could not read the Redis keyspace after the restore"
  actual_total=$(data_sum_counts "$actual")
  if [[ "$expires" -eq 0 ]]; then
    [[ "$actual" == "$expected" ]] || {
      printf '  expected %s; restored %s\n' "$(tr '\n' ' ' <<<"$expected")" "$(tr '\n' ' ' <<<"$actual")" >&2
      die "Redis key counts do not match the backup"
    }
    [[ "$(data_redis_keyset_digests)" == "$(sed -n 's/^redis_keyset_sha256\.//p' "$from/$DATA_MANIFEST_FILE")" ]] ||
      die "the restored Redis key set differs from the backup"
    printf '  keys and key-set digests match the backup: %s (total %s)\n' \
      "$(tr '\n' ' ' <<<"${actual:-empty}" | sed 's/ $//')" "$actual_total"
  else
    # Keys with a TTL may expire between backup and restore, so neither the
    # count nor the key set has to match exactly.
    [[ "$actual_total" -le "$expected_total" && "$actual_total" -ge $((expected_total - expires)) ]] ||
      die "Redis has $actual_total keys; the backup has $expected_total ($expires with expiry)"
    printf '  keys within the backup range: total %s of %s (%s with expiry)\n' \
      "$actual_total" "$expected_total" "$expires"
  fi
}

for component in "${components[@]}"; do
  "restore_$component"
done
printf 'Restore of %s into %s complete in %ss\n' "$(manifest_value created_utc)" "$(data_target_label)" "$((SECONDS - started))"
