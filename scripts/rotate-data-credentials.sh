#!/usr/bin/env bash
#
# Rotate the MiniShop data-stack passwords (Issue #40, part 3): the PostgreSQL
# application role and the Redis requirepass, together with both Secrets that
# hold them, then restart the workloads that read them and verify the result.
#
# What it changes, in this order (each step is checked before the next):
#   1. ALTER ROLE <role> PASSWORD inside the PostgreSQL container, over its
#      trusted local socket, with statement logging off for that session.
#   2. Secret <namespace>/minishop-data-credentials, then
#      <app-namespace>/minishop-app-credentials, patched from stdin and checked
#      by comparing sha256 hashes. Each patch carries the resourceVersion read
#      during the checks, so a concurrent change fails it with 409 Conflict
#      (and triggers the rollback), and it removes the
#      kubectl.kubernetes.io/last-applied-configuration annotation, which
#      would otherwise keep a copy of the old value.
#   3. A rolling restart of every Deployment, StatefulSet or DaemonSet whose
#      pod template reads a rotated key from those Secrets (Redis first, since
#      Redis reads requirepass from its environment at start; then the
#      backend), waiting for each to be ready. The PostgreSQL StatefulSet is
#      not restarted: its POSTGRES_PASSWORD is read only by initdb on an empty
#      volume, and its probes use the trusted local socket.
#   4. Verification: the new passwords log in and the old ones are rejected,
#      the Redis keys without a TTL are unchanged, and every new backend Pod
#      answers /ready, /items and /items/<index>/reviews.
# Client window: from ALTER ROLE (or the Redis restart, when only Redis
# rotates) until the backend rollout completes, old backend Pods cannot open
# new connections; once Redis restarts they fail readiness and go NotReady.
# The script measures and prints this window (owner decision: a window of
# authentication failures is accepted; no dual roles).
#
# With --apply, a lock on <state-dir>/.lock allows one rotation or recovery at
# a time from that state directory. The old values must be 16 or more
# characters of [A-Za-z0-9+/=]; anything else is refused ("rotate manually").
#
# Passwords are 32 random bytes as 64 hex characters, generated here and kept
# only in mode 600 files in a private work directory. They are never printed,
# passed as a command argument, or written to shell history: they reach psql,
# redis-cli and kubectl through stdin. Error output from those calls is shown
# with long tokens redacted.
#
# If any step fails, the script rolls back automatically: both Secrets and the
# role go back to the old passwords and the restarted workloads are restarted
# again. If the rollback also fails, it prints the state of each part and
# keeps the work directory, from which --recover finishes the job.
#
# Take a backup first (bash scripts/backup-data.sh --context NAME). The script
# refuses to run unless a backup set of the same target newer than
# --backup-max-age hours exists, or --skip-backup-check is given.
#
# Usage:
#   bash scripts/rotate-data-credentials.sh --context NAME [options]
#       Dry run (default): run every check, print the plan, change nothing.
#   bash scripts/rotate-data-credentials.sh --context NAME --apply [options]
#       Rotate.
#   bash scripts/rotate-data-credentials.sh --context NAME --apply \
#       --recover DIR --to old|new [options]
#       After a failed rollback: set the role, both Secrets and the readers to
#       the old or the new passwords kept in DIR, then delete DIR. DIR records
#       which passwords were rotated; a different --only is refused.
#
#   --context NAME            kube context (required; there is no default)
#   --kubeconfig PATH         kubeconfig (default ./.kube/config)
#   --apply                   make the change (default is a dry run)
#   --only postgresql|redis   rotate one password (default both)
#   --namespace NAME          data namespace (default data)
#   --app-namespace NAME      application namespace (default webapp)
#   --data-secret NAME        Secret in the data namespace
#                             (default minishop-data-credentials)
#   --app-secret NAME         Secret in the application namespace
#                             (default minishop-app-credentials)
#   --pg-pod NAME             PostgreSQL pod (default minishop-postgresql-0)
#   --redis-pod NAME          Redis pod (default minishop-redis-0)
#   --pg-role NAME            PostgreSQL role the application uses
#                             (default minishop)
#   --backend NAME            backend Deployment to verify (default
#                             minishop-backend)
#   --backup-dir DIR          backup root to check (default
#                             $MINISHOP_BACKUP_DIR, else ~/minishop-backups)
#   --backup-max-age HOURS    newest acceptable backup age (default 24)
#   --skip-backup-check       rotate without a recent backup
#   --state-dir DIR           parent of the private work directory (default
#                             $MINISHOP_ROTATION_DIR, else
#                             ~/.local/state/minishop-rotation)
#   --timeout SECONDS         limit for each rollout (default 300)

# DATA_* variables set here are read by data-lib.sh, and in-container commands
# are single-quoted on purpose: they expand inside the container.
# shellcheck disable=SC2016,SC2034

set -euo pipefail
# Tracing would print commands that handle password files; `bash -x` must not
# turn it on. Secret values are also streamed, never held in a variable.
set +x

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=data-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/data-lib.sh"

readonly PG_KEY=postgres-password
readonly REDIS_KEY=redis-password
readonly WORK_FORMAT=minishop-rotation/1
readonly ROLE_PATTERN='^[a-z_][a-z0-9_]{0,62}$'
# Old values are pasted into an SQL literal on rollback and must be caught by
# redact(), so only base64-alphabet values of 16 or more characters are
# accepted; anything else is rotated by hand.
readonly OLD_VALUE_PATTERN='[A-Za-z0-9+/=]{16,}'
readonly LAST_APPLIED=kubectl.kubernetes.io/last-applied-configuration

