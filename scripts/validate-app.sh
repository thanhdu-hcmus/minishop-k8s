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
(async () => {
  const upload = await request("POST", "/upload");
  if (upload.status !== 200) throw new Error("upload request failed");
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const items = await request("GET", "/items?q=");
    try {
      if (items.status === 200 && Array.isArray(JSON.parse(items.body)) && JSON.parse(items.body).length > 0) {
        return;
      }
    } catch (_) {}
    await sleep(1000);
  }
  throw new Error("frontend to backend to data check failed");
})().catch(error => { console.error(error.message); process.exit(1); });'

kubectl_for_minishop -n webapp exec deployment/minishop-frontend -- \
  node -e "$frontend_probe"

kubectl_for_minishop -n webapp get networkpolicy \
  minishop-default-deny minishop-frontend minishop-backend >/dev/null

printf '%s\n' 'MiniShop frontend, backend, and data path validated.'
