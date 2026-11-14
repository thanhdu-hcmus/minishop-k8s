#!/usr/bin/env bash
#
# Test the --remove-eck guard of scripts/teardown-logging.sh (Issue #59, ADR
# 0017) with stubbed kubectl, curl and sha256sum on PATH. No cluster, network
# or Docker is used; nothing outside a scratch directory is touched.
#
# Usage:
#   bash scripts/test-teardown-logging.sh
#
# Cases: the CRD listing fails (with and without --yes); nine of the ten ECK
# CRDs exist and a resource lives outside logging; ten CRDs with such a
# resource; a per-CRD resource listing fails; a dry run that would be
# refused. In each, the script must stop (or only print) and issue no delete.
# Control: nine CRDs with resources only in logging, which must proceed and
# delete the stack, the namespace, Filebeat's RBAC, the operator and the CRDs.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly TEARDOWN="$SCRIPT_DIR/teardown-logging.sh"

case "${1:-}" in
  '') ;;
  -h | --help) sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
  *) printf 'Unknown option %s\n' "$1" >&2; exit 2 ;;
esac

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin"
: >"$scratch/kubeconfig"

# Stub kubectl: records each call in $STUB_DIR/calls and answers from files
# in $STUB_DIR (crds, resources, *-fails markers).
cat >"$scratch/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls"
while [[ "${1:-}" == --kubeconfig || "${1:-}" == --context ]]; do shift 2; done
case "$*" in
  "config get-contexts "*) echo stub; exit 0 ;;
  cluster-info) exit 0 ;;
  "get crd -o name")
    [[ -f "$STUB_DIR/crd-list-fails" ]] && { echo 'stub: crd list failed' >&2; exit 1; }
    sed 's|^|customresourcedefinition.apiextensions.k8s.io/|' "$STUB_DIR/crds"
    exit 0 ;;
  "get "*".k8s.elastic.co --all-namespaces "*)
    [[ -f "$STUB_DIR/resource-list-fails" ]] && { echo 'stub: list failed' >&2; exit 1; }
    awk -v crd="$2" '$1 == crd { print $2, $3 }' "$STUB_DIR/resources"
    exit 0 ;;
  "get namespace logging") [[ -f "$STUB_DIR/namespace-deleted" ]] && exit 1; exit 0 ;;
  "delete namespace logging "*) touch "$STUB_DIR/namespace-deleted"; exit 0 ;;
  "delete "* | "-n logging delete "*) exit 0 ;;
esac
echo "stub kubectl: unexpected call: $*" >&2
exit 99
STUB
# Stub curl writes an empty file; stub sha256sum accepts it. Only the control
# case gets this far.
cat >"$scratch/bin/curl" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --output ]]; then : >"$2"; exit 0; fi
  shift
done
exit 1
STUB
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' >"$scratch/bin/sha256sum"
chmod +x "$scratch/bin/kubectl" "$scratch/bin/curl" "$scratch/bin/sha256sum"

readonly ALL_CRDS='agents.agent.k8s.elastic.co
apmservers.apm.k8s.elastic.co
beats.beat.k8s.elastic.co
elasticmapsservers.maps.k8s.elastic.co
elasticsearchautoscalers.autoscaling.k8s.elastic.co
elasticsearches.elasticsearch.k8s.elastic.co
enterprisesearches.enterprisesearch.k8s.elastic.co
kibanas.kibana.k8s.elastic.co
logstashes.logstash.k8s.elastic.co
stackconfigpolicies.stackconfigpolicy.k8s.elastic.co'
NINE_CRDS=$(grep -v '^agents\.' <<<"$ALL_CRDS")
readonly NINE_CRDS
readonly LOGGING_ONLY='elasticsearches.elasticsearch.k8s.elastic.co logging logging
kibanas.kibana.k8s.elastic.co logging logging
beats.beat.k8s.elastic.co logging filebeat'
readonly WITH_FOREIGN="$LOGGING_ONLY
elasticsearches.elasticsearch.k8s.elastic.co data other-cluster"

