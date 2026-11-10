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
# A target-only table with a foreign key to a restored table blocks --clean;
# the single transaction must roll back and leave the data as it was.
psql_in "$prefix-dst-pg" <<<"CREATE TABLE extra_ref (item integer REFERENCES marketitems (id))"
expect_failure "restore rolls back when a target-only table references a restored table" 'pg_restore failed' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" "${target[@]}" --only postgresql
[[ "$(psql_in "$prefix-dst-pg" <<<"SELECT count(*) FROM marketitems")" == 100 ]] ||
  die "the failed restore changed marketitems"
psql_in "$prefix-dst-pg" <<<"DROP TABLE extra_ref"

# Guards. Every kubeconfig here points at unreachable loopback ports, and the
# "live" kubeconfig is a fake one, so a broken guard still reaches no cluster.
fake_live="$scratch/live-kubeconfig"
cat >"$fake_live" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: kind-learn
    cluster: { server: "https://127.0.0.1:2" }
contexts:
  - name: kind-learn
    context: { cluster: kind-learn, user: nobody }
users:
  - name: nobody
    user: {}
YAML
fake_kubeconfig="$scratch/kubeconfig"
cat >"$fake_kubeconfig" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: kind-learn
    cluster: { server: "https://127.0.0.1:1" }
  - name: renamed
    cluster: { server: "https://127.0.0.1:2" }
contexts:
  - name: kind-learn
    context: { cluster: kind-learn, user: nobody }
  - name: alias
    context: { cluster: kind-learn, user: nobody }
  - name: same-server
    context: { cluster: renamed, user: nobody }
users:
  - name: nobody
    user: {}
YAML
export MINISHOP_LIVE_KUBECONFIG="$fake_live"
expect_failure "restore refuses kind-learn without --allow-kind-learn" 'refusing to restore into the live cluster' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" --kubeconfig "$fake_kubeconfig" --context kind-learn
expect_failure "restore refuses a context that points at the kind-learn cluster" 'refusing to restore into the live cluster' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" --kubeconfig "$fake_kubeconfig" --context alias
expect_failure "restore refuses a renamed context with the kind-learn API server URL" 'uses the kind-learn API server' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" --kubeconfig "$fake_kubeconfig" --context same-server
# A target that passes the name and URL checks but has kind-learn's node.
# A stub kubectl answers the kubeconfig reads and the node lookup, and fails
# on any other call.
mkdir -m 700 "$scratch/bin"
cat >"$scratch/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"--kubeconfig $MINISHOP_LIVE_KUBECONFIG config view"*) echo https://127.0.0.1:4 ;;
  *"config view"*".contexts"*) echo throwaway ;;
  *"config view"*".clusters"*) echo https://127.0.0.1:3 ;;
  *"get node learn-control-plane"*) echo node/learn-control-plane ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 1 ;;
esac
STUB
chmod 700 "$scratch/bin/kubectl"
expect_failure "restore refuses a target that has the node learn-control-plane" 'the target has node learn-control-plane' \
  env PATH="$scratch/bin:$PATH" bash "$SCRIPT_DIR/restore-data.sh" --from "$set_dir" \
  --kubeconfig "$fake_kubeconfig" --context throwaway
unset MINISHOP_LIVE_KUBECONFIG
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

# A dump cut short keeps its table of contents, so pg_restore --list passes;
# the full read must catch it. /usr/local/bin is first on the image's PATH.
# shellcheck disable=SC2016
docker exec -u 0 "$prefix-src-pg" sh -ec 'printf "%s\n" "#!/bin/sh" \
  "/usr/lib/postgresql/\$PG_MAJOR/bin/pg_dump \"\$@\" | head -c -200" >/usr/local/bin/pg_dump
  chmod 755 /usr/local/bin/pg_dump'
expect_failure "backup rejects a truncated dump that pg_restore --list accepts" 'could not read the whole dump' \
  bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups"
docker exec -u 0 "$prefix-src-pg" rm -f /usr/local/bin/pg_dump
[[ -z "$(find "$backups" -mindepth 1 -maxdepth 1 -name '.partial-*')" ]] || die "a truncated dump left a partial set"

# A clock that stepped back must not create a set older than the newest one.
future="$backups/29991231T235959Z"
mkdir -m 700 "$future"
: >"$future/$DATA_SUMS_FILE"
expect_failure "backup refuses a stamp older than the newest set" 'not after the newest set' \
  bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups" --keep 1
[[ -f "$set_dir/$DATA_SUMS_FILE" ]] || die "the refused backup pruned an existing set"
rm -rf -- "$future"

