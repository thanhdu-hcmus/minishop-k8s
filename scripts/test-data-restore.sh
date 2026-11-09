#!/usr/bin/env bash
#
# Test backup-data.sh and restore-data.sh on throwaway Docker containers built
# from the chart's pinned postgres and redis digests (Issue #40). The
# containers run with --network none and the chart's user, environment and
# Redis command, and are removed on exit. No cluster is touched.
#
# Usage:
#   bash scripts/test-data-restore.sh
#       Self-test: seed synthetic data in source containers, back it up,
#       restore it over different data in target containers, check counts and
#       that Redis keeps the data across a restart (AOF), then check that the
#       scripts refuse kind-learn, a tampered set, a backup dir in the repo and
#       a stopped source, and that --keep prunes.
#   bash scripts/test-data-restore.sh --from DIR
#       Restore drill: restore an existing backup set (for example one taken
#       from kind-learn) into fresh target containers and check its counts.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=data-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/data-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

from=""
case "${1:-}" in
  '') ;;
  --from) from=${2:?--from needs a value}; shift 2 ;;
  -h | --help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
[[ $# -eq 0 ]] || { usage; exit 2; }

data_require_commands docker sha256sum
umask 077
pg_image=$(data_chart_image postgresql) || die "no pinned postgresql image"
redis_image=$(data_chart_image redis) || die "no pinned redis image"
prefix="minishop-restore-test-$$"
containers=()
scratch=$(mktemp -d)

cleanup() {
  if [[ ${#containers[@]} -gt 0 ]]; then
    docker rm -f -v "${containers[@]}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT

# Throwaway credentials: random, exported only to `docker run -e NAME`, never
# printed.
POSTGRES_PASSWORD=$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')
REDIS_PASSWORD=$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')
export POSTGRES_PASSWORD REDIS_PASSWORD

wait_until() { # description, command...
  local description=$1 i
  shift
  for ((i = 0; i < 90; i++)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "timed out waiting for $description"
}

redis_ready() {
  # shellcheck disable=SC2016
  docker exec "$1" sh -ec 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli INFO persistence' |
    tr -d '\r' | grep -qx loading:0
}

start_postgresql() {
  containers+=("$1")
  docker run -d --name "$1" --network none --user 999:999 \
    -e POSTGRES_DB=minishop -e POSTGRES_USER=minishop -e POSTGRES_PASSWORD \
    -e PGDATA=/var/lib/postgresql/data/pgdata "$pg_image" >/dev/null
  # During initdb the server listens on the socket only; TCP on 127.0.0.1
  # answers once the final server is up.
  wait_until "PostgreSQL in $1" docker exec "$1" pg_isready -h 127.0.0.1 -U minishop -d minishop
}

start_redis() {
  containers+=("$1")
  # shellcheck disable=SC2016
  docker run -d --name "$1" --network none --user 999:999 -e REDIS_PASSWORD "$redis_image" \
    sh -ec 'exec redis-server --appendonly yes --appendfsync everysec --requirepass "$REDIS_PASSWORD"' >/dev/null
  wait_until "Redis in $1" redis_ready "$1"
}

psql_in() { # container; SQL on stdin
  # shellcheck disable=SC2016
  docker exec -i "$1" sh -ec 'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -X -q -At -v ON_ERROR_STOP=1 -U minishop -d minishop'
}

redis_in() { # container, redis-cli arguments...
  local container=$1
  shift
  # shellcheck disable=SC2016
  docker exec "$container" sh -ec 'REDISCLI_AUTH="$REDIS_PASSWORD" exec redis-cli "$@"' redis-cli "$@"
}

docker_target() { # pg container, redis container
  printf '%s\n' --docker --pg-container "$1" --redis-container "$2"
}

pass() { printf 'PASS: %s\n' "$*"; }

# expect_failure DESCRIPTION PATTERN COMMAND... runs COMMAND, which must fail
# with PATTERN in its stderr.
expect_failure() {
  local description=$1 pattern=$2 err="$scratch/stderr"
  shift 2
  if "$@" >/dev/null 2>"$err"; then
    die "$description: the command succeeded"
  fi
  grep -Eq "$pattern" "$err" || { cat "$err" >&2; die "$description: wrong error"; }
  pass "$description"
}

start_targets() {
  start_postgresql "$prefix-dst-pg"
  start_redis "$prefix-dst-redis"
  # Data that the restore must replace.
  psql_in "$prefix-dst-pg" <<'SQL'
CREATE TABLE marketitems (id integer PRIMARY KEY, name text);
INSERT INTO marketitems SELECT g, 'stale-' || g FROM generate_series(1, 3) g;
SQL
  redis_in "$prefix-dst-redis" MSET stale:1 x stale:2 y stale:3 z >/dev/null
}

check_restart_keeps_redis() { # container, expected keyspace lines
  docker restart "$1" >/dev/null
  wait_until "Redis in $1 after restart" redis_ready "$1"
  local after
  after=$(DATA_TARGET=docker DATA_REDIS_CONTAINER=$1 data_redis_keyspace)
  [[ "$after" == "$2" ]] || die "Redis lost the restored keys on restart: $after"
  pass "Redis in $1 keeps the restored keys across a restart (AOF)"
}

# --- Drill mode: restore a given backup set into throwaway targets -----------
if [[ -n "$from" ]]; then
  [[ -d "$from" ]] || die "$from is not a directory"
  start_targets
  mapfile -t target < <(docker_target "$prefix-dst-pg" "$prefix-dst-redis")
  bash "$SCRIPT_DIR/restore-data.sh" --from "$from" "${target[@]}"
  check_restart_keeps_redis "$prefix-dst-redis" \
    "$(sed -n 's/^redis_keys\.//p' "$from/$DATA_MANIFEST_FILE")"
  pass "drill: $(basename "$from") restored into throwaway containers"
  exit 0
fi

# --- Self-test ----------------------------------------------------------------
start_postgresql "$prefix-src-pg"
start_redis "$prefix-src-redis"
psql_in "$prefix-src-pg" <<'SQL'
CREATE TABLE marketitems (id integer PRIMARY KEY, name text NOT NULL, price numeric(10, 2));
INSERT INTO marketitems SELECT g, 'item-' || g, g * 1.25 FROM generate_series(1, 100) g;
CREATE TABLE runtime_validation (id serial PRIMARY KEY, note text);
INSERT INTO runtime_validation (note) VALUES ('a'), ('b');
SQL
# shellcheck disable=SC2016
docker exec "$prefix-src-redis" sh -ec 'export REDISCLI_AUTH="$REDIS_PASSWORD"
  i=1; while [ "$i" -le 100 ]; do echo "SET item:$i value-$i"; i=$((i + 1)); done | redis-cli >/dev/null
  redis-cli -n 1 MSET other:1 a other:2 b >/dev/null'
start_targets

backups="$scratch/backups"
mapfile -t source < <(docker_target "$prefix-src-pg" "$prefix-src-redis")
mapfile -t target < <(docker_target "$prefix-dst-pg" "$prefix-dst-redis")
bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups"
set_dir=$(find "$backups" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ "$(stat -c %a -- "$backups") $(stat -c %a -- "$set_dir")" == "700 700" ]] ||
  die "backup directories are not mode 700"
[[ -z "$(find "$set_dir" -type f ! -perm 600)" ]] || die "backup files are not mode 600"
pass "backup set is private (700 directories, 600 files)"

bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" "${target[@]}"
[[ "$(psql_in "$prefix-dst-pg" <<<"SELECT count(*), sum(price) FROM marketitems")" == "100|6312.50" ]] ||
  die "restored marketitems differ from the source"
[[ "$(redis_in "$prefix-dst-redis" EXISTS stale:1)" == 0 ]] || die "stale Redis keys survived"
[[ "$(redis_in "$prefix-dst-redis" GET item:42)" == value-42 ]] || die "restored Redis values differ"
pass "restore replaced the target data with the source data"
check_restart_keeps_redis "$prefix-dst-redis" $'db0=100\ndb1=2'
bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" "${target[@]}" >/dev/null
pass "a second restore over restored data succeeds"
# A restore whose rows differ from the manifest must fail: change one value in
# a copy of the manifest's digest line and re-sign the set.
forged="$scratch/forged"
cp -a -- "$set_dir" "$forged"
sed -i 's/^\(postgresql_md5\.public\.marketitems=\).*/\100000000000000000000000000000000/' \
  "$forged/$DATA_MANIFEST_FILE"
(cd "$forged" && sha256sum -- "$DATA_PG_FILE" "$DATA_REDIS_FILE" "$DATA_MANIFEST_FILE" >"$DATA_SUMS_FILE")
expect_failure "restore detects rows that differ from the recorded digest" 'row digests differ' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$forged" "${target[@]}" --only postgresql

# Guards.
fake_kubeconfig="$scratch/kubeconfig"
cat >"$fake_kubeconfig" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: kind-learn
    cluster: { server: "https://127.0.0.1:1" }
contexts:
  - name: kind-learn
    context: { cluster: kind-learn, user: nobody }
  - name: alias
    context: { cluster: kind-learn, user: nobody }
users:
  - name: nobody
    user: {}
YAML
expect_failure "restore refuses kind-learn without --allow-kind-learn" 'refusing to restore into the live cluster' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" --kubeconfig "$fake_kubeconfig" --context kind-learn
expect_failure "restore refuses a context that points at the kind-learn cluster" 'refusing to restore into the live cluster' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" --kubeconfig "$fake_kubeconfig" --context alias
expect_failure "restore refuses to run without a target" 'name the target' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir"
tampered="$scratch/tampered"
cp -a -- "$set_dir" "$tampered"
printf 'x' >>"$tampered/$DATA_REDIS_FILE"
expect_failure "restore refuses a set whose checksum does not match" 'checksum mismatch' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$tampered" "${target[@]}"
expect_failure "backup refuses a backup dir inside the repository" 'inside the repository' \
  bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$DATA_REPO_ROOT/backups"
[[ ! -e "$DATA_REPO_ROOT/backups" ]] || die "a backups directory was created in the repository"

docker stop "$prefix-src-redis" >/dev/null
expect_failure "backup fails closed when Redis is down" 'is not running' \
  bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups"
docker start "$prefix-src-redis" >/dev/null
wait_until "Redis in $prefix-src-redis" redis_ready "$prefix-src-redis"
# Break redis-cli after the PostgreSQL dump has been written.
docker exec -u 0 "$prefix-src-redis" chmod 000 /usr/local/bin/redis-cli
expect_failure "backup fails closed when a client tool fails mid-run" 'removed the partial set' \
  bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups"
docker exec -u 0 "$prefix-src-redis" chmod 755 /usr/local/bin/redis-cli
[[ -z "$(find "$backups" -mindepth 1 -maxdepth 1 -name '.partial-*')" ]] || die "a failed backup left a partial set"
[[ "$(find "$backups" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]] || die "a failed backup left files behind"
pass "failed backups leave no partial set"

# Pruning keeps the newest N complete sets.
sleep 1
bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups" >/dev/null
sleep 1
bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups" --keep 2 >/dev/null
mapfile -t sets < <(find "$backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[[ ${#sets[@]} -eq 2 && "${sets[0]}" > "$(basename "$set_dir")" ]] ||
  die "--keep 2 left: ${sets[*]}"
pass "--keep 2 pruned the oldest set"
printf 'All backup and restore tests passed.\n'
