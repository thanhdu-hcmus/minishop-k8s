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
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
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
const isUnseeded = items =>
  items.status === 200 &&
  ((Array.isArray(items.body) && items.body.length === 0) ||
    (items.body !== undefined && items.body.code === "42P01"));
(async () => {
  let items = await getItems();
  if (hasItems(items)) {
    console.log("Items already present; skipping POST /upload.");
  } else {
    // POST /upload drops and recreates the table, so run it only with nothing to lose.
    if (!isUnseeded(items)) throw new Error("items request failed before seeding");
    const upload = await request("POST", "/upload");
    if (upload.status !== 200) throw new Error("upload request failed");
    for (let attempt = 0; attempt < 20 && !hasItems(items); attempt += 1) {
      await sleep(1000);
      items = await getItems();
    }
    if (!hasItems(items)) throw new Error("frontend to backend to postgresql check failed");
  }
  const reviews = await request("GET", "/items/" + items.body[0].data.index + "/reviews");
  const reviewList = parse(reviews.body);
  if (reviews.status !== 200 || !Array.isArray(reviewList) || reviewList.length === 0) {
    throw new Error("frontend to backend to redis check failed");
  }
})().catch(error => { console.error(error.message); process.exit(1); });'

# The Deployment and Service selectors also match legacy frontend Pods, so resolve
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
