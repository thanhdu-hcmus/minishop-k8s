#!/usr/bin/env bash
#
# Shared settings and helpers for the ECK-managed logging stack (Issue #59,
# ADR 0017): deploy-eck.sh, deploy-logging.sh, validate-logging.sh,
# teardown-logging.sh, validate-logging-manifests.sh and test-logging.sh.
#
# Elasticsearch API calls run inside the Elasticsearch container through
# `kubectl exec`. The container reads the elastic user's password from the
# Secret volume that manifests/40-logging/elasticsearch.yaml mounts and hands
# it to curl through a pipe, so the password never passes through this shell,
# a command line, or any output. No script reads a Secret through the API.
# In-container commands are single-quoted on purpose: they expand inside the
# container. The constants are used by the scripts that source this file.
# shellcheck disable=SC2016,SC2034

LOGGING_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly LOGGING_REPO_ROOT
readonly LOGGING_MANIFESTS="$LOGGING_REPO_ROOT/manifests/40-logging"

# ECK 3.2.0 is the newest release whose support matrix includes Kubernetes
# 1.30 (kind-learn runs v1.30.13). ECK 3.3.0 and later support 1.31+ only, so
# bump ECK together with the kind node image; see ADR 0017. The checksums pin
# the official download-host manifests; deploy-eck.sh also pins the operator
# image digest after the checksum check.
readonly ECK_VERSION=3.2.0
readonly ECK_DOWNLOAD_URL="https://download.elastic.co/downloads/eck/${ECK_VERSION}"
readonly ECK_CRDS_SHA256=2ba3cb0d134e13651e44a65cbe820544a36f5d6ff6a24abf3529c59a435384ea
readonly ECK_OPERATOR_SHA256=74c5bd9e3e14529c3480bcf04c0bd623d500c84bba6396b21d39cc5a8fc90809
readonly ECK_OPERATOR_IMAGE="docker.elastic.co/eck/eck-operator:${ECK_VERSION}"
readonly ECK_OPERATOR_DIGEST=sha256:6f6e3fa64f64d79279e2ceccdb0ab917ecc9c079446a633976387621eb301869
readonly ECK_NAMESPACE=elastic-system
readonly ECK_CRD_COUNT=10
# The operator reconciles, watches and caches only these namespaces; ECK
# 3.2.0 adds its own namespace itself (cmd/manager/main.go). This narrows
# what the operator caches and acts on, not its RBAC: the ClusterRole still
# covers every namespace (ADR 0017).
readonly ECK_MANAGED_NAMESPACES="[logging]"

# Names used by manifests/40-logging. Keep them in step with the manifests.
readonly LOGGING_NAMESPACE=logging
readonly LOGGING_ES_NAME=logging
readonly LOGGING_KIBANA_NAME=logging
readonly LOGGING_BEAT_NAME=filebeat
readonly LOGGING_ILM_POLICY=minishop-logs
readonly LOGGING_ES_HOST="${LOGGING_ES_NAME}-es-http.${LOGGING_NAMESPACE}.svc"

# Target cluster. Scripts accept --context and --kubeconfig to change these;
# the defaults are the repository's kind-learn settings (AGENTS.md).
LOGGING_KUBECONFIG="$LOGGING_REPO_ROOT/.kube/config"
LOGGING_CONTEXT="kind-learn"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

logging_require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done
}

logging_kubectl() {
  kubectl --kubeconfig "$LOGGING_KUBECONFIG" --context "$LOGGING_CONTEXT" "$@"
}

logging_require_context() {
  [[ -r "$LOGGING_KUBECONFIG" ]] || die "kubeconfig $LOGGING_KUBECONFIG is not readable"
  logging_kubectl config get-contexts "$LOGGING_CONTEXT" --no-headers 2>/dev/null | grep -q . ||
    die "context $LOGGING_CONTEXT is not in $LOGGING_KUBECONFIG"
  logging_kubectl cluster-info >/dev/null || die "cannot reach the API server of $LOGGING_CONTEXT"
}

# logging_download NAME SHA256 FILE: download an ECK release manifest and
# refuse it unless its SHA-256 matches the pinned value.
logging_download() {
  local name=$1 sha=$2 file=$3
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    --output "$file" "$ECK_DOWNLOAD_URL/$name" || die "could not download ECK $ECK_VERSION $name"
  printf '%s  %s\n' "$sha" "$file" | sha256sum --check --status ||
    die "ECK $ECK_VERSION $name checksum mismatch; refusing to use it"
}

