#!/usr/bin/env bash
#
# Shared helpers for backup-data.sh, restore-data.sh and test-data-restore.sh
# (Issue #40).
#
# Every client tool runs inside the data containers through `kubectl exec` or
# `docker exec`. The in-container commands read POSTGRES_USER, POSTGRES_DB,
# POSTGRES_PASSWORD and REDIS_PASSWORD from the container's own environment,
# so no credential passes through this shell, its arguments, or its output.
# The commands are single-quoted on purpose: they expand inside the container.
# The constants and DATA_* variables are used by the scripts that source this.
# shellcheck disable=SC2016,SC2034

DATA_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly DATA_REPO_ROOT
readonly DATA_VALUES_FILE="$DATA_REPO_ROOT/charts/minishop/values.yaml"
readonly DATA_BACKUP_FORMAT=minishop-data-backup/1
readonly DATA_PG_FILE=postgresql.dump
readonly DATA_REDIS_FILE=redis.rdb
readonly DATA_MANIFEST_FILE=manifest.txt
readonly DATA_SUMS_FILE=SHA256SUMS
# Complete backup sets are directories named by their UTC start time.
readonly DATA_STAMP_PATTERN='^[0-9]{8}T[0-9]{6}Z$'

# In-container preambles. They only export variables the client tools read.
readonly DATA_PG_ENV='export PGPASSWORD="$POSTGRES_PASSWORD" PGUSER="$POSTGRES_USER" PGDATABASE="$POSTGRES_DB";'
readonly DATA_REDIS_ENV='export REDISCLI_AUTH="$REDIS_PASSWORD";'

# Target selection. kube targets name pods in a namespace; docker targets name
# containers. Callers set these from their command-line options.
DATA_TARGET=kube
DATA_KUBECONFIG="$DATA_REPO_ROOT/.kube/config"
DATA_CONTEXT=""
DATA_NAMESPACE=data
DATA_PG_POD=minishop-postgresql-0
DATA_REDIS_POD=minishop-redis-0
DATA_PG_CONTAINER=""
DATA_REDIS_CONTAINER=""

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

data_require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done
}

data_target_label() {
  case "$DATA_TARGET" in
    kube) printf 'kube context=%s namespace=%s pods=%s,%s' \
      "$DATA_CONTEXT" "$DATA_NAMESPACE" "$DATA_PG_POD" "$DATA_REDIS_POD" ;;
    docker) printf 'docker containers=%s,%s' "$DATA_PG_CONTAINER" "$DATA_REDIS_CONTAINER" ;;
  esac
}

data_kubectl() {
  kubectl --kubeconfig "$DATA_KUBECONFIG" --context "$DATA_CONTEXT" "$@"
}

# data_exec postgresql|redis CMD... runs CMD in that component's container,
# passing this shell's stdin through.
data_exec() {
  local component=$1
  shift
  case "$DATA_TARGET:$component" in
    kube:postgresql)
      data_kubectl -n "$DATA_NAMESPACE" exec -i "$DATA_PG_POD" -c postgresql -- "$@" ;;
    kube:redis)
      data_kubectl -n "$DATA_NAMESPACE" exec -i "$DATA_REDIS_POD" -c redis -- "$@" ;;
    docker:postgresql) docker exec -i "$DATA_PG_CONTAINER" "$@" ;;
    docker:redis) docker exec -i "$DATA_REDIS_CONTAINER" "$@" ;;
    *) die "unknown target or component: $DATA_TARGET:$component" ;;
  esac
}

# Fail before any data moves if a container is missing or not ready.
data_require_component() {
  local component=$1 ready
  case "$DATA_TARGET" in
    kube)
      local pod=$DATA_PG_POD
      [[ "$component" == redis ]] && pod=$DATA_REDIS_POD
      ready=$(data_kubectl -n "$DATA_NAMESPACE" get pod "$pod" \
        -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}') ||
        die "could not read pod $DATA_NAMESPACE/$pod in context $DATA_CONTEXT"
      [[ "$ready" == True ]] || die "pod $DATA_NAMESPACE/$pod is not Ready"
      ;;
    docker)
      local container=$DATA_PG_CONTAINER
      [[ "$component" == redis ]] && container=$DATA_REDIS_CONTAINER
      [[ -n "$container" ]] || die "no docker container named for $component"
      ready=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null) ||
        die "docker container $container does not exist"
      [[ "$ready" == true ]] || die "docker container $container is not running"
      ;;
  esac
}

