#!/usr/bin/env bash
#
# Validate manifests/40-logging offline (Issue #59, ADR 0017). No cluster is
# used.
#   - kubeconform (strict) checks every document: core kinds against the
#     Kubernetes schemas, and the Elasticsearch, Kibana and Beat resources
#     against JSON schemas built from the pinned, checksum-verified ECK CRDs.
#     Unknown fields fail, except where the CRD preserves them (podTemplate,
#     config).
#   - Policy checks: one Elastic Stack version everywhere, every image pinned
#     by digest, CPU and memory requests and limits on every container, the
#     ILM policy deletes after 3d, and Filebeat links to that policy.
#
# Usage:
#   bash scripts/validate-logging-manifests.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=logging-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/logging-lib.sh"

case "${1:-}" in
  '') ;;
  -h | --help) sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
  *) die "unknown option $1" ;;
esac

logging_require_commands curl docker python3 sha256sum
readonly KUBECONFORM_IMAGE=ghcr.io/yannh/kubeconform:v0.6.7

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/schemas"
logging_download crds.yaml "$ECK_CRDS_SHA256" "$work/crds.yaml"

# Build kubeconform schemas ({kind}_{version}.json, lower case) from each CRD
# version's openAPIV3Schema. Objects with declared properties reject unknown
# ones, as the API server prunes them; preserve-unknown-fields stays open.
python3 -I - "$work/crds.yaml" "$work/schemas" <<'PY'
import json
import os
import sys

import yaml


def close(node):
    if isinstance(node, dict):
        if (
            node.get("type") == "object"
            and "properties" in node
            and "additionalProperties" not in node
            and not node.get("x-kubernetes-preserve-unknown-fields")
        ):
            node["additionalProperties"] = False
        for value in node.values():
            close(value)
    elif isinstance(node, list):
        for value in node:
            close(value)


count = 0
with open(sys.argv[1], encoding="utf-8") as handle:
    for doc in yaml.safe_load_all(handle):
        if not doc or doc.get("kind") != "CustomResourceDefinition":
            continue
        kind = doc["spec"]["names"]["kind"].lower()
        for version in doc["spec"]["versions"]:
            schema = version["schema"]["openAPIV3Schema"]
            close(schema)
            path = os.path.join(sys.argv[2], f"{kind}_{version['name']}.json")
            with open(path, "w", encoding="utf-8") as out:
                json.dump(schema, out)
            count += 1
if count == 0:
    sys.exit("no CRD schemas found")
print(f"Built {count} ECK CRD schemas")
PY

manifests=()
for file in "$LOGGING_MANIFESTS"/*.yaml; do
  manifests+=("/work/${file#"$LOGGING_REPO_ROOT"/}")
done
docker run --rm \
  --volume "$LOGGING_REPO_ROOT:/work:ro" \
  --volume "$work/schemas:/schemas:ro" \
  "$KUBECONFORM_IMAGE" -summary -strict \
  -schema-location default \
  -schema-location '/schemas/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json' \
  "${manifests[@]}"

python3 -I - "$LOGGING_MANIFESTS" "$LOGGING_ILM_POLICY" <<'PY'
import glob
import json
import os
import re
import sys

import yaml

directory, policy_name = sys.argv[1], sys.argv[2]
errors = []
docs = []
for path in sorted(glob.glob(os.path.join(directory, "*.yaml"))):
    with open(path, encoding="utf-8") as handle:
        docs += [(os.path.basename(path), d) for d in yaml.safe_load_all(handle) if d]


def pod_specs(doc):
    spec = doc.get("spec", {})
    kind = doc["kind"]
    if kind == "Elasticsearch":
        return [n.get("podTemplate", {}).get("spec", {}) for n in spec.get("nodeSets", [])]
    if kind == "Kibana":
        return [spec.get("podTemplate", {}).get("spec", {})]
    if kind == "Beat":
        return [spec.get("daemonSet", {}).get("podTemplate", {}).get("spec", {})]
    return []


stack = {}
for name, doc in docs:
    kind = doc["kind"]
    if kind not in ("Elasticsearch", "Kibana", "Beat"):
        continue
    version = doc["spec"].get("version")
    image = doc["spec"].get("image", "")
    stack[f"{name}:{kind}"] = version
    if not re.fullmatch(r"docker\.elastic\.co/[a-z/]+:" + re.escape(str(version)) + r"@sha256:[0-9a-f]{64}", image):
        errors.append(f"{name} {kind}: image {image!r} is not {version} pinned by digest")
    for pod in pod_specs(doc):
        containers = pod.get("containers", [])
        if not containers:
            errors.append(f"{name} {kind}: podTemplate has no container settings")
        for container in containers:
            resources = container.get("resources", {})
            for section in ("requests", "limits"):
                for key in ("cpu", "memory"):
                    if key not in resources.get(section, {}):
                        errors.append(f"{name} {kind}/{container.get('name')}: no {section}.{key}")
    if kind == "Beat":
        config = doc["spec"].get("config", {})
        if config.get("setup.ilm.policy_name") != policy_name:
            errors.append(f"{name}: Filebeat setup.ilm.policy_name is not {policy_name}")
        if config.get("setup.ilm.overwrite") is not False:
            errors.append(f"{name}: Filebeat must not overwrite the ILM policy")

if len(set(stack.values())) != 1:
    errors.append(f"Elastic Stack versions differ: {stack}")

with open(os.path.join(directory, "ilm-policy.json"), encoding="utf-8") as handle:
    phases = json.load(handle)["policy"]["phases"]
if phases.get("delete", {}).get("min_age") != "3d" or "delete" not in phases["delete"].get("actions", {}):
    errors.append("ilm-policy.json: no delete action at min_age 3d")

if errors:
    print("\n".join("FAIL: " + e for e in errors), file=sys.stderr)
    sys.exit(1)
print(f"Policy checks passed: stack {next(iter(stack.values()))}, digests, resources, ILM.")
PY

printf '%s\n' 'manifests/40-logging validates.'