# logging_patch_operator FILE: in a checksum-verified operator.yaml, pin the
# operator image by digest and set the managed namespaces in the operator's
# eck.yaml ConfigMap. The checksum fixed the file, so each edit must match
# exactly once; anything else stops.
logging_patch_operator() {
  local file=$1 image_line anchor ns_line
  image_line="image: \"$ECK_OPERATOR_IMAGE\""
  [[ "$(grep -cF -- "$image_line" "$file")" -eq 1 ]] ||
    die "expected one '$image_line' line in operator.yaml"
  [[ "$(grep -c 'image:' "$file")" -eq 1 ]] ||
    die "operator.yaml has an image line this script does not pin"
  sed -i "s|$image_line|image: \"$ECK_OPERATOR_IMAGE@$ECK_OPERATOR_DIGEST\"|" "$file"
  grep -qF -- "$ECK_OPERATOR_IMAGE@$ECK_OPERATOR_DIGEST" "$file" ||
    die "could not pin the operator image digest"

  anchor="    operator-namespace: $ECK_NAMESPACE"
  ns_line="    namespaces: $ECK_MANAGED_NAMESPACES"
  [[ "$(grep -cxF -- "$anchor" "$file")" -eq 1 ]] ||
    die "expected one '$anchor' line in operator.yaml"
  if grep -qE '^ +namespaces:' "$file"; then
    die "operator.yaml already sets namespaces"
  fi
  sed -i "s|^$anchor\$|&\n$ns_line|" "$file"
  [[ "$(grep -cxF -- "$ns_line" "$file")" -eq 1 ]] ||
    die "could not set the operator's managed namespaces"
}

# logging_eck_installed: 0 when all ECK CRDs are established.
logging_eck_installed() {
  local established
  established=$(logging_kubectl get crd -l app.kubernetes.io/name=eck-operator-crds \
    -o 'jsonpath={range .items[*]}{.status.conditions[?(@.type=="Established")].status}{"\n"}{end}' \
    2>/dev/null | grep -c '^True$') || true
  [[ "${established:-0}" -eq "$ECK_CRD_COUNT" ]]
}

# logging_es_pod: name of a Running Elasticsearch Pod of the logging cluster.
logging_es_pod() {
  local pods
  pods=$(logging_kubectl -n "$LOGGING_NAMESPACE" get pods \
    -l "elasticsearch.k8s.elastic.co/cluster-name=$LOGGING_ES_NAME" \
    -o 'jsonpath={range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}') || return 1
  [[ -n "$pods" ]] || return 1
  printf '%s\n' "${pods%%$'\n'*}"
}

# Runs inside the Elasticsearch container: $1 method, $2 path, $3 host. The
# request body is read from stdin. The TLS name is the HTTP Service, resolved
# to the loopback address, so the call stays inside the Pod and the
# ECK-managed CA verifies the certificate.
readonly LOGGING_ES_CURL='
curl --silent --show-error --fail-with-body --max-time 60 \
  --cacert /usr/share/elasticsearch/config/http-certs/ca.crt \
  --resolve "$3:9200:127.0.0.1" \
  --config <(printf "user = \"elastic:%s\"\n" "$(cat /mnt/elastic-user/elastic)") \
  --request "$1" --header "Content-Type: application/json" \
  --data-binary @- "https://$3:9200$2"'

# logging_es_api METHOD PATH: call the Elasticsearch API as the elastic user;
# stdin is the request body (use </dev/null for none). Prints the response.
logging_es_api() {
  local pod
  pod=$(logging_es_pod) || {
    printf '%s\n' "No running Elasticsearch Pod in $LOGGING_NAMESPACE." >&2
    return 1
  }
  logging_kubectl -n "$LOGGING_NAMESPACE" exec -i "$pod" -c elasticsearch -- \
    bash -c "$LOGGING_ES_CURL" es-api "$1" "$2" "$LOGGING_ES_HOST"
}

# logging_resource_field KIND NAME JSONPATH: a field of a resource in the
# logging namespace (never use it on a Secret).
logging_resource_field() {
  logging_kubectl -n "$LOGGING_NAMESPACE" get "$1" "$2" -o "jsonpath=$3" 2>/dev/null
}

# logging_wait_health KIND NAME TIMEOUT ACCEPTED-REGEX: poll .status.health.
logging_wait_health() {
  local kind=$1 name=$2 timeout=$3 accepted=$4 deadline health=""
  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    health=$(logging_resource_field "$kind" "$name" '{.status.health}') || health=""
    if [[ "$health" =~ ^($accepted)$ ]]; then
      printf '%s %s health: %s\n' "$kind" "$name" "$health"
      return 0
    fi
    sleep 5
  done
  printf '%s %s health is "%s" after %ss (wanted %s).\n' "$kind" "$name" "${health:-unknown}" \
    "$timeout" "$accepted" >&2
  return 1
}

# logging_target_usage: the shared --context/--kubeconfig option text.
readonly LOGGING_TARGET_USAGE='  --context NAME       kubeconfig context (default kind-learn)
  --kubeconfig FILE    kubeconfig file (default ./.kube/config)'