# Image actually running the component, for the backup manifest.
data_running_image() {
  local component=$1
  case "$DATA_TARGET" in
    kube)
      local pod=$DATA_PG_POD
      [[ "$component" == redis ]] && pod=$DATA_REDIS_POD
      data_kubectl -n "$DATA_NAMESPACE" get pod "$pod" -o \
        "jsonpath={.status.containerStatuses[?(@.name==\"$component\")].imageID}"
      ;;
    docker)
      local container=$DATA_PG_CONTAINER
      [[ "$component" == redis ]] && container=$DATA_REDIS_CONTAINER
      docker inspect -f '{{.Config.Image}}' "$container"
      ;;
  esac
}

# Pinned image reference (repository@digest) from the chart values, so local
# verification uses exactly the client tools the cluster runs.
data_chart_image() {
  awk -v want="$1" '
    /^images:/ { in_images = 1; next }
    in_images && /^[^ #]/ { in_images = 0 }
    in_images && /^  [a-z]+:/ { key = $1; sub(/:$/, "", key); next }
    in_images && key == want && $1 == "repository:" { repo = $2 }
    in_images && key == want && $1 == "digest:" { digest = $2 }
    END {
      if (repo == "" || digest !~ /^sha256:[0-9a-f]+$/) exit 1
      print repo "@" digest
    }' "$DATA_VALUES_FILE"
}

# Run a client tool from a pinned image against a backup directory mounted
# read-only, with no network, no capabilities and the caller's own uid.
data_local_tool() {
  local image=$1 dir=$2
  shift 2
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user "$(id -u):$(id -g)" \
    --volume "$dir:/backup:ro" --entrypoint "" "$image" "$@"
}

# Every user table as "schema.table count md5" lines, sorted. The md5 covers
# the text form of all rows in a fixed order, so equal digests mean equal
# contents on the same PostgreSQL version and settings. Only names, counts and
# digests leave the container, never row data. string_agg holds a whole table
# in memory, which suits this learning-scale data set.
data_pg_table_stats() {
  data_exec postgresql sh -ec "$DATA_PG_ENV"' exec psql -X -At -v ON_ERROR_STOP=1' <<'SQL'
SELECT format('%I.%I', table_schema, table_name) || ' ' || s.c || ' ' || s.d
FROM information_schema.tables,
  LATERAL (
    SELECT (xpath('/row/c/text()', r))[1]::text AS c,
           (xpath('/row/d/text()', r))[1]::text AS d
    FROM query_to_xml(
      format('SELECT count(*) AS c, md5(coalesce(string_agg(t::text, chr(10) ORDER BY t::text), %L)) AS d FROM %I.%I t',
             '', table_schema, table_name),
      false, true, '') AS r
  ) AS s
WHERE table_type = 'BASE TABLE'
  AND table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1;
SQL
}

# "schema.table=count" or "schema.table=md5" lines from data_pg_table_stats.
data_pg_counts() { awk '{ print $1 "=" $2 }' <<<"$1"; }
data_pg_digests() { awk '{ print $1 "=" $3 }' <<<"$1"; }

data_pg_server_version() {
  data_exec postgresql sh -ec "$DATA_PG_ENV"' exec psql -X -At -v ON_ERROR_STOP=1 -c "SHOW server_version"' </dev/null
}

# Key count per logical database as "db0=100" lines, from INFO keyspace.
data_redis_keyspace() {
  local info
  info=$(data_exec redis sh -ec "$DATA_REDIS_ENV"' exec redis-cli INFO keyspace' </dev/null) ||
    return 1
  awk -F'[:,=]' '/^db[0-9]+:keys=/ { print $1 "=" $3 }' <<<"${info//$'\r'/}"
}

# sha256 of the sorted key names in each logical database as "db0=<sha>"
# lines. It proves the same key set without printing a key; value integrity
# comes from the RDB's own CRC64, checked by redis-check-rdb.
data_redis_keyset_digests() {
  data_exec redis sh -ec "$DATA_REDIS_ENV"'
    for db in $(redis-cli INFO keyspace | tr -d "\r" | sed -n "s/^db\([0-9]*\):.*/\1/p"); do
      printf "db%s=%s\n" "$db" "$(redis-cli -n "$db" --scan | LC_ALL=C sort | sha256sum | cut -d" " -f1)"
    done' </dev/null
}

data_redis_version() {
  data_exec redis sh -ec "$DATA_REDIS_ENV"' exec redis-cli INFO server' </dev/null |
    tr -d '\r' | awk -F: '$1 == "redis_version" { print $2 }'
}

# Sum the values of "name=count" lines.
data_sum_counts() {
  awk -F= '{ total += $NF } END { print total + 0 }' <<<"$1"
}

# Refuse a backup location inside the repository: backups hold real data.
data_require_outside_repo() {
  local resolved
  resolved=$(realpath -m -- "$1")
  case "$resolved/" in
    "$DATA_REPO_ROOT"/*) die "$1 is inside the repository; backups hold data and must live outside it" ;;
  esac
}
