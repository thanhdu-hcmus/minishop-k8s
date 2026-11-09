#!/usr/bin/env bash
#
# Back up the MiniShop data stack (Issue #40): a PostgreSQL logical dump
# (pg_dump -Fc of the application database) and a point-in-time Redis RDB
# snapshot (redis-cli --rdb, a replication-style sync that writes nothing on
# the server).
#
# The backup only reads from the source. It writes one directory per run,
# <backup-dir>/<UTC stamp>/, holding postgresql.dump, redis.rdb, manifest.txt
# (row and key counts, per-table row digests, per-database key-set digests,
# versions, images) and SHA256SUMS. The run builds the set
# in a hidden .partial-<stamp> directory and renames it only after every check
# passes; on any failure the partial set is deleted. Output is limited to
# counts, sizes and checksums.
#
# Backups hold real data. The backup directory must be outside the repository,
# owned by you, and mode 700; files are written with umask 077.
#
# Usage:
#   bash scripts/backup-data.sh [options]
#
# Source (default: kube, context kind-learn, namespace data):
#   --context NAME          kube context (default kind-learn)
#   --kubeconfig PATH       kubeconfig (default ./.kube/config)
#   --namespace NAME        namespace of the StatefulSets (default data)
#   --pg-pod NAME           PostgreSQL pod (default minishop-postgresql-0)
#   --redis-pod NAME        Redis pod (default minishop-redis-0)
#   --docker                read from docker containers instead of a cluster
#   --pg-container NAME     PostgreSQL container (with --docker)
#   --redis-container NAME  Redis container (with --docker)
# Output:
#   --backup-dir DIR        backup root (default $MINISHOP_BACKUP_DIR, else
#                           ~/minishop-backups)
#   --keep N                after a successful backup, delete all but the
#                           newest N complete sets in the backup root

# DATA_* variables set here are read by data-lib.sh, and in-container commands
# are single-quoted on purpose: they expand inside the container.
# shellcheck disable=SC2016,SC2034

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=data-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/data-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