# refs_jsonpath POD-SPEC-PATH [EXTRA] prints a jsonpath that lists, per item,
# "name|EXTRA|secret:key ..." for every Secret reference in the pod spec at
# POD-SPEC-PATH: env secretKeyRef of containers and initContainers as
# "secret:key", and envFrom, secret volumes and projected secret sources as
# "secret:*". It reads workloads only, never a Secret.
refs_jsonpath() {
  local p=$1 extra=${2:-} c
  printf '{range .items[*]}{.metadata.name}|%s|' "$extra"
  for c in containers initContainers; do
    printf '{range %s.%s[*].env[*]}{.valueFrom.secretKeyRef.name}:{.valueFrom.secretKeyRef.key} {end}' "$p" "$c"
    printf '{range %s.%s[*].envFrom[*]}{.secretRef.name}:* {end}' "$p" "$c"
  done
  printf '{range %s.volumes[*]}{.secret.secretName}:* {end}' "$p"
  printf '{range %s.volumes[*].projected.sources[*]}{.secret.name}:* {end}' "$p"
  printf '{"\\n"}{end}'
}

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

DATA_CONTEXT=""
apply=false
only=""
app_namespace=webapp
data_secret=minishop-data-credentials
app_secret=minishop-app-credentials
pg_role=minishop
backend=minishop-backend
backup_root=${MINISHOP_BACKUP_DIR:-$HOME/minishop-backups}
backup_max_age=24
skip_backup_check=false
state_root=${MINISHOP_ROTATION_DIR:-$HOME/.local/state/minishop-rotation}
timeout=300
recover_dir=""
recover_to=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) DATA_CONTEXT=${2:?--context needs a value}; shift 2 ;;
    --kubeconfig) DATA_KUBECONFIG=${2:?--kubeconfig needs a value}; shift 2 ;;
    --apply) apply=true; shift ;;
    --only) only=${2:?--only needs a value}; shift 2 ;;
    --namespace) DATA_NAMESPACE=${2:?--namespace needs a value}; shift 2 ;;
    --app-namespace) app_namespace=${2:?--app-namespace needs a value}; shift 2 ;;
    --data-secret) data_secret=${2:?--data-secret needs a value}; shift 2 ;;
    --app-secret) app_secret=${2:?--app-secret needs a value}; shift 2 ;;
    --pg-pod) DATA_PG_POD=${2:?--pg-pod needs a value}; shift 2 ;;
    --redis-pod) DATA_REDIS_POD=${2:?--redis-pod needs a value}; shift 2 ;;
    --pg-role) pg_role=${2:?--pg-role needs a value}; shift 2 ;;
    --backend) backend=${2:?--backend needs a value}; shift 2 ;;
    --backup-dir) backup_root=${2:?--backup-dir needs a value}; shift 2 ;;
    --backup-max-age) backup_max_age=${2:?--backup-max-age needs a value}; shift 2 ;;
    --skip-backup-check) skip_backup_check=true; shift ;;
    --state-dir) state_root=${2:?--state-dir needs a value}; shift 2 ;;
    --timeout) timeout=${2:?--timeout needs a value}; shift 2 ;;
    --recover) recover_dir=${2:?--recover needs a value}; shift 2 ;;
    --to) recover_to=${2:?--to needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$DATA_CONTEXT" ]] || { usage; die "name the cluster with --context NAME; there is no default"; }
case "$only" in
  '') components=(postgresql redis) ;;
  postgresql | redis) components=("$only") ;;
  *) die "--only must be postgresql or redis" ;;
esac
[[ "$pg_role" =~ $ROLE_PATTERN ]] || die "--pg-role must be a plain lower-case identifier"
[[ "$backup_max_age" =~ ^[1-9][0-9]*$ ]] || die "--backup-max-age must be a positive integer"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"
[[ "$DATA_NAMESPACE" != "$app_namespace" ]] || die "--namespace and --app-namespace must differ"
if [[ -n "$recover_dir" || -n "$recover_to" ]]; then
  [[ -n "$recover_dir" ]] || die "--to needs --recover DIR"
  [[ "$recover_to" == old || "$recover_to" == new ]] || die "--recover needs --to old or --to new"
fi

umask 077
data_require_commands kubectl base64 sha256sum od tr sed awk date mktemp stat realpath cmp flock

private_dir_ok() { # dir: ours and mode 700
  [[ "$(stat -c %u -- "$1")" == "$(id -u)" && "$(stat -c %a -- "$1")" == 700 ]]
}

