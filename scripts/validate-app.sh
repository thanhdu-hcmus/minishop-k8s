#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_context

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

kubectl kustomize "$REPO_ROOT/kustomize/overlays/dev" \
  --load-restrictor LoadRestrictionsNone >"$rendered"
kubectl_for_minishop apply --dry-run=server -f "$rendered" >/dev/null

kubectl_for_minishop -n data get secret minishop-data-credentials >/dev/null
kubectl_for_minishop -n webapp get secret minishop-app-credentials >/dev/null
kubectl_for_minishop -n data rollout status statefulset/minishop-postgresql --timeout=180s
kubectl_for_minishop -n data rollout status statefulset/minishop-redis --timeout=180s
kubectl_for_minishop -n webapp rollout status deployment/minishop-backend --timeout=180s
kubectl_for_minishop -n webapp rollout status deployment/minishop-frontend --timeout=180s

# Before #40, POST /upload dropped and recreated marketItems. The probe below sends
# it to prove the route is gone, so it is sent only when every backend container
# runs a #40 or later image. The primary check is positive: #40 images ship
# /usr/src/app/seed.js and older ones do not. The digests every pre-#40 publish
# run produced (backend-image.yml on main: #24, #43, #46, #48) are a second guard.
# A pre-#40 image only skips the POST probe, so validation still passes between
# the #40 merge and its digest pin; anything that is not a pinned MiniShop
# backend image fails. Both the requested image (spec) and the running one
# (imageID) are checked: the runtime reports imageID by content, so a Pod that
# requests the same bytes under another name still shows the ghcr.io name.
backend_spec_pattern='^ghcr\.io/thanhdu-hcmus/minishop-backend@sha256:[0-9a-f]{64}$'
backend_image_pattern='^(docker-pullable://)?ghcr\.io/thanhdu-hcmus/minishop-backend@sha256:[0-9a-f]{64}$'
upload_enabled_digests=(
  sha256:e87390d3420f8e51e2df726f9efcc9e3946c40174723a045243f2dc3eeff62f4
  sha256:44a87d71dda575c0e062e1474eafbe5885169aeb0ce4c123b81f2b497dd1d7af
  sha256:599480a80f5fa26755cf368c0b13fdc9406580421477e8970981c39fc2f35114
  sha256:f10f726b3b9ccac97f0aeb56aef94a1756031ff4d36deed8ef44cefedb71e05a
)
backend_selector=app.kubernetes.io/component=minishop-backend,app.kubernetes.io/name=minishop
# One line per container: "spec <pod> <container> <image>" for each requested
# image, then "status <pod> <container> <imageID>" for each running one. $pod is
# a go-template variable, not a shell one, so the template stays in single quotes.
# shellcheck disable=SC2016
backend_containers=$(kubectl_for_minishop -n webapp get pods --selector "$backend_selector" -o \
  'go-template={{range .items}}{{$pod := .metadata.name}}{{range .spec.containers}}spec {{$pod}} {{.name}} {{.image}}{{"\n"}}{{end}}{{range .status.containerStatuses}}status {{$pod}} {{.name}} {{.imageID}}{{"\n"}}{{end}}{{end}}')
if ! grep -q '^status ' <<<"$backend_containers"; then
  printf '%s\n' 'No backend Pod reports a container; cannot check POST /upload safely.' >&2
  exit 1
fi
legacy_pods=()
while read -r kind pod container image_id; do
  if [[ "$kind" == spec ]]; then
    if [[ ! "$image_id" =~ $backend_spec_pattern ]]; then
      printf 'Backend Pod %s container %s requests image "%s", not a pinned MiniShop backend image.\n' \
        "$pod" "$container" "${image_id:-}" >&2
      exit 1
    fi
    continue
  fi
  if [[ ! "$image_id" =~ $backend_image_pattern ]]; then
    printf 'Backend Pod %s container %s image "%s" is not a pinned MiniShop backend image.\n' \
      "$pod" "$container" "${image_id:-}" >&2
    exit 1
  fi
  # Prints present or absent; anything else means exec failed, so fail closed.
  seed_file=$(kubectl_for_minishop -n webapp exec "pod/$pod" -c "$container" -- \
    sh -c 'if test -f /usr/src/app/seed.js; then echo present; else echo absent; fi' \
    </dev/null) || seed_file=
  case "$seed_file" in
    present) ;;
    absent)
      legacy_pods+=("$pod")
      continue
      ;;
    *)
      printf 'Could not check backend Pod %s for seed.js; not sending POST /upload.\n' "$pod" >&2
      exit 1
      ;;
  esac
  for digest in "${upload_enabled_digests[@]}"; do
    if [[ "$image_id" == *"@$digest" ]]; then
      legacy_pods+=("$pod")
    fi
  done
