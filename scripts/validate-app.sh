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
# it to prove the route is gone, so first refuse to run against any backend Pod
# whose image is not a MiniShop backend build or is one of the published digests
# that still serve that route.
upload_enabled_digests=(
  sha256:e87390d3420f8e51e2df726f9efcc9e3946c40174723a045243f2dc3eeff62f4
  sha256:44a87d71dda575c0e062e1474eafbe5885169aeb0ce4c123b81f2b497dd1d7af
  sha256:599480a80f5fa26755cf368c0b13fdc9406580421477e8970981c39fc2f35114
)
backend_selector=app.kubernetes.io/component=minishop-backend,app.kubernetes.io/name=minishop
backend_images=$(kubectl_for_minishop -n webapp get pods --selector "$backend_selector" -o \
  'jsonpath={range .items[*]}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}{end}')
if [[ -z "$backend_images" ]]; then
  printf '%s\n' 'No backend Pod reports an image; cannot check POST /upload safely.' >&2
  exit 1
fi
while IFS= read -r image_id; do
  if [[ "$image_id" != *ghcr.io/thanhdu-hcmus/minishop-backend@sha256:* ]]; then
    printf 'Backend Pod image %s is not a MiniShop backend build; not sending POST /upload.\n' \
      "$image_id" >&2
    exit 1
  fi
  for digest in "${upload_enabled_digests[@]}"; do
    if [[ "$image_id" == *"@$digest" ]]; then
      printf 'Backend Pod image %s still serves the destructive POST /upload; deploy the #40 image first.\n' \
        "$image_id" >&2
      exit 1
    fi
  done
done <<<"$backend_images"

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
  // The backend no longer serves POST /upload (#40); any 2xx means it does.
  const upload = await request("POST", "/upload");
  if (upload.status >= 200 && upload.status < 300) {
    throw new Error("POST /upload is still enabled (HTTP " + upload.status + ")");
  }
  const after = await getItems();
  if (!hasItems(after) || fingerprint(after.body) !== fingerprint(items.body)) {
    throw new Error("items changed after POST /upload");
  }
  console.log("POST /upload answered HTTP " + upload.status + " and changed nothing.");
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
  node -e "$frontend_probe"

kubectl_for_minishop -n webapp get networkpolicy \
  minishop-default-deny minishop-frontend minishop-backend >/dev/null

printf '%s\n' 'MiniShop frontend, backend, and data path validated.'