# --recover: the work directory decides which passwords are involved.
recover_work=""
if [[ -n "$recover_dir" ]]; then
  [[ -d "$recover_dir" ]] || die "$recover_dir is not a directory"
  recover_work=$(realpath -- "$recover_dir")
  private_dir_ok "$recover_work" || die "$recover_work must be yours and mode 700"
  grep -qx "format=$WORK_FORMAT" "$recover_work/rotation.info" 2>/dev/null ||
    die "$recover_work is not a rotation work directory"
  grep -qxF "context=$DATA_CONTEXT" "$recover_work/rotation.info" ||
    die "$recover_work belongs to another context ($(sed -n 's/^context=//p' "$recover_work/rotation.info"))"
  recorded=()
  read -r -a recorded_keys <<<"$(sed -n 's/^keys=//p' "$recover_work/rotation.info")"
  for key in "${recorded_keys[@]}"; do
    case "$key" in
      postgres-password) recorded+=(postgresql) ;;
      redis-password) recorded+=(redis) ;;
      *) die "$recover_work/rotation.info names an unknown key $key" ;;
    esac
  done
  [[ ${#recorded[@]} -gt 0 ]] || die "$recover_work/rotation.info names no keys"
  if [[ -n "$only" && "${recorded[*]}" != "$only" ]]; then
    die "--only $only conflicts with $recover_work, which rotated: ${recorded[*]}"
  fi
  components=("${recorded[@]}")
fi

has_component() {
  local c
  for c in "${components[@]}"; do [[ "$c" == "$1" ]] && return 0; done
  return 1
}
key_of() { [[ "$1" == postgresql ]] && echo "$PG_KEY" || echo "$REDIS_KEY"; }
keys=()
for component in "${components[@]}"; do keys+=("$(key_of "$component")"); done

# --- Output helpers: nothing here ever prints a password --------------------
# Long base64 or hex runs in error output are replaced, so an error that
# echoes a request or a statement cannot show a password. Hyphenated
# Kubernetes names survive, since a hyphen ends a run.
redact() { sed -E 's/[A-Za-z0-9+\/=]{16,}/<redacted>/g'; }
step() { printf '==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }

# kube_quiet DESCRIPTION KUBECTL-ARGS... runs kubectl with stdout discarded and
# shows its stderr, redacted, only on failure.
kube_quiet() {
  local description=$1 err
  shift
  if err=$(data_kubectl "$@" 2>&1 >/dev/null); then
    return 0
  fi
  printf '    %s failed: %s\n' "$description" "$(head -n 3 <<<"$err" | redact | tr '\n' ' ')" >&2
  return 1
}

# --- Secrets ------------------------------------------------------------------
# kubectl prints the whole object on a jsonpath error, so stderr of a Secret
# read is always discarded. Values are streamed from kubectl through base64 -d
# into a mode 600 file or into sha256sum; no shell variable holds one.

# secret_to_file NAMESPACE SECRET KEY FILE: 1 if the Secret cannot be read,
# 2 if the key is absent or empty.
secret_to_file() {
  data_kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null |
    base64 -d >"$4" 2>/dev/null || return 1
  [[ -s "$4" ]] || return 2
}

# sha256 of a Secret value, "missing" when the key is absent or empty, or
# "unreadable" when the Secret cannot be read.
secret_sha() { # namespace secret key
  local probe="$work/.probe" status=0
  secret_to_file "$1" "$2" "$3" "$probe" || status=$?
  case "$status" in
    0) file_sha "$probe" ;;
    1) echo unreadable ;;
    *) echo missing ;;
  esac
  rm -f -- "$probe"
}

file_sha() { sha256sum <"$1" | cut -c1-64; }

# resourceVersion of a Secret (metadata only; stderr discarded all the same).
secret_version() { # namespace secret
  data_kubectl -n "$1" get secret "$2" -o 'jsonpath={.metadata.resourceVersion}' 2>/dev/null
}

# patch_secret NAMESPACE SECRET VERSION DIR KEY... sets each KEY to the content
# of DIR/KEY. The patch goes through stdin, never the command line. A
# non-empty VERSION makes the API server refuse the patch (409 Conflict) if
# the Secret changed since it was read. The patch also removes the
# last-applied-configuration annotation that `kubectl apply` left, which
# would otherwise keep a copy of the replaced value.
patch_secret() {
  local ns=$1 name=$2 version=$3 dir=$4 sep="" key
  shift 4
  {
    printf '{"metadata":{'
    [[ -z "$version" ]] || printf '"resourceVersion":"%s",' "$version"
    printf '"annotations":{"%s":null}},"data":{' "$LAST_APPLIED"
    for key in "$@"; do
      printf '%s"%s":"' "$sep" "$key"
      base64 -w0 <"$dir/$key"
      printf '"'
      sep=,
    done
    printf '}}'
  } | kube_quiet "patch of Secret $ns/$name" -n "$ns" patch secret "$name" \
    --type merge --patch-file /dev/stdin
}

# secret_holds NAMESPACE SECRET DIR KEY...: every KEY equals DIR/KEY by hash.
secret_holds() {
  local ns=$1 name=$2 dir=$3 key
  shift 3
  for key in "$@"; do
    [[ "$(secret_sha "$ns" "$name" "$key")" == "$(file_sha "$dir/$key")" ]] || return 1
  done
}

# --- PostgreSQL -----------------------------------------------------------------
pg_psql() { # extra psql arguments; SQL on stdin
  data_exec postgresql sh -ec "$DATA_PG_ENV"' exec psql -X -q -At -v ON_ERROR_STOP=1 -v VERBOSITY=terse "$@"' psql "$@"
}

# ALTER ROLE over the trusted local socket, so it works whatever password the
# role has now. Statement and error logging are off for this session (the
# role is a superuser), so the server log never receives the password.
pg_set_password() { # password file
  local err
  if err=$({
    printf "SET log_statement = 'none';\nSET log_min_error_statement = 'panic';\n"
    printf "SET log_min_duration_statement = -1;\nALTER ROLE \"%s\" PASSWORD '" "$pg_role"
    cat "$1"
    printf "';\n"
  } | pg_psql 2>&1 >/dev/null); then
    return 0
  fi
  printf '    ALTER ROLE failed: %s\n' "$(head -n 3 <<<"$err" | redact | tr '\n' ' ')" >&2
  return 1
}

# Log in over TCP to the pod IP, the path clients use (scram-sha-256), from
# inside the container; the password arrives on stdin. Prints ok, rejected,
# or error: <reason>.
pg_login() { # password file
  local out ip
  ip=$(data_kubectl -n "$DATA_NAMESPACE" get pod "$DATA_PG_POD" -o 'jsonpath={.status.podIP}' 2>/dev/null) || ip=""
  [[ -n "$ip" ]] || { echo "error: no pod IP for $DATA_PG_POD"; return 0; }
  if out=$({ cat "$1"; echo; } | data_exec postgresql sh -c '
      IFS= read -r PGPASSWORD || true
      export PGPASSWORD PGCONNECT_TIMEOUT=10
      exec psql -X -At -h "$1" -U "$2" -d "$POSTGRES_DB" -c "SELECT 1"' login "$ip" "$pg_role" 2>&1); then
    [[ "$out" == 1 ]] && echo ok || echo "error: unexpected psql output"
  elif grep -q 'password authentication failed' <<<"$out"; then
    echo rejected
  else
    echo "error: $(head -n 1 <<<"$out" | redact)"
  fi
}

# --- Redis --------------------------------------------------------------------------
redis_login() { # password file; prints ok, rejected, or error: <reason>
  local out
  out=$({ cat "$1"; echo; } | data_exec redis sh -c '
      IFS= read -r REDISCLI_AUTH || true
      export REDISCLI_AUTH
      exec redis-cli --no-auth-warning PING' 2>&1 | tr -d '\r') || true
  case "$out" in
    PONG) echo ok ;;
    *WRONGPASS* | *"invalid password"*) echo rejected ;;
    *) echo "error: $(head -n 1 <<<"$out" | redact)" ;;
  esac
}

