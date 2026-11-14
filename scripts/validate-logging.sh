#!/usr/bin/env bash
#
# Validate the logging stack end to end (Issue #59, ADR 0017):
#   - Elasticsearch is green or yellow, Kibana and Filebeat are green;
#   - ILM policy minishop-logs exists with its 3d delete phase;
#   - a unique pino-style test line written to a MiniShop backend Pod's log
#     becomes searchable in Elasticsearch, with Kubernetes metadata and its
#     JSON decoded (message, log.level, pino.*), in an index that the
#     minishop-logs policy manages.
#
# Usage:
#   bash scripts/validate-logging.sh [--timeout SECONDS] [--context NAME] [--kubeconfig FILE]
#
# The test line is written to the standard output of PID 1 in one Running
# backend Pod (webapp, app.kubernetes.io/component=minishop-backend), so it
# appears once in that Pod's log; nothing else in MiniShop changes. Searches
# run as the elastic user inside the Elasticsearch container
# (scripts/logging-lib.sh); no password is read or printed here.
#   --timeout SECONDS    how long to wait for the line to be searchable (default 180)

# The in-container command is single-quoted on purpose: it expands inside
# the backend container.
# shellcheck disable=SC2016

set -euo pipefail
set +x

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=logging-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/logging-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  printf '%s\n' "$LOGGING_TARGET_USAGE" >&2
}

timeout=180
# LOGGING_CONTEXT and LOGGING_KUBECONFIG are read by logging-lib.sh.
# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout=${2:?--timeout needs a value}; shift 2 ;;
    --context) LOGGING_CONTEXT=${2:?--context needs a value}; shift 2 ;;
    --kubeconfig) LOGGING_KUBECONFIG=${2:?--kubeconfig needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive number of seconds"

readonly APP_NAMESPACE=webapp
readonly BACKEND_SELECTOR=app.kubernetes.io/component=minishop-backend
readonly BACKEND_CONTAINER=backend
readonly PROBE_NAME=minishop-log-probe

logging_require_commands kubectl
logging_require_context
pass() { printf 'PASS: %s\n' "$*"; }

# --- Stack health ---------------------------------------------------------------
logging_wait_health elasticsearch "$LOGGING_ES_NAME" 30 'green|yellow' >/dev/null ||
  die "Elasticsearch $LOGGING_ES_NAME is not green or yellow"
logging_wait_health kibana "$LOGGING_KIBANA_NAME" 30 green >/dev/null ||
  die "Kibana $LOGGING_KIBANA_NAME is not green"
logging_wait_health beat "$LOGGING_BEAT_NAME" 30 green >/dev/null ||
  die "Filebeat $LOGGING_BEAT_NAME is not green"
pass "Elasticsearch $(logging_resource_field elasticsearch "$LOGGING_ES_NAME" '{.status.health}'), Kibana green, Filebeat green ($(logging_resource_field beat "$LOGGING_BEAT_NAME" '{.status.availableNodes}') nodes)"

policy=$(logging_es_api GET "/_ilm/policy/$LOGGING_ILM_POLICY?filter_path=*.policy.phases.delete.min_age" </dev/null) ||
  die "ILM policy $LOGGING_ILM_POLICY is missing; re-run scripts/deploy-logging.sh"
[[ "$policy" == *'"min_age":"3d"'* ]] || die "ILM policy $LOGGING_ILM_POLICY has no 3d delete phase"
pass "ILM policy $LOGGING_ILM_POLICY deletes indices 3d after rollover"

# --- Test line from a MiniShop backend Pod --------------------------------------
backend=$(logging_kubectl -n "$APP_NAMESPACE" get pods -l "$BACKEND_SELECTOR" \
  -o 'jsonpath={range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}')
backend=${backend%%$'\n'*}
[[ -n "$backend" ]] || die "no Running backend Pod in $APP_NAMESPACE ($BACKEND_SELECTOR)"

token="logprobe-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
line=$(printf '{"level":30,"time":%s000,"pid":1,"hostname":"%s","name":"%s","msg":"%s"}' \
  "$(date -u +%s)" "$backend" "$PROBE_NAME" "$token")
logging_kubectl -n "$APP_NAMESPACE" exec "$backend" -c "$BACKEND_CONTAINER" -- \
  sh -c 'printf "%s\n" "$1" >/proc/1/fd/1' probe "$line" ||
  die "could not write the test line to $APP_NAMESPACE/$backend"
printf 'Wrote test line %s to %s/%s; waiting up to %ss for it in Elasticsearch\n' \
  "$token" "$APP_NAMESPACE" "$backend" "$timeout"

# The token alone finds the line whether or not it was decoded. The full query
# also requires the metadata and the decoded fields; must_not proves the raw
# JSON was replaced by the pino msg.
found_query=$(printf '{"query":{"match_phrase":{"message":"%s"}}}' "$token")
decoded_query=$(printf '{"query":{"bool":{"filter":[{"match_phrase":{"message":"%s"}},{"term":{"log.level":"info"}},{"term":{"pino.name":"%s"}},{"term":{"pino.level":30}},{"term":{"kubernetes.namespace":"%s"}},{"term":{"kubernetes.pod.name":"%s"}},{"term":{"kubernetes.labels.app_kubernetes_io/component":"minishop-backend"}}],"must_not":[{"match_phrase":{"message":"%s"}}]}}}' \
  "$token" "$PROBE_NAME" "$APP_NAMESPACE" "$backend" "$PROBE_NAME")

count() {
  local response
  response=$(logging_es_api POST '/filebeat-*/_count?filter_path=count' <<<"$1") || return 1
  response=${response#*\"count\":}
  printf '%s\n' "${response%%[!0-9]*}"
}

found=0
start=$SECONDS
deadline=$((SECONDS + timeout))
while ((SECONDS < deadline)); do
  found=$(count "$found_query" 2>/dev/null) || found=0
  [[ "${found:-0}" -ge 1 ]] && break
  sleep 5
done
if [[ "${found:-0}" -lt 1 ]]; then
  pod_query=$(printf '{"query":{"term":{"kubernetes.pod.name":"%s"}}}' "$backend")
  printf 'Documents in filebeat-*: %s; from %s: %s.\n' \
    "$(count '{"query":{"match_all":{}}}' || echo unknown)" "$backend" \
    "$(count "$pod_query" || echo unknown)" >&2
  die "test line $token is not searchable after ${timeout}s; check the Filebeat Pod logs on the backend's node"
fi
pass "test line searchable after $((SECONDS - start))s"

decoded=$(count "$decoded_query") || decoded=0
[[ "${decoded:-0}" -eq 1 ]] ||
  die "test line found but not decoded as expected (message, log.level, pino.*, kubernetes.*): $decoded match(es)"
pass "test line decoded: message, log.level=info, pino.name, kubernetes namespace, pod and labels"

hit=$(logging_es_api POST '/filebeat-*/_search?filter_path=hits.hits._index' <<<"$found_query")
index=${hit#*\"_index\":\"}
index=${index%%\"*}
[[ -n "$index" && "$index" != "$hit" ]] || die "could not read the index of the test line"
explain=$(logging_es_api GET "/$index/_ilm/explain?filter_path=indices.*.policy" </dev/null)
[[ "$explain" == *"\"policy\":\"$LOGGING_ILM_POLICY\""* ]] ||
  die "index $index is not managed by $LOGGING_ILM_POLICY: $explain"
pass "index $index is managed by ILM policy $LOGGING_ILM_POLICY"

printf 'Logging validation passed in context %s.\n' "$LOGGING_CONTEXT"
