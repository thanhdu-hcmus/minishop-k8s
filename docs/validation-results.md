# MiniShop Resilience Validation Results

**Issue:** [#32 — validate pod recovery and data persistence](https://github.com/thanhdu-hcmus/minishop-k8s/issues/32)

**Date:** 2026-09-28
**Cluster:** `kind-learn`

## Scope and safety

The test used only the MiniShop resources introduced by the linked slices. The
legacy `webapp/backend`, `webapp/frontend`, and `data/redis` workloads were not
targeted. Deployment Pod selection used these exact labels:

```text
Backend:  app.kubernetes.io/component=minishop-backend,
          app.kubernetes.io/name=minishop,
          app.kubernetes.io/part-of=minishop
Frontend: app.kubernetes.io/component=frontend,
          app.kubernetes.io/name=minishop,
          app.kubernetes.io/part-of=minishop
```

The frontend selector includes `part-of=minishop` because the frontend
Deployment's own selector is broader and the legacy frontend Pods share its
other two labels. StatefulSet checks targeted only
`data/minishop-postgresql-0` and `data/minishop-redis-0`.

All cluster commands used the existing `kind-learn` context. The isolated
worktree did not contain the ignored kubeconfig, so commands used the existing
root-checkout kubeconfig path in place. Its contents were not read, copied, or
printed. No Secret values were accessed or logged.

## Baseline and final state

Before mutations, read-only projections captured all Deployments and
StatefulSets, HPAs, PVCs, and PVs. The same projections were captured after
cleanup and compared exactly:

| Resource set | Baseline | Final | Result |
|---|---:|---:|---|
| Deployments and StatefulSets | 18 | 18 | Metadata projections identical; all expected replicas Ready |
| HPAs | 2 | 2 | Metadata projections identical; MiniShop HPA returned to 3/3 |
| PVCs | 5 Bound | 5 Bound | Names, UIDs, PV bindings, classes, and capacities identical |
| PVs | 5 Bound | 5 Bound | Names, UIDs, claim references, classes, capacities, and reclaim policies identical |

The MiniShop backend HPA remained configured for 3–8 replicas. Legacy
Deployments, StatefulSets, HPAs, platform workloads, and all storage bindings
were unchanged. Pre-existing database-report Jobs and Pods were left alone.

## Pod recovery

One Pod at a time was deleted using the MiniShop-only label selectors above.
Both controller-created replacements reached Ready:

| Workload | Deleted Pod | Replacement | Verification |
|---|---|---|---|
| Frontend Deployment | `minishop-frontend-75c5d596b5-htbvp` | `minishop-frontend-75c5d596b5-z8972` | Deployment rollout completed; replacement Ready; frontend `GET /` returned HTTP 200 |
| Backend Deployment | `minishop-backend-7495cdf8cb-nljq2` | `minishop-backend-7495cdf8cb-tlfkv` | Deployment rollout completed; three selected backend Pods Ready |

The frontend's read-only `GET /items?q=` also returned HTTP 200, but the JSON
response had PostgreSQL error code `28P01` (invalid password) rather than
application data. Credential values and database records were not inspected or
changed. This is recorded as an existing runtime limitation, not a successful
database-backed application check; credential diagnosis and repair are outside
Issue #32's approved scope.

## Persistent data recovery

- PostgreSQL: created a uniquely named temporary table and marker in the
  MiniShop database using the PostgreSQL Pod's local socket and injected
  non-secret database/user settings. After deleting and recreating only
  `minishop-postgresql-0`, the marker was present. The temporary table was
  dropped, and its absence was verified.
- Redis: set a unique key with a 900-second expiry using the Redis Pod's
  injected password internally, without printing it. After deleting and
  recreating only `minishop-redis-0`, the value matched. The key was deleted,
  and `EXISTS` returned zero.

Both StatefulSet Pods returned Ready with new Pod UIDs. No PVC or PV was deleted,
recreated, or modified.

## Bounded HPA load test

The existing `deploy/30-platform/hpa-load-test.yaml` was used; it creates a
MiniShop-labeled Job with a 180-second load window and a 240-second active
deadline, plus two narrowly selected temporary NetworkPolicies. Replica samples
were collected while the Job ran and while the HPA settled.

| Point | Backend Deployment replicas | HPA bounds |
|---|---:|---:|
| Baseline | 3/3 Ready | 3–8 |
| Peak under load | 8/8 Ready | 3–8 |
| Settled after load | 3/3 Ready | 3–8 |

The test Job and Pod and both temporary NetworkPolicies were explicitly deleted;
follow-up queries found none of them. The backend HPA and Deployment returned to
the original 3 Ready replicas. No HPA configuration was changed.

## Reproducible commands

Run from the repository root in a shell without command tracing (`set -x` is
not enabled). The examples use only the exact MiniShop selectors and resources;
never substitute legacy `backend`, `frontend`, `postgres`, or `redis` names.

### Capture and compare baseline

The projections omit Secret data and include resource identity, desired/ready
counts, selectors, HPA bounds, and PVC/PV bindings. Save the `before` files
before pod deletion, and run the same commands with `.after` filenames after
all cleanup:

```bash
set -euo pipefail
export KUBECONFIG=./.kube/config
mkdir -p /tmp/minishop-issue32-evidence
evidence=/tmp/minishop-issue32-evidence
kubectl --context kind-learn get deploy,sts -A \
  -o custom-columns='KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid,SPEC:.spec.replicas,READY:.status.readyReplicas,SELECTOR:.spec.selector.matchLabels' \
  --no-headers | sort > "$evidence/workloads.before"
kubectl --context kind-learn get hpa -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid,REFERENCE:.spec.scaleTargetRef.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,CURRENT:.status.currentReplicas,DESIRED:.status.desiredReplicas' \
  --no-headers | sort > "$evidence/hpa.before"
kubectl --context kind-learn get pvc -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid,PHASE:.status.phase,PV:.spec.volumeName,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity.storage' \
  --no-headers | sort > "$evidence/pvc.before"
kubectl --context kind-learn get pv \
  -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,PHASE:.status.phase,CLAIMNS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,STORAGECLASS:.spec.storageClassName,CAPACITY:.spec.capacity.storage,RECLAIM:.spec.persistentVolumeReclaimPolicy' \
  --no-headers | sort > "$evidence/pv.before"
```

After cleanup, save the same projections to `workloads.after`, `hpa.after`,
`pvc.after`, and `pv.after`, then require exact equality:

```bash
for resource_set in workloads hpa pvc pv; do
  diff -u "$evidence/$resource_set.before" "$evidence/$resource_set.after"
done
```

### Recover Deployment Pods

Read the old UID, delete only one selected MiniShop Pod, wait for its
controller, then assert the replacement UID differs and its container is
Ready. Repeat these commands separately for the frontend and backend:

```bash
set -euo pipefail
backend_selector='app.kubernetes.io/component=minishop-backend,app.kubernetes.io/name=minishop,app.kubernetes.io/part-of=minishop'
frontend_selector='app.kubernetes.io/component=frontend,app.kubernetes.io/name=minishop,app.kubernetes.io/part-of=minishop'

pod=$(kubectl --context kind-learn -n webapp get pods -l "$frontend_selector" \
  -o jsonpath='{.items[0].metadata.name}')
old_uid=$(kubectl --context kind-learn -n webapp get pod "$pod" \
  -o jsonpath='{.metadata.uid}')
kubectl --context kind-learn -n webapp delete pod "$pod" --wait=true --timeout=120s
kubectl --context kind-learn -n webapp rollout status deployment/minishop-frontend --timeout=180s
replacement=$(kubectl --context kind-learn -n webapp get pods -l "$frontend_selector" \
  -o jsonpath='{.items[0].metadata.name}')
new_uid=$(kubectl --context kind-learn -n webapp get pod "$replacement" \
  -o jsonpath='{.metadata.uid}')
test "$old_uid" != "$new_uid"
kubectl --context kind-learn -n webapp get pod "$replacement" -o wide
kubectl --context kind-learn -n webapp exec "$replacement" -c frontend -- node -e \
  'require("node:http").get("http://127.0.0.1:8080/",r=>{r.resume();console.log("GET / HTTP "+r.statusCode);process.exit(r.statusCode===200?0:1)}).on("error",()=>process.exit(1))'
kubectl --context kind-learn -n webapp exec "$replacement" -c frontend -- node -e \
  'const h=require("node:http");h.get("http://127.0.0.1:8080/items?q=",r=>{let b="";r.on("data",c=>b+=c);r.on("end",()=>{let code="unknown";try{code=JSON.parse(b).code||"none"}catch{}console.log("GET /items?q= HTTP "+r.statusCode+" responseCode="+code)})}).on("error",e=>{console.log("GET /items?q= error="+e.code);process.exitCode=1})'

pod=$(kubectl --context kind-learn -n webapp get pods -l "$backend_selector" \
  -o jsonpath='{.items[0].metadata.name}')
old_uid=$(kubectl --context kind-learn -n webapp get pod "$pod" \
  -o jsonpath='{.metadata.uid}')
kubectl --context kind-learn -n webapp delete pod "$pod" --wait=true --timeout=120s
kubectl --context kind-learn -n webapp rollout status deployment/minishop-backend --timeout=180s
after_backend=$(kubectl --context kind-learn -n webapp get pods -l "$backend_selector" \
  -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,READY:.status.containerStatuses[0].ready' --no-headers | sort)
printf '%s\n' "$after_backend"
if printf '%s\n' "$after_backend" | grep -Fq "$old_uid"; then
  printf 'Deleted backend Pod UID is still selected: %s\n' "$old_uid" >&2
  exit 1
fi
pod_count=$(printf '%s\n' "$after_backend" | awk 'NF { count++ } END { print count+0 }')
ready_count=$(printf '%s\n' "$after_backend" | awk '$3 == "true" { count++ } END { print count+0 }')
test "$pod_count" = 3
test "$ready_count" = 3
```

The backend assertion verifies that the deleted UID is absent and all three
selector-matched Pods are Ready after rollout. Do not use the broader
Deployment selector for frontend Pod deletion: legacy frontend Pods share its
two Deployment selector labels.

### Verify persistent markers

Use unique test-only names and delete only the exact MiniShop StatefulSet Pods.
PostgreSQL uses the Pod's local socket and injected database/user settings with
`PGPASSWORD` explicitly unset. The SQL marker is sent through stdin; neither
credentials nor existing rows are queried or printed:

```bash
set -euo pipefail
pg_pod=minishop-postgresql-0
pg_table=issue32_resilience_20260928
pg_marker=issue32-pg-marker-20260928
pg_cleanup() {
  printf 'DROP TABLE IF EXISTS %s;\n' "$pg_table" |
    kubectl --context kind-learn -n data exec -i "$pg_pod" -c postgresql -- sh -ec \
      'unset PGPASSWORD; psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
      >/dev/null 2>&1 || true
}
trap pg_cleanup EXIT
printf '%s\n' \
  "CREATE TABLE $pg_table (marker text PRIMARY KEY);" \
  "INSERT INTO $pg_table(marker) VALUES ('$pg_marker');" |
  kubectl --context kind-learn -n data exec -i "$pg_pod" -c postgresql -- sh -ec \
    'unset PGPASSWORD; psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
kubectl --context kind-learn -n data delete pod "$pg_pod" --wait=true --timeout=120s
kubectl --context kind-learn -n data rollout status statefulset/minishop-postgresql --timeout=180s
persisted=$(kubectl --context kind-learn -n data exec "$pg_pod" -c postgresql -- sh -ec \
  "unset PGPASSWORD; psql -X -qAt -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"SELECT marker FROM $pg_table WHERE marker='$pg_marker'\"")
test "$persisted" = "$pg_marker"
printf 'DROP TABLE %s;\n' "$pg_table" |
  kubectl --context kind-learn -n data exec -i "$pg_pod" -c postgresql -- sh -ec \
    'unset PGPASSWORD; psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
absent=$(kubectl --context kind-learn -n data exec "$pg_pod" -c postgresql -- sh -ec \
  "unset PGPASSWORD; psql -X -qAt -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"SELECT to_regclass('public.$pg_table') IS NULL\"")
test "$absent" = t
trap - EXIT
```

Redis uses its injected password only inside the Pod command, with output
suppressed for `SET`. Its 900-second TTL is a safety net; still verify and
delete the key explicitly after the Pod returns Ready:

```bash
set -euo pipefail
redis_pod=minishop-redis-0
redis_key=issue32:resilience:20260928
redis_marker=issue32-redis-marker-20260928
redis_cleanup() {
  kubectl --context kind-learn -n data exec "$redis_pod" -c redis -- sh -ec \
    "REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli --no-auth-warning --raw DEL '$redis_key' >/dev/null" \
    >/dev/null 2>&1 || true
}
trap redis_cleanup EXIT
kubectl --context kind-learn -n data exec "$redis_pod" -c redis -- sh -ec \
  "REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli --no-auth-warning --raw SET '$redis_key' '$redis_marker' EX 900 >/dev/null"
kubectl --context kind-learn -n data delete pod "$redis_pod" --wait=true --timeout=120s
kubectl --context kind-learn -n data rollout status statefulset/minishop-redis --timeout=180s
persisted=$(kubectl --context kind-learn -n data exec "$redis_pod" -c redis -- sh -ec \
  "REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli --no-auth-warning --raw GET '$redis_key'")
test "$persisted" = "$redis_marker"
deleted=$(kubectl --context kind-learn -n data exec "$redis_pod" -c redis -- sh -ec \
  "REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli --no-auth-warning --raw DEL '$redis_key'")
test "$deleted" = 1
exists=$(kubectl --context kind-learn -n data exec "$redis_pod" -c redis -- sh -ec \
  "REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli --no-auth-warning --raw EXISTS '$redis_key'")
test "$exists" = 0
trap - EXIT
```

### Sample bounded HPA load

The existing manifest creates only the labeled MiniShop test Job and its two
temporary policies. Keep a cleanup trap armed so failure or interruption still
removes those exact resources. The Job runs for 180 seconds and has a 240-second
active deadline; sample the target Deployment, not the legacy backend:

```bash
set -euo pipefail
manifest=deploy/30-platform/hpa-load-test.yaml
cleanup() {
  kubectl --context kind-learn delete -f "$manifest" \
    --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
}
trap cleanup EXIT
baseline=$(kubectl --context kind-learn -n webapp get deployment minishop-backend \
  -o jsonpath='{.spec.replicas}')
peak=$baseline
limits=$(kubectl --context kind-learn -n webapp get hpa minishop-backend \
  -o jsonpath='{.spec.minReplicas}/{.spec.maxReplicas}')
test "$limits" = 3/8
kubectl --context kind-learn apply -f "$manifest"
for attempt in $(seq 1 36); do
  current=$(kubectl --context kind-learn -n webapp get deployment minishop-backend \
    -o jsonpath='{.spec.replicas}')
  ready=$(kubectl --context kind-learn -n webapp get deployment minishop-backend \
    -o jsonpath='{.status.readyReplicas}')
  printf 'sample=%s replicas=%s ready=%s\n' "$attempt" "$current" "$ready"
  test "$current" -ge 3 && test "$current" -le 8
  test "$ready" -le "$current"
  test "$current" -le "$peak" || peak=$current
  sleep 5
done
test "$peak" -gt "$baseline"
kubectl --context kind-learn -n webapp wait --for=condition=complete \
  job/minishop-hpa-load-test --timeout=240s
kubectl --context kind-learn delete -f "$manifest" --wait=true --timeout=60s
trap - EXIT
for attempt in $(seq 1 48); do
  current=$(kubectl --context kind-learn -n webapp get deployment minishop-backend \
    -o jsonpath='{.spec.replicas}')
  ready=$(kubectl --context kind-learn -n webapp get deployment minishop-backend \
    -o jsonpath='{.status.readyReplicas}')
  printf 'settle-sample=%s replicas=%s ready=%s\n' "$attempt" "$current" "$ready"
  test "$current" -ge 3 && test "$current" -le 8
  if test "$current" = 3 && test "$ready" = 3; then break; fi
  sleep 5
done
test "$current" = 3 && test "$ready" = 3
printf 'baseline=%s peak=%s settled=%s\n' "$baseline" "$peak" "$current"
```

Finally confirm the exact load-test resources are absent:

```bash
kubectl --context kind-learn -n webapp get job minishop-hpa-load-test
kubectl --context kind-learn -n webapp get networkpolicy \
  minishop-hpa-load-test-egress minishop-hpa-load-test-ingress
kubectl --context kind-learn -n webapp get pods \
  -l 'app.kubernetes.io/component=minishop-hpa-load-test,app.kubernetes.io/part-of=minishop'
```

The three `get` commands should report `NotFound` or no matching Pods after
cleanup. These commands intentionally do not read Secret objects or emit
injected password values.

## Limitations

The repository references `scripts/validate.sh`, but that file is absent. The
existing `scripts/validate-app.sh` writes an application record with
`POST /upload`, so it was not run to avoid mutating unrelated app data. The full
platform validator also performs a container restart beyond this Issue's test
scope. No dependencies, CI, storage, credentials, or HPA settings were changed.

The cluster uses Kind's `kindnet`, which does not enforce NetworkPolicies; the
temporary policies' presence does not establish enforcement behavior.