login() { # component password-file
  case "$1" in
    postgresql) pg_login "$2" ;;
    redis) redis_login "$2" ;;
  esac
}

# --- Workloads ------------------------------------------------------------------------
owner_of_pod() { # pod -> statefulset/<name>
  local owner
  owner=$(data_kubectl -n "$DATA_NAMESPACE" get pod "$1" \
    -o 'jsonpath={.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}') || return 1
  [[ -n "$owner" ]] || return 1
  echo "statefulset/$owner"
}

# refs_hit REFS SECRET: REFS (from refs_jsonpath) read a rotated key of SECRET.
refs_hit() {
  local key
  [[ " $1 " == *" $2:* "* ]] && return 0
  for key in "${keys[@]}"; do
    [[ " $1 " == *" $2:$key "* ]] && return 0
  done
  return 1
}

secret_of_namespace() { [[ "$1" == "$app_namespace" ]] && echo "$app_secret" || echo "$data_secret"; }

# scan_refs KIND POD-SPEC-PATH [EXTRA] prints "namespace|name|extra|refs" for
# every KIND in both namespaces whose pod spec reads a rotated key from the
# Secret of its namespace.
scan_refs() {
  local kind=$1 path=$2 extra=${3:-} ns secret listing name more refs
  for ns in "$DATA_NAMESPACE" "$app_namespace"; do
    secret=$(secret_of_namespace "$ns")
    listing=$(data_kubectl -n "$ns" get "$kind" -o "jsonpath=$(refs_jsonpath "$path" "$extra")") || return 1
    while IFS='|' read -r name more refs; do
      [[ -n "$name" ]] || continue
      if refs_hit "$refs" "$secret"; then printf '%s|%s|%s\n' "$ns" "$name" "$more"; fi
    done <<<"$listing"
  done
}

# "namespace kind/name" for each workload that reads a rotated key from the
# Secret of its namespace.
list_readers() {
  local kind lines ns name
  for kind in deployment statefulset daemonset; do
    lines=$(scan_refs "$kind" .spec.template.spec) || return 1
    while IFS='|' read -r ns name _; do
      if [[ -n "$name" ]]; then printf '%s %s/%s\n' "$ns" "$kind" "$name"; fi
    done <<<"$lines"
  done
}

# Running Jobs (including those a CronJob started) that read either Secret
# would keep the old password; finished ones do not matter.
list_active_jobs() {
  local lines ns name active
  lines=$(scan_refs job .spec.template.spec '{.status.active}') || return 1
  while IFS='|' read -r ns name active; do
    if [[ -n "$name" && "${active:-0}" -gt 0 ]]; then printf '%s job/%s\n' "$ns" "$name"; fi
  done <<<"$lines"
}

# CronJobs that read either Secret need no restart: each run reads the
# Secret when its Pod starts. They are listed so the operator knows.
list_cronjobs() {
  local lines ns name
  lines=$(scan_refs cronjob .spec.jobTemplate.spec.template.spec) || return 1
  while IFS='|' read -r ns name _; do
    if [[ -n "$name" ]]; then printf '%s/cronjob/%s ' "$ns" "$name"; fi
  done <<<"$lines"
}

restart_workload() { # namespace kind/name
  kube_quiet "rollout restart of $1/$2" -n "$1" rollout restart "$2"
}

wait_workload() { # namespace kind/name
  local out
  if out=$(data_kubectl -n "$1" rollout status "$2" --timeout="${timeout}s" 2>&1); then
    ok "$1/$2 rolled out"
    return 0
  fi
  printf '    %s/%s did not become ready: %s\n' "$1" "$2" "$(tail -n 1 <<<"$out" | redact)" >&2
  return 1
}