DATA_CONTEXT=kind-learn
backup_root=${MINISHOP_BACKUP_DIR:-$HOME/minishop-backups}
keep=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) DATA_CONTEXT=${2:?--context needs a value}; shift 2 ;;
    --kubeconfig) DATA_KUBECONFIG=${2:?--kubeconfig needs a value}; shift 2 ;;
    --namespace) DATA_NAMESPACE=${2:?--namespace needs a value}; shift 2 ;;
    --pg-pod) DATA_PG_POD=${2:?--pg-pod needs a value}; shift 2 ;;
    --redis-pod) DATA_REDIS_POD=${2:?--redis-pod needs a value}; shift 2 ;;
    --docker) DATA_TARGET=docker; shift ;;
    --pg-container) DATA_PG_CONTAINER=${2:?--pg-container needs a value}; shift 2 ;;
    --redis-container) DATA_REDIS_CONTAINER=${2:?--redis-container needs a value}; shift 2 ;;
    --backup-dir) backup_root=${2:?--backup-dir needs a value}; shift 2 ;;
    --keep) keep=${2:?--keep needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
if [[ -n "$keep" && ! "$keep" =~ ^[1-9][0-9]*$ ]]; then
  die "--keep must be a positive integer"
fi

umask 077
data_require_commands docker sha256sum awk realpath stat
[[ "$DATA_TARGET" == docker ]] || data_require_commands kubectl

# --- Backup root: outside the repo, ours, private -------------------------
data_require_outside_repo "$backup_root"
if [[ ! -e "$backup_root" ]]; then
  mkdir -p -- "$backup_root"
  chmod 700 -- "$backup_root"
fi
backup_root=$(realpath -- "$backup_root")
[[ -d "$backup_root" ]] || die "$backup_root is not a directory"
[[ "$(stat -c %u -- "$backup_root")" == "$(id -u)" ]] ||
  die "$backup_root is not owned by you"
# A Windows drive mounted without metadata ignores chmod; refuse it.
[[ "$(stat -c %a -- "$backup_root")" == 700 ]] ||
  die "$backup_root must be mode 700 (chmod 700 it; Windows drives under /mnt cannot enforce this)"

pg_image=$(data_chart_image postgresql) || die "no pinned postgresql image in $DATA_VALUES_FILE"
redis_image=$(data_chart_image redis) || die "no pinned redis image in $DATA_VALUES_FILE"

# --- Source checks -----------------------------------------------------------
printf 'Source: %s\n' "$(data_target_label)"
data_require_component postgresql
data_require_component redis

stamp=$(date -u +%Y%m%dT%H%M%SZ)
final_dir="$backup_root/$stamp"
work_dir="$backup_root/.partial-$stamp"
[[ ! -e "$final_dir" && ! -e "$work_dir" ]] || die "$final_dir already exists; retry in a second"

cleanup() {
  if [[ -n "${work_dir:-}" && -d "$work_dir" ]]; then
    rm -rf -- "$work_dir"
    printf 'Backup failed; removed the partial set %s\n' "$work_dir" >&2
  fi
}
trap cleanup EXIT
mkdir -- "$work_dir"
started=$SECONDS

# --- PostgreSQL ---------------------------------------------------------------
pg_version=$(data_pg_server_version)
pg_stats_before=$(data_pg_table_stats) || die "could not count PostgreSQL rows"
[[ -n "$pg_stats_before" ]] || die "the PostgreSQL database has no user tables; refusing an empty backup"
data_exec postgresql sh -ec "$DATA_PG_ENV"' exec pg_dump -Fc' \
  </dev/null >"$work_dir/$DATA_PG_FILE" || die "pg_dump failed"
pg_stats_after=$(data_pg_table_stats) || die "could not count PostgreSQL rows"
# pg_dump reads one snapshot; equal counts and digests on both sides tie the
# recorded values to that snapshot.
[[ "$pg_stats_before" == "$pg_stats_after" ]] ||
  die "PostgreSQL rows changed during pg_dump; retry when writes are quiet"
pg_counts_before=$(data_pg_counts "$pg_stats_before")

pg_list=$(data_local_tool "$pg_image" "$work_dir" pg_restore --list "/backup/$DATA_PG_FILE") ||
  die "pg_restore --list rejected the dump"
pg_table_data=$(grep -c ' TABLE DATA ' <<<"$pg_list" || true)
pg_entries=$(grep -cv '^;' <<<"$pg_list" || true)
pg_table_count=$(wc -l <<<"$pg_counts_before")
[[ "$pg_table_data" -eq "$pg_table_count" ]] ||
  die "dump has $pg_table_data TABLE DATA entries for $pg_table_count tables"

# --- Redis --------------------------------------------------------------------
redis_version=$(data_redis_version)
redis_before=$(data_redis_keyspace) || die "could not read the Redis keyspace"
keyset_before=$(data_redis_keyset_digests) || die "could not list the Redis key set"
redis_log="$work_dir/redis-cli.log"
data_exec redis sh -ec "$DATA_REDIS_ENV"' exec redis-cli --rdb -' \
  </dev/null >"$work_dir/$DATA_REDIS_FILE" 2>"$redis_log" || {
  cat "$redis_log" >&2
  die "redis-cli --rdb failed"
}
redis_after=$(data_redis_keyspace) || die "could not read the Redis keyspace"
keyset_after=$(data_redis_keyset_digests) || die "could not list the Redis key set"
# sha256 of empty input: a database with keys must never list none.
if grep -q '=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855$' <<<"$keyset_before"; then
  die "a Redis database listed no keys"
fi
# With diskless replication redis-cli cannot truncate a pipe, so stdout keeps
# the 40-byte end-of-stream marker after the payload. Cut it to the payload
# length that redis-cli reports.
payload=$(sed -n 's/.*Transfer finished with success after \([0-9][0-9]*\) bytes.*/\1/p' "$redis_log")
if [[ -n "$payload" ]]; then
  size=$(stat -c %s -- "$work_dir/$DATA_REDIS_FILE")
  if [[ "$size" -eq $((payload + 40)) ]]; then
    truncate -s "$payload" -- "$work_dir/$DATA_REDIS_FILE"
  elif [[ "$size" -ne "$payload" ]]; then
    die "Redis snapshot is $size bytes but redis-cli reported $payload"
  fi
elif ! grep -q 'Transfer finished with success' "$redis_log"; then
  cat "$redis_log" >&2
  die "redis-cli did not report a finished transfer"
fi
rm -f -- "$redis_log"

rdb_check=$(data_local_tool "$redis_image" "$work_dir" redis-check-rdb "/backup/$DATA_REDIS_FILE") || {
  grep -E 'RDB ERROR|\[info\]' <<<"$rdb_check" >&2 || true
  die "redis-check-rdb rejected the snapshot"
}
rdb_size=$(stat -c %s -- "$work_dir/$DATA_REDIS_FILE")
grep -Fq "[offset $rdb_size] \\o/ RDB looks OK! \\o/" <<<"$rdb_check" ||
  die "redis-check-rdb did not end cleanly at byte $rdb_size"
rdb_keys=$(sed -n 's/^\[info\] \([0-9][0-9]*\) keys read$/\1/p' <<<"$rdb_check")
rdb_expires=$(sed -n 's/^\[info\] \([0-9][0-9]*\) expires$/\1/p' <<<"$rdb_check")
[[ -n "$rdb_keys" && -n "$rdb_expires" ]] || die "could not read key counts from redis-check-rdb"
redis_total=$(data_sum_counts "$redis_before")
[[ "$redis_before" == "$redis_after" && "$keyset_before" == "$keyset_after" &&
  "$rdb_keys" -eq "$redis_total" ]] ||
  die "Redis keyspace changed during the snapshot ($redis_total live, $rdb_keys in the RDB); retry"

# --- Manifest and checksums ---------------------------------------------------
{
  printf 'format=%s\n' "$DATA_BACKUP_FORMAT"
  printf 'created_utc=%s\n' "$stamp"
  printf 'source=%s\n' "$(data_target_label)"
  printf 'postgresql_image=%s\n' "$(data_running_image postgresql)"
  printf 'postgresql_version=%s\n' "$pg_version"
  printf 'postgresql_table_data_entries=%s\n' "$pg_table_data"
  awk '{ print "postgresql_rows." $0 }' <<<"$pg_counts_before"
  data_pg_digests "$pg_stats_before" | awk '{ print "postgresql_md5." $0 }'
  printf 'redis_image=%s\n' "$(data_running_image redis)"
  printf 'redis_version=%s\n' "$redis_version"
  if [[ -n "$redis_before" ]]; then
    awk '{ print "redis_keys." $0 }' <<<"$redis_before"
    awk '{ print "redis_keyset_sha256." $0 }' <<<"$keyset_before"
  fi
  printf 'redis_keys_total=%s\n' "$rdb_keys"
  printf 'redis_expires=%s\n' "$rdb_expires"
} >"$work_dir/$DATA_MANIFEST_FILE"
(cd "$work_dir" && sha256sum -- "$DATA_PG_FILE" "$DATA_REDIS_FILE" "$DATA_MANIFEST_FILE" >"$DATA_SUMS_FILE")
(cd "$work_dir" && sha256sum --check --strict --quiet "$DATA_SUMS_FILE") || die "checksum re-read failed"
sync -- "$work_dir"/* 2>/dev/null || sync

mv -- "$work_dir" "$final_dir"
work_dir=""
trap - EXIT

# --- Report: counts, sizes and checksums only ---------------------------------
printf 'Backup %s complete in %ss: %s\n' "$stamp" "$((SECONDS - started))" "$final_dir"
while read -r sum file; do
  printf '  %-16s %10s bytes  sha256 %s\n' "$file" "$(stat -c %s -- "$final_dir/$file")" "$sum"
done <"$final_dir/$DATA_SUMS_FILE"
printf '  PostgreSQL %s: pg_restore --list OK (%s entries, %s TABLE DATA); rows %s (digests in the manifest)\n' \
  "$pg_version" "$pg_entries" "$pg_table_data" "$(tr '\n' ' ' <<<"$pg_counts_before" | sed 's/ $//')"
printf '  Redis %s: redis-check-rdb OK (%s keys, %s with expiry); keyspace %s\n' \
  "$redis_version" "$rdb_keys" "$rdb_expires" "$(tr '\n' ' ' <<<"${redis_before:-empty}" | sed 's/ $//')"

# --- Optional pruning of older complete sets ----------------------------------
if [[ -n "$keep" ]]; then
  mapfile -t sets < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
    grep -E "$DATA_STAMP_PATTERN" | sort)
  excess=$((${#sets[@]} - keep))
  for ((i = 0; i < excess; i++)); do
    # Only directories that look like our sets: a stamp name and a SHA256SUMS.
    if [[ -f "$backup_root/${sets[i]}/$DATA_SUMS_FILE" ]]; then
      rm -rf -- "${backup_root:?}/${sets[i]}"
      printf 'Pruned %s (keeping the newest %s)\n' "${sets[i]}" "$keep"
    fi
  done
fi