# Pruning keeps the newest N complete sets.
sleep 1
bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups" >/dev/null
sleep 1
bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups" --keep 2 >/dev/null
mapfile -t sets < <(find "$backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[[ ${#sets[@]} -eq 2 && "${sets[0]}" > "$(basename "$set_dir")" ]] ||
  die "--keep 2 left: ${sets[*]}"
pass "--keep 2 pruned the oldest set"

# Keys with a TTL: counts may only fall, and the keys without a TTL must match.
redis_in "$prefix-src-redis" -n 1 SET session:1 x EX 3600 >/dev/null
sleep 1
bash "$SCRIPT_DIR/backup-data.sh" "${source[@]}" --backup-dir "$backups" >/dev/null
ttl_set=$(find "$backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1)
grep -qx 'redis_expires=1' "$backups/$ttl_set/$DATA_MANIFEST_FILE" || die "the TTL key was not recorded"
ttl_out=$(bash "$SCRIPT_DIR/restore-data.sh" --from "$backups/$ttl_set" "${target[@]}" --only redis)
grep -q 'keys without a TTL match' <<<"$ttl_out" || die "the TTL restore did not take the TTL path"
pass "a set with TTL keys restores and keeps every key without a TTL"

# The temporary port. A password-protected server already on 16379 must make
# the restore stop, without the probe sending it the target's password.
# shellcheck disable=SC2016
docker exec "$prefix-dst-redis" sh -ec 'umask 077
  od -An -tx1 -N16 /dev/urandom | tr -d " \n" >/tmp/occupant-pw
  printf "requirepass %s\n" "$(cat /tmp/occupant-pw)" | redis-server - --port 16379 \
    --bind 127.0.0.1 --save "" --appendonly no --daemonize yes --logfile /tmp/occupant.log'
# shellcheck disable=SC2016
wait_until "the occupant on 16379" docker exec "$prefix-dst-redis" sh -c \
  'REDISCLI_AUTH="$(cat /tmp/occupant-pw)" redis-cli -p 16379 PING | grep -q PONG'
expect_failure "restore stops when the temporary port is taken" 'port 16379 is in use' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$backups/$ttl_set" "${target[@]}" --only redis
# shellcheck disable=SC2016
denied=$(docker exec "$prefix-dst-redis" sh -c \
  'REDISCLI_AUTH="$(cat /tmp/occupant-pw)" redis-cli -p 16379 INFO stats | tr -d "\r" | sed -n "s/^acl_access_denied_auth://p"')
[[ "$denied" == 0 ]] || die "the port probe tried to authenticate to the occupant ($denied denied)"
pass "the port probe sends no password to a server on the port"
bash "$SCRIPT_DIR/restore-data.sh" --from "$backups/$ttl_set" "${target[@]}" --only redis --restore-port 16380 >/dev/null
pass "--restore-port moves the temporary server"
# shellcheck disable=SC2016
docker exec "$prefix-dst-redis" sh -c \
  'REDISCLI_AUTH="$(cat /tmp/occupant-pw)" redis-cli -p 16379 SHUTDOWN NOSAVE >/dev/null 2>&1 || true; rm -f /tmp/occupant-pw'
# A temporary server that cannot bind must fail at once, not after the sync
# timeout. A wrapper first on the image's PATH (/usr/local/sbin) appends a bind
# to an address the container does not have (TEST-NET-1); the last --bind wins.
# The running target server is not affected.
# shellcheck disable=SC2016
docker exec -u 0 "$prefix-dst-redis" sh -ec 'printf "%s\n" "#!/bin/sh" \
  "exec /usr/local/bin/redis-server \"\$@\" --bind 192.0.2.1" >/usr/local/sbin/redis-server
  chmod 755 /usr/local/sbin/redis-server'
started_at=$SECONDS
expect_failure "restore fails fast when the temporary server cannot listen" 'could not listen' \
  bash "$SCRIPT_DIR/restore-data.sh" --from "$backups/$ttl_set" "${target[@]}" --only redis
docker exec -u 0 "$prefix-dst-redis" rm -f /usr/local/sbin/redis-server
[[ $((SECONDS - started_at)) -lt 30 ]] || die "the bind failure took $((SECONDS - started_at)) s to report"
[[ -z "$(docker exec "$prefix-dst-redis" ls -A /data/.minishop-restore 2>/dev/null)" ]] ||
  die "the failed restore left /data/.minishop-restore"
[[ "$(redis_in "$prefix-dst-redis" INFO replication | tr -d '\r' | grep '^role:')" == role:master ]] ||
  die "the target is not a master after the failed restore"
printf 'All backup and restore tests passed.\n'