# Probe each backend Pod that is not terminating, from inside the Pod: /ready,
# /items (PostgreSQL) and /items/<index>/reviews (Redis) must answer 200.
readonly ITEMS_PROBE='const http = require("http");
const get = path => new Promise((resolve, reject) => {
  const request = http.get({ host: "127.0.0.1", port: 3001, path, timeout: 10000 }, response => {
    let body = "";
    response.on("data", chunk => { body += chunk; });
    response.on("end", () => resolve({ status: response.statusCode, body }));
  });
  request.on("timeout", () => request.destroy(new Error("timeout on " + path)));
  request.on("error", reject);
});
(async () => {
  const ready = await get("/ready");
  if (ready.status !== 200) throw new Error("GET /ready answered HTTP " + ready.status + " " + ready.body);
  const items = await get("/items?q=");
  let rows;
  try { rows = JSON.parse(items.body); } catch (_) { rows = undefined; }
  if (items.status !== 200 || !Array.isArray(rows)) throw new Error("GET /items answered HTTP " + items.status);
  const index = rows.length > 0 && rows[0].data && rows[0].data.index !== undefined ? rows[0].data.index : 1;
  const reviews = await get("/items/" + encodeURIComponent(index) + "/reviews");
  if (reviews.status !== 200) throw new Error("GET /items/" + index + "/reviews answered HTTP " + reviews.status);
  console.log("/ready 200, /items 200 (" + rows.length + " items), /items/" + index + "/reviews 200");
})().catch(error => { console.error(error.message); process.exit(1); });'

check_backend() {
  local selector pods pod out failed=0
  # go-template on a Deployment, never a Secret.
  selector=$(data_kubectl -n "$app_namespace" get deployment "$backend" -o \
    'go-template={{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}') || return 1
  pods=$(data_kubectl -n "$app_namespace" get pods --selector "${selector%,}" -o \
    'jsonpath={range .items[*]}{.metadata.name},{.metadata.deletionTimestamp},{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
    awk -F, '$2 == "" && $3 == "True" { print $1 }') || return 1
  [[ -n "$pods" ]] || { printf '    no ready %s Pod\n' "$backend" >&2; return 1; }
  while IFS= read -r pod; do
    if out=$(data_kubectl -n "$app_namespace" exec "$pod" -- node -e "$ITEMS_PROBE" </dev/null 2>&1); then
      ok "$pod: $out"
    else
      printf '    %s: %s\n' "$pod" "$(tail -n 1 <<<"$out" | redact)" >&2
      failed=1
    fi
  done <<<"$pods"
  return "$failed"
}

# --- Target ---------------------------------------------------------------------------
data_kubectl config get-contexts "$DATA_CONTEXT" -o name >/dev/null 2>&1 ||
  die "context $DATA_CONTEXT is not in kubeconfig $DATA_KUBECONFIG"
mode="dry run"
[[ "$apply" == true ]] && mode=apply
[[ -n "$recover_dir" ]] && mode="$mode, recover to the $recover_to passwords"
printf 'Target: %s (%s)\n' "$(data_target_label)" "$mode"
printf 'Secrets: %s/%s and %s/%s, keys: %s\n' "$DATA_NAMESPACE" "$data_secret" \
  "$app_namespace" "$app_secret" "${keys[*]}"

# --- Work directory: private, outside the repository --------------------------------
work=""
keep_work=false
rotating=false
phase=""
st_role=old
st_data=old
st_app=old
restarted=()

on_exit() {
  local status=$?
  trap - EXIT
  # A second interrupt must not cut a rollback short.
  trap '' INT TERM HUP
  set +e
  if [[ "$rotating" == true ]]; then
    rollback
    status=1
  fi
  if [[ -n "$work" && -d "$work" && "$keep_work" != true ]]; then
    rm -rf -- "$work"
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

case "$(realpath -m -- "$state_root")/" in
  "$DATA_REPO_ROOT"/*) die "--state-dir $state_root is inside the repository" ;;
esac
# Only a directory created here is chmodded; an existing one must already be
# private.
if [[ ! -e "$state_root" ]]; then
  mkdir -p -- "$state_root"
  chmod 700 -- "$state_root"
fi
[[ -d "$state_root" ]] || die "$state_root is not a directory"
private_dir_ok "$state_root" ||
  die "$state_root must be yours and mode 700 (Windows drives under /mnt cannot enforce this)"

# One rotation or recovery at a time from this state directory. The lock is
# released when the script exits. A second operator elsewhere is caught by
# the resourceVersion in each Secret patch instead.
if [[ "$apply" == true ]]; then
  exec {lock_fd}>>"$state_root/.lock"
  flock -n "$lock_fd" ||
    die "another rotation or recovery holds $state_root/.lock; wait for it to finish"
fi

if [[ -n "$recover_dir" ]]; then
  work=$recover_work
  keep_work=true
else
  work=$(mktemp -d "$state_root/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  mkdir -m 700 -- "$work/old" "$work/new"
  printf 'format=%s\ncontext=%s\nkeys=%s\n' "$WORK_FORMAT" "$DATA_CONTEXT" "${keys[*]}" >"$work/rotation.info"
fi

# --- Checks (dry run and apply) ---------------------------------------------------------
step "Checks"
data_require_component postgresql
data_require_component redis
pg_sts=$(owner_of_pod "$DATA_PG_POD") || die "no StatefulSet owns $DATA_PG_POD"
redis_sts=$(owner_of_pod "$DATA_REDIS_POD") || die "no StatefulSet owns $DATA_REDIS_POD"
data_kubectl -n "$app_namespace" get deployment "$backend" -o name >/dev/null 2>&1 ||
  die "Deployment $app_namespace/$backend does not exist"

role_login=$(printf "SELECT rolcanlogin FROM pg_roles WHERE rolname = :'role';\n" |
  pg_psql -v role="$pg_role") || die "could not query PostgreSQL roles"
[[ "$role_login" == t ]] || die "PostgreSQL role $pg_role does not exist or cannot log in"
backend_user=$(data_kubectl -n "$app_namespace" get deployment "$backend" -o \
  'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="POSTGRES_USER")].value}')
[[ "$backend_user" == "$pg_role" ]] ||
  die "$backend connects as PostgreSQL user '${backend_user:-unset}', not --pg-role $pg_role"
ok "role $pg_role exists and is the role $backend uses"

# resourceVersions are read before the values, so a change after this point,
# even one that lands before the values are read, makes the forward patches
# fail with 409 Conflict instead of overwriting it.
data_version=$(secret_version "$DATA_NAMESPACE" "$data_secret") || data_version=""
app_version=$(secret_version "$app_namespace" "$app_secret") || app_version=""
[[ -n "$data_version" && -n "$app_version" ]] ||
  die "cannot read the resourceVersion of both Secrets (missing, or no permission)"

# value_ok FILE: one line of base64-alphabet characters, 16 or more.
value_ok() {
  [[ "$(wc -l <"$1")" -eq 0 ]] && grep -Eqx "$OLD_VALUE_PATTERN" "$1"
}

for secret_ref in "$DATA_NAMESPACE/$data_secret" "$app_namespace/$app_secret"; do
  for key in "${keys[@]}"; do
    case "$(secret_sha "${secret_ref%%/*}" "${secret_ref#*/}" "$key")" in
      unreadable) die "cannot read Secret $secret_ref (missing, or no permission)" ;;
      missing) die "Secret $secret_ref has no key $key" ;;
    esac
  done