failures=0
# run_case NAME EXPECT(fail|pass) CRDS RESOURCES MARKERS ARGS...
run_case() {
  local name=$1 expect=$2 crds=$3 resources=$4 markers=$5 status=0 marker deletes
  shift 5
  export STUB_DIR="$scratch/$name"
  mkdir "$STUB_DIR"
  printf '%s\n' "$crds" | sed '/^$/d' >"$STUB_DIR/crds"
  printf '%s\n' "$resources" | sed '/^$/d' >"$STUB_DIR/resources"
  for marker in $markers; do touch "$STUB_DIR/$marker"; done
  PATH="$scratch/bin:$PATH" bash "$TEARDOWN" --context stub --kubeconfig "$scratch/kubeconfig" "$@" \
    >"$STUB_DIR/out" 2>&1 || status=$?
  deletes=$(grep -c ' delete ' "$STUB_DIR/calls" || true)
  if [[ "$expect" == fail ]]; then
    if [[ "$status" -ne 0 && "$deletes" -eq 0 ]]; then
      printf 'PASS: %s: stopped (exit %s), no delete: %s\n' "$name" "$status" "$(grep -m1 'Error' "$STUB_DIR/out")"
    else
      printf 'FAIL: %s: exit %s, %s delete call(s)\n' "$name" "$status" "$deletes"
      sed 's/^/  /' "$STUB_DIR/out"
      failures=$((failures + 1))
    fi
  elif [[ "$expect" == dry ]]; then
    if [[ "$status" -eq 0 && "$deletes" -eq 0 ]] && grep -q 'would be refused' "$STUB_DIR/out"; then
      printf 'PASS: %s: dry run reports the refusal, no delete\n' "$name"
    else
      printf 'FAIL: %s: exit %s, %s delete call(s)\n' "$name" "$status" "$deletes"
      sed 's/^/  /' "$STUB_DIR/out"
      failures=$((failures + 1))
    fi
  else
    local wanted missing=""
    for wanted in 'delete beats.beat.k8s.elastic.co filebeat' 'delete kibanas.kibana.k8s.elastic.co logging' \
      'delete elasticsearches.elasticsearch.k8s.elastic.co logging' 'delete namespace logging' \
      'delete clusterrole logging-filebeat' 'operator.yaml' 'crds.yaml'; do
      grep -q -- "$wanted" "$STUB_DIR/calls" || missing+=" [$wanted]"
    done
    if [[ "$status" -eq 0 && -z "$missing" ]]; then
      printf 'PASS: %s: proceeded with %s delete calls\n' "$name" "$deletes"
    else
      printf 'FAIL: %s: exit %s, missing%s\n' "$name" "$status" "${missing:- nothing}"
      sed 's/^/  /' "$STUB_DIR/out"
      failures=$((failures + 1))
    fi
  fi
}

run_case crd-list-fails fail "$ALL_CRDS" "$LOGGING_ONLY" crd-list-fails --yes --remove-eck
run_case crd-list-fails-dry-run fail "$ALL_CRDS" "$LOGGING_ONLY" crd-list-fails --remove-eck
run_case nine-crds-foreign fail "$NINE_CRDS" "$WITH_FOREIGN" '' --yes --remove-eck
run_case ten-crds-foreign fail "$ALL_CRDS" "$WITH_FOREIGN" '' --yes --remove-eck
run_case resource-list-fails fail "$ALL_CRDS" "$LOGGING_ONLY" resource-list-fails --yes --remove-eck
run_case resource-list-fails-dry-run fail "$ALL_CRDS" "$LOGGING_ONLY" resource-list-fails --remove-eck
run_case foreign-dry-run dry "$NINE_CRDS" "$WITH_FOREIGN" '' --remove-eck
run_case control-nine-crds pass "$NINE_CRDS" "$LOGGING_ONLY" '' --yes --remove-eck

if ((failures > 0)); then
  printf '%s teardown guard case(s) failed.\n' "$failures" >&2
  exit 1
fi
printf 'All teardown guard tests passed.\n'