done <<<"$backend_containers"
send_upload_probe=true
if ((${#legacy_pods[@]} > 0)); then
  send_upload_probe=false
  printf 'WARNING: backend Pod(s) %s run a pre-#40 image that still serves the destructive POST /upload. Skipping only the POST /upload probe; the read checks still run. Deploy the #40 digest pin to run it.\n' \
    "${legacy_pods[*]}" >&2
fi

frontend_probe='const http = require("http");
const request = (method, path) => new Promise((resolve, reject) => {
  const request = http.request({ hostname: "127.0.0.1", port: 8080, method, path }, response => {
    let body = "";
    response.on("data", chunk => { body += chunk; });
    response.on("end", () => resolve({ status: response.statusCode, body }));
  });
  request.on("error", reject);
  request.end();
});
const parse = body => {
  try {
    return JSON.parse(body);
  } catch (_) {
    return undefined;
  }
};
const getItems = async () => {
  const response = await request("GET", "/items?q=");
  return { status: response.status, body: parse(response.body) };
};
const hasItems = items =>
  items.status === 200 && Array.isArray(items.body) && items.body.length > 0;
// /items has no ORDER BY and flags the first rows with specialOffer, so compare
// rows without that flag and independent of order.
const fingerprint = rows => rows.map(row => {
  const data = Object.assign({}, row.data);
  delete data.specialOffer;
  return JSON.stringify(data);
}).sort().join("\n");
(async () => {
  const items = await getItems();
  if (!hasItems(items)) {
    // An empty list, or 500 with SQLSTATE 42P01 (table missing), means unseeded.
    // The validator no longer seeds; the chart seed Job does (seed.enabled=true).
    const code = items.body && items.body.code ? " code " + items.body.code : "";
    throw new Error("frontend to backend to postgresql check failed: HTTP " + items.status +
      code + "; seed an empty database with the chart seed Job (seed.enabled=true)");
  }
  // sendUploadProbe is prepended by the script: false while any backend Pod runs
  // a pre-#40 image, where this request would drop and reseed the table.
  if (sendUploadProbe) {
    // #40 removed the route, so Express answers 404; anything else is a failure.
    const upload = await request("POST", "/upload");
    if (upload.status !== 404) {
      throw new Error("POST /upload answered HTTP " + upload.status + ", expected 404");
    }
    const after = await getItems();
    if (!hasItems(after) || fingerprint(after.body) !== fingerprint(items.body)) {
      throw new Error("items changed after POST /upload");
    }
    console.log("POST /upload answered HTTP 404 and changed nothing.");
  } else {
    console.log("POST /upload probe skipped (pre-#40 backend image).");
  }
  const reviews = await request("GET", "/items/" + items.body[0].data.index + "/reviews");
  const reviewList = parse(reviews.body);
  if (reviews.status !== 200 || !Array.isArray(reviewList) || reviewList.length === 0) {
    throw new Error("frontend to backend to redis check failed");
  }
})().catch(error => { console.error(error.message); process.exit(1); });'

# The immutable Deployment selector also matches legacy frontend Pods, so resolve
# the Pod with part-of=minishop instead of exec into deployment/minishop-frontend.
frontend_selector=app.kubernetes.io/component=frontend,app.kubernetes.io/name=minishop
frontend_selector+=,app.kubernetes.io/part-of=minishop
kubectl_for_minishop -n webapp wait pod --selector "$frontend_selector" \
  --field-selector=status.phase=Running --for=condition=Ready --timeout=180s >/dev/null
frontend_pod=$(kubectl_for_minishop -n webapp get pods --selector "$frontend_selector" \
  --field-selector=status.phase=Running -o 'jsonpath={.items[0].metadata.name}')
printf 'Probing through MiniShop frontend Pod %s.\n' "$frontend_pod"

kubectl_for_minishop -n webapp exec "pod/$frontend_pod" -c frontend -- \
  node -e "const sendUploadProbe = $send_upload_probe;"$'\n'"$frontend_probe"

kubectl_for_minishop -n webapp get networkpolicy \
  minishop-default-deny minishop-frontend minishop-backend >/dev/null

if [[ "$send_upload_probe" == true ]]; then
  printf '%s\n' 'MiniShop frontend, backend, and data path validated.'
else
  printf '%s\n' 'MiniShop frontend, backend, and data path validated; POST /upload probe skipped (WARNING above).'
fi