done

if [[ -z "$recover_dir" ]]; then
  for component in "${components[@]}"; do
    key=$(key_of "$component")
    secret_to_file "$DATA_NAMESPACE" "$data_secret" "$key" "$work/old/$key" ||
      die "cannot read $key from $DATA_NAMESPACE/$data_secret"
    value_ok "$work/old/$key" ||
      die "the current $key is not 16 or more characters of [A-Za-z0-9+/=], so a rollback could not restore it safely; rotate manually"
    secret_holds "$app_namespace" "$app_secret" "$work/old" "$key" ||
      die "$key differs between $DATA_NAMESPACE/$data_secret and $app_namespace/$app_secret; make them consistent before rotating"
    result=$(login "$component" "$work/old/$key")
    [[ "$result" == ok ]] ||
      die "the current $component password in the Secrets does not log in ($result); fix that before rotating"
  done
  ok "both Secrets hold the same ${keys[*]}, and they log in"
else
  for key in "${keys[@]}"; do
    [[ -s "$work/$recover_to/$key" ]] || die "$work/$recover_to has no $key"
    value_ok "$work/$recover_to/$key" || die "$work/$recover_to/$key is not a value this script wrote"
  done
fi

readers=$(list_readers) || die "could not list the workloads that read the Secrets"
plan=()
# Redis first: the backend's new Pods only become ready once Redis accepts
# the new password.
if has_component redis; then
  grep -qxF "$DATA_NAMESPACE $redis_sts" <<<"$readers" ||
    die "$redis_sts does not read $REDIS_KEY from $data_secret; refusing to rotate a password Redis would not use"
  plan+=("$DATA_NAMESPACE $redis_sts")
fi
while IFS= read -r reader; do
  [[ -n "$reader" ]] || continue
  [[ "$reader" == "$DATA_NAMESPACE $redis_sts" || "$reader" == "$DATA_NAMESPACE $pg_sts" ]] && continue
  plan+=("$reader")
done <<<"$readers"
grep -qxF "$app_namespace deployment/$backend" <<<"$readers" ||
  die "deployment/$backend does not read the rotated keys from $app_secret"
active_jobs=$(list_active_jobs) || die "could not list Jobs"
[[ -z "$active_jobs" ]] ||
  die "running Jobs read the Secrets and would keep the old password; wait for them: $(tr '\n' ' ' <<<"$active_jobs")"
cronjobs=$(list_cronjobs) || die "could not list CronJobs"
if [[ -n "$cronjobs" ]]; then
  printf '    CronJobs that read the Secrets pick up the new password on their next run: %s\n' "$cronjobs"
fi

if [[ -z "$recover_dir" ]]; then
  check_backend || die "the backend is not healthy before the rotation; fix that first"
fi

if [[ "$skip_backup_check" == true || -n "$recover_dir" ]]; then
  printf '    backup check skipped\n'
else
  label=$(data_target_label)
  newest=""
  if [[ -d "$backup_root" ]]; then
    while IFS= read -r set; do
      if [[ -f "$backup_root/$set/$DATA_SUMS_FILE" ]] &&
        grep -qxF "source=$label" "$backup_root/$set/$DATA_MANIFEST_FILE" 2>/dev/null; then
        newest=$set
        break
      fi
    done < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
      grep -E "$DATA_STAMP_PATTERN" | sort -r || true)
  fi
  [[ -n "$newest" ]] ||
    die "no backup set of this target in $backup_root; run bash scripts/backup-data.sh --context $DATA_CONTEXT first, or pass --skip-backup-check"
  taken=$(date -u -d "${newest:0:4}-${newest:4:2}-${newest:6:2} ${newest:9:2}:${newest:11:2}:${newest:13:2}" +%s)
  age=$(($(date -u +%s) - taken))
  ((age <= backup_max_age * 3600)) ||
    die "the newest backup set $newest is $((age / 3600)) hours old (limit $backup_max_age); take a new one with bash scripts/backup-data.sh --context $DATA_CONTEXT, or pass --skip-backup-check"
  (cd "$backup_root/$newest" && sha256sum --check --strict --quiet "$DATA_SUMS_FILE") ||
    die "backup set $backup_root/$newest fails its checksums"
  ok "backup set $newest is $((age / 60)) minutes old and its checksums match"
fi

step "Plan"
if has_component postgresql; then
  printf '    ALTER ROLE %s PASSWORD (new 64-character random password)\n' "$pg_role"
fi
printf '    patch %s in %s/%s, then %s/%s\n' "${keys[*]}" "$DATA_NAMESPACE" "$data_secret" "$app_namespace" "$app_secret"
for reader in "${plan[@]}"; do
  printf '    rolling restart %s/%s\n' "${reader%% *}" "${reader#* }"
done
printf '    not restarted: %s/%s (reads the password only at initdb; probes use the local socket)\n' \
  "$DATA_NAMESPACE" "$pg_sts"
printf '    expect failures from the first credential change until the backend rollout completes:\n'
printf '    old backend Pods cannot open new connections and go NotReady once Redis restarts\n'

if [[ "$apply" != true ]]; then
  printf 'Dry run: nothing was changed. Re-run with --apply to rotate.\n'
  exit 0
fi

# --- Apply ----------------------------------------------------------------------------------
# Old and new password files for the target and for the "other" side.
if [[ -n "$recover_dir" ]]; then
  target_dir="$work/$recover_to"
  other_dir="$work/old"
  [[ "$recover_to" == old ]] && other_dir="$work/new"
else
  target_dir="$work/new"
  other_dir="$work/old"
  for key in "${keys[@]}"; do
    od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$target_dir/$key"
    [[ "$(wc -c <"$target_dir/$key")" -eq 64 ]] || die "could not generate a password"
  done
fi

redis_before=""
if has_component redis; then
  redis_before=$(data_redis_persistent_keyset_digests) || die "could not read the Redis key set"
fi

print_state() {
  printf '  State now:\n' >&2
  if has_component postgresql; then
    printf '    PostgreSQL role %-28s %s password\n' "$pg_role:" "$st_role" >&2
  fi
  printf '    Secret %-36s %s password\n' "$DATA_NAMESPACE/$data_secret:" "$st_data" >&2
  printf '    Secret %-36s %s password\n' "$app_namespace/$app_secret:" "$st_app" >&2
  if [[ ${#restarted[@]} -gt 0 ]]; then
    printf '    restarted (must be restarted again once the Secrets are consistent): %s\n' \
      "$(printf '%s\n' "${restarted[@]}" | tr ' ' / | tr '\n' ' ')" >&2
  fi
}

recovery_hint() {
  local args=(bash scripts/rotate-data-credentials.sh --context "$DATA_CONTEXT"
    --kubeconfig "$DATA_KUBECONFIG" --namespace "$DATA_NAMESPACE" --app-namespace "$app_namespace"
    --data-secret "$data_secret" --app-secret "$app_secret" --pg-pod "$DATA_PG_POD"
    --redis-pod "$DATA_REDIS_POD" --pg-role "$pg_role" --backend "$backend")
  [[ -n "$only" ]] && args+=(--only "$only")
  args+=(--timeout "$timeout" --state-dir "$state_root" --apply --recover "$work" --to)
  printf '  The old and new passwords are kept (mode 600, never printed) in %s\n' "$work" >&2
  printf '  To put everything back on the old passwords:\n    %sold\n' "$(printf '%q ' "${args[@]}")" >&2
  printf '  Or to finish on the new passwords:\n    %snew\n' "$(printf '%q ' "${args[@]}")" >&2
  printf '  --recover is idempotent; re-run it until it succeeds. It deletes %s when done.\n' "$work" >&2
}

# Undo every attempted step: Secrets first, so that the restarts read the old
# values, then the role, then restart again whatever was restarted.
rollback() {
  local failed=false reader component key result
  printf '\n!!! Rotation failed during: %s\n' "$phase" >&2
  print_state
  printf '  Rolling back to the old passwords.\n' >&2
  if [[ "$st_app" != old ]]; then
    # No resourceVersion: the rollback must win over whatever is there.
    if patch_secret "$app_namespace" "$app_secret" "" "$other_dir" "${keys[@]}" &&
      secret_holds "$app_namespace" "$app_secret" "$other_dir" "${keys[@]}"; then
      st_app=old
    else
      failed=true
    fi
  fi
  if [[ "$st_data" != old ]]; then
    if patch_secret "$DATA_NAMESPACE" "$data_secret" "" "$other_dir" "${keys[@]}" &&
      secret_holds "$DATA_NAMESPACE" "$data_secret" "$other_dir" "${keys[@]}"; then
      st_data=old
    else
      failed=true
    fi
  fi
  if [[ "$st_role" != old ]]; then
    if pg_set_password "$other_dir/$PG_KEY"; then st_role=old; else failed=true; fi
  fi
  if [[ "$failed" != true ]]; then
    for reader in "${restarted[@]}"; do
      if ! restart_workload "${reader%% *}" "${reader#* }" ||
        ! wait_workload "${reader%% *}" "${reader#* }"; then
        failed=true
      fi
    done
  fi
  if [[ "$failed" != true ]]; then
    for component in "${components[@]}"; do
      key=$(key_of "$component")
      result=$(login "$component" "$other_dir/$key")
      if [[ "$result" != ok ]]; then
        printf '    the old %s password does not log in after the rollback (%s)\n' "$component" "$result" >&2
        failed=true
      fi
    done
  fi
  if [[ "$failed" == true ]]; then
    keep_work=true
    printf '\n!!! ROLLBACK INCOMPLETE.\n' >&2
    print_state
    recovery_hint
  else
    printf '  Rolled back: the role, both Secrets and the restarted workloads use the old passwords again.\n' >&2
    if [[ ${#restarted[@]} -gt 0 ]]; then
      printf '  Check the application with bash scripts/validate-app.sh.\n' >&2
    fi
  fi
}

# In recover mode there is nothing known-good to roll back to: report and keep
# the directory instead, and let the operator re-run.
fail_recover() {
  local status=$?
  trap - EXIT
  trap '' INT TERM HUP
  set +e
  printf '\n!!! Recovery failed during: %s\n' "$phase" >&2
  printf '  The role and the Secrets are being set to the %s passwords; parts done so far:\n' "$recover_to" >&2
  print_state
  recovery_hint
  exit "$((status == 0 ? 1 : status))"
}

if [[ -n "$recover_dir" ]]; then
  # States here are relative to the recovery target, not the rotation.
  st_role=unknown st_data=unknown st_app=unknown
  trap fail_recover EXIT
else
  rotating=true
fi
target_word=new
[[ -n "$recover_dir" ]] && target_word=$recover_to
forward_data_version=$data_version
forward_app_version=$app_version

# The client-visible window runs from the first change a running client can
# notice (ALTER ROLE, or the Redis restart when only Redis rotates) until the
# last rollout finishes.
window_start=""
window_from=""
mark_window() { # what changed
  if [[ -z "$window_start" ]]; then
    window_start=$(date +%s.%N)
    window_from=$1
  fi
}

if has_component postgresql; then
  phase="ALTER ROLE $pg_role"
  step "$phase"
  mark_window "ALTER ROLE"
  st_role=unknown
  pg_set_password "$target_dir/$PG_KEY" || die "ALTER ROLE failed"
  st_role=$target_word
  ok "role $pg_role has the $target_word password"
fi

phase="patch Secret $DATA_NAMESPACE/$data_secret"
step "$phase"
st_data=unknown
patch_secret "$DATA_NAMESPACE" "$data_secret" "$forward_data_version" "$target_dir" "${keys[@]}" ||
  die "Secret patch failed (409 Conflict means the Secret changed after the checks)"
secret_holds "$DATA_NAMESPACE" "$data_secret" "$target_dir" "${keys[@]}" ||
  die "Secret $DATA_NAMESPACE/$data_secret does not hold the $target_word passwords after the patch"
st_data=$target_word
ok "sha256 of ${keys[*]} matches the $target_word passwords"

phase="patch Secret $app_namespace/$app_secret"
step "$phase"
st_app=unknown
patch_secret "$app_namespace" "$app_secret" "$forward_app_version" "$target_dir" "${keys[@]}" ||
  die "Secret patch failed (409 Conflict means the Secret changed after the checks)"
secret_holds "$app_namespace" "$app_secret" "$target_dir" "${keys[@]}" ||
  die "Secret $app_namespace/$app_secret does not hold the $target_word passwords after the patch"
st_app=$target_word
ok "sha256 of ${keys[*]} matches the $target_word passwords"

for reader in "${plan[@]}"; do
  phase="rolling restart of ${reader%% *}/${reader#* }"
  step "$phase"
  mark_window "the ${reader#* } restart"
  restarted+=("$reader")
  restart_workload "${reader%% *}" "${reader#* }" || die "restart failed"
  wait_workload "${reader%% *}" "${reader#* }" || die "rollout did not finish"
done
if [[ -n "$window_start" ]]; then
  window_seconds=$(awk -v a="$window_start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
  ok "client window: ${window_seconds} s from $window_from until the last rollout finished"
fi

phase="verification"
step "Verify"
data_require_component postgresql
data_require_component redis
for component in "${components[@]}"; do
  key=$(key_of "$component")
  result=$(login "$component" "$target_dir/$key")
  [[ "$result" == ok ]] || die "the $target_word $component password does not log in ($result)"
  if [[ -s "$other_dir/$key" ]] && ! cmp -s "$other_dir/$key" "$target_dir/$key"; then
    result=$(login "$component" "$other_dir/$key")
    [[ "$result" == rejected ]] || die "the previous $component password is not rejected ($result)"
    ok "$component: the $target_word password logs in, the previous one is rejected"
  else
    ok "$component: the $target_word password logs in"
  fi
done
if has_component redis; then
  [[ "$(data_redis_persistent_keyset_digests)" == "$redis_before" ]] ||
    die "the Redis keys without a TTL changed across the restart"
  ok "Redis keys without a TTL are unchanged across the restart"
fi
check_backend || die "the backend does not serve requests with the $target_word passwords"

rotating=false
trap on_exit EXIT
if [[ -n "$recover_dir" ]]; then
  keep_work=false
  printf 'Recovery complete: the role, both Secrets and their readers use the %s passwords. Removed %s.\n' \
    "$recover_to" "$work"
else
  printf 'Rotation complete: %s rotated in the role, both Secrets and their readers.\n' "${keys[*]}"
fi
printf 'The previous passwords no longer work. Operators who keep MINISHOP_POSTGRES_PASSWORD or\n'
printf 'MINISHOP_REDIS_PASSWORD must not re-run create-data-credentials.sh, create-app-credentials.sh,\n'
printf 'deploy-data.sh or deploy-kustomize-dev.sh with the old values: those write them back into\n'
printf 'the Secrets without changing the role, and the next restart fails to log in.\n'
