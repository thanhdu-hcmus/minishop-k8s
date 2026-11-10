---
title: Legacy stack retirement runbook
requirement: Issue #38 — retire the legacy stack and own the Ingress in Git
status: proposed
last_updated: 2026-11-08
---

# Legacy Stack Retirement Runbook

## Goal
Retire, in a safe order, the hand-applied objects that predate the Git-owned
MiniShop runtime, and move `minishop.local` to the chart Ingress
`webapp/minishop`. The decision record is
[ADR 0011](decisions/0011-ingress-ownership-and-legacy-retirement.md).

Nothing here has been run. The owner approves each numbered step before it runs
and records the approval on Issue #38. Stop at the first check that does not
give the expected result.

## Scope
Legacy objects, all created with `kubectl apply` (each has a last-applied
annotation, which step 1 exports for undo):

| Namespace | Object | Step |
| --- | --- | --- |
| webapp | Ingress `minishop-frontend` | 2 |
| webapp | Service `frontend-loadbalancer-demo` (LoadBalancer) | 3 |
| webapp | Service `frontend`, Deployment `frontend` | 3 |
| webapp | HPA `backend`, Deployment `backend`, Service `backend`, ConfigMap `minishop-runtime` | 4 |
| webapp | CronJob `postgres-report`, Job `db-migration`, ConfigMap `minishop-postgres-schema`, Secret `postgres-app-creds` | 5 |
| data | CNPG Cluster `minishop-postgres`, Secret `postgres-creds` | 6, 7 |
| data | StatefulSet `redis`, Service `redis`, PVC `data-redis-0` | 6, 7 |
| metallb-system | MetalLB v0.14.9, IPAddressPool and L2Advertisement `minishop-pool` | 8 (owner decision) |

Not legacy, do not delete:
- HPA `webapp/minishop-backend`: Git-owned by
  `manifests/30-platform/autoscaling.yaml` (applied by `deploy-platform.sh`),
  deliberately outside the chart.
- ingress-nginx: Git-owned from this Issue by `scripts/deploy-ingress-nginx.sh`.
  The pinned manifest matched the running controller in a read-only
  `kubectl diff` on 2026-11-08, apart from the two admission Jobs.
- The CNPG operator in `cnpg-system`: its future depends on Issue #42.

## Reversibility key
- **Reversible**: re-apply the step 1 export to undo.
- **Data-reversible**: the objects can be recreated, but data comes back only
  by restoring the step 6 backups.
- **Irreversible**: no undo from this runbook.

## Prerequisites
- PR for Issue #38 merged to `main`; run from an up-to-date checkout in WSL.
- Docker, kubectl, and the cluster are healthy: `kubectl get nodes` shows four
  `Ready` nodes and `bash scripts/validate-app.sh` passes.
- A backup directory outside the repository. Never commit its contents.

```bash
cd /mnt/d/01_CAREER/DEVOPS/minishop-k8s
export KUBECONFIG="$PWD/.kube/config"
k() { kubectl --context kind-learn "$@"; }
umask 077
BACKUP_DIR="$HOME/minishop-legacy-backup"
mkdir -p "$BACKUP_DIR"
```

## Step 1: Export every legacy object (no change)
Check: each object exists. A `NotFound` means it is already gone; drop it from
the later steps.

```bash
cat >"$BACKUP_DIR/objects.txt" <<'LIST'
webapp ingress/minishop-frontend
webapp service/frontend-loadbalancer-demo
webapp service/frontend
webapp deployment/frontend
webapp horizontalpodautoscaler/backend
webapp deployment/backend
webapp service/backend
webapp configmap/minishop-runtime
webapp cronjob/postgres-report
webapp job/db-migration
webapp configmap/minishop-postgres-schema
data clusters.postgresql.cnpg.io/minishop-postgres
data statefulset/redis
data service/redis
metallb-system ipaddresspool.metallb.io/minishop-pool
metallb-system l2advertisement.metallb.io/minishop-pool
LIST
while read -r ns obj; do
  k -n "$ns" apply view-last-applied "$obj" -o yaml \
    >"$BACKUP_DIR/$ns-${obj//\//-}.yaml"
done <"$BACKUP_DIR/objects.txt"
ls -l "$BACKUP_DIR"
```

Secrets are deliberately not exported, so their values never reach disk.

## Step 2: Move minishop.local to the chart Ingress
ingress-nginx admission rejects a second Ingress for the same host and path,
and `deploy-helm.sh` refuses to run while the legacy Ingress exists. The legacy
Ingress therefore goes first. `minishop.local` returns 404 from deletion until
the upgrade creates `webapp/minishop`; validating first keeps that gap to about
a minute.

Check:

```bash
k -n webapp get ingress minishop-frontend \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}|{.spec.rules[0].host}{"\n"}'
# expect: |minishop.local   (not Helm-managed)
k -n webapp get endpointslices -l kubernetes.io/service-name=minishop-frontend \
  -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready} {end}{"\n"}'
# expect: at least one "true"
.tools/bin/helm --kube-context kind-learn -n webapp history minishop --max 1
# record the current REVISION for undo
bash scripts/deploy-helm.sh values-dev.yaml
# expect: exit 1 with exactly
#   Ingress webapp/minishop-frontend already routes minishop.local; retire it first (docs/legacy-retirement-runbook.md).
# Every check before this preflight is read-only (local commands, kubectl
# config and cluster-info, and gets of the namespaces, Secrets, ServiceAccount,
# and HPA), so this message proves they all pass. Any other error: stop and fix
# it before deleting anything.
bash scripts/validate-helm.sh
```

Run:

```bash
k -n webapp delete ingress minishop-frontend
bash scripts/deploy-helm.sh values-dev.yaml
```

Expect the backend to drop to one replica briefly. `values-dev.yaml` sets
`replicas.backend: 1`, and Helm's three-way merge resets the live
`minishop-backend` replicas (3, held by HPA `minishop-backend`) to 1 until the
HPA restores its minimum of 3. The 2026-11-07 upgrade to revision 3 used the
same values; the HPA's last scale was recorded 8 s after it.

Verify:

```bash
k -n webapp get ingress minishop -o wide
# expect: CLASS nginx, HOSTS minishop.local, ADDRESS localhost
curl -fsS -o /dev/null -w '%{http_code}\n' -H 'Host: minishop.local' http://127.0.0.1/
curl -fsS -o /dev/null -w '%{http_code}\n' -H 'Host: minishop.local' http://127.0.0.1/items
# expect: 200 and 200
k -n webapp get service minishop-frontend -o jsonpath='{.spec.selector}{"\n"}'
# expect: includes app.kubernetes.io/part-of=minishop
bash scripts/validate-app.sh
```

NetworkPolicy is not enforced on this cluster (`kindnet`; see ADR 0011 and
ADR 0006), so a 200 here does not prove that
`minishop-frontend-from-ingress` is correct. Only a CNI that enforces policy
can test it.

Reversible. Undo: `.tools/bin/helm --kube-context kind-learn -n webapp
rollback minishop <recorded revision> --wait`, then
`k apply -f "$BACKUP_DIR/webapp-ingress-minishop-frontend.yaml"`. Roll back
first: the legacy Ingress cannot be created while `webapp/minishop` exists.

## Step 3: Retire the legacy frontend
Check:

```bash
k get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {..service.name}{"\n"}{end}'
# expect: only "webapp/minishop minishop-frontend"
k -n webapp get deployment frontend -o jsonpath='{.spec.replicas}{"\n"}'
# expect: 0
k -n webapp get rs -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name
# expect: the frontend-* ReplicaSet is owned by "frontend"; minishop-frontend-* by "minishop-frontend"
```

Run:

```bash
k -n webapp delete service frontend-loadbalancer-demo
k -n webapp delete service frontend
k -n webapp delete deployment frontend --wait=true
```

Never pass `--cascade=orphan` when deleting either frontend Deployment while
both exist. Their selectors overlap, so the surviving Deployment would adopt
the orphaned ReplicaSet and its Pods.

Verify: `k -n webapp get deploy,svc` lists only `minishop-*` frontend objects,
and the Step 2 curl commands still return 200.

Reversible: re-apply the three exports. MetalLB may assign
`frontend-loadbalancer-demo` a different address from the pool.

## Step 4: Retire the legacy backend
Its Pods may be `Ready` or stuck `Unknown` after a Docker restart (both were
seen on 2026-11-07 and 2026-11-08). What matters is that nothing calls it.

Check:

```bash
k -n webapp get deployment frontend
# expect: NotFound (step 3 done)
k -n webapp get deploy,sts -o jsonpath='{..args}{"\n"}' \
  | grep -o 'http://[a-z0-9.-]*:3001' | sort -u
# expect: only http://minishop-backend:3001
# (before step 3 it also lists http://backend.webapp.svc.cluster.local:3001)
```

Run:

```bash
k -n webapp delete horizontalpodautoscaler backend
k -n webapp delete deployment backend --wait=true --timeout=180s
k -n webapp delete service backend
k -n webapp get deploy,sts,cronjob,job -o json | grep -c '"minishop-runtime"'
# expect: 0 before the next command
k -n webapp delete configmap minishop-runtime
```

If a backend Pod stays `Terminating` for more than two minutes on a `Ready`
node, ask the owner before `k -n webapp delete pod <name> --grace-period=0
--force`.

Verify: `k -n webapp get pods` shows no `backend-*` Pods and
`bash scripts/validate-app.sh` passes.

Reversible: re-apply the ConfigMap, Service, Deployment, and HPA exports, in
that order.

## Step 5: Retire the legacy jobs
`postgres-report` only counts rows in CNPG `kumademo` every five minutes.

Check:

```bash
k -n webapp get cronjob postgres-report -o jsonpath='{.status.active}{"\n"}'
# expect: empty (no running Job)
```

Run:

```bash
k -n webapp delete cronjob postgres-report
k -n webapp delete job db-migration
k -n webapp get deploy,sts,cronjob,job -o json \
  | grep -c '"minishop-postgres-schema"\|"postgres-app-creds"'
# expect: 0 before the next two commands
k -n webapp delete configmap minishop-postgres-schema
k -n webapp delete secret postgres-app-creds
```

Reversible for the CronJob, Job, and ConfigMap: re-apply the exports.
Re-applying `db-migration` runs the schema SQL against CNPG again. The Secret
is irreversible from this runbook because its value is not exported.

## Step 6: Back up legacy data (no deletion)
Run this even before Issue #42 decides, so a copy exists.

This step covers only the legacy objects. The Helm-owned
`minishop-postgresql` and `minishop-redis` are backed up with
`scripts/backup-data.sh` (Issue #40; see the
[operator guide](./minishop-operator-guide.md#back-up-and-restore-data)).
Take one of those too before any retirement step.

CNPG `kumademo`. Check, and record the count (100 on 2026-11-08):

```bash
primary=$(k -n data get pod \
  -l cnpg.io/cluster=minishop-postgres,cnpg.io/instanceRole=primary -o name)
test -n "$primary" && echo "$primary"
k -n data exec "$primary" -c postgres -- \
  psql -d kumademo -Atc 'select count(*) from marketitems'
```

Run and verify:

```bash
k -n data exec "$primary" -c postgres -- pg_dump -Fc -d kumademo \
  >"$BACKUP_DIR/kumademo.dump"
k -n data exec -i "$primary" -c postgres -- pg_restore --list \
  <"$BACKUP_DIR/kumademo.dump" | grep -c 'TABLE DATA'
# expect: 1 or more, and the listing includes marketitems
sha256sum "$BACKUP_DIR/kumademo.dump" >"$BACKUP_DIR/kumademo.dump.sha256"
```

Legacy Redis `redis-0` (Redis 5.0.5, AOF on, no `dump.rdb` yet). Check, and
record the key count (101 on 2026-11-08):

```bash
k -n data exec redis-0 -c redis -- redis-cli DBSIZE
```

Run and verify (`SAVE` blocks Redis briefly and writes `/data/dump.rdb`):

```bash
k -n data exec redis-0 -c redis -- redis-cli SAVE
# expect: OK
k -n data exec redis-0 -c redis -- redis-check-rdb /data/dump.rdb
# expect: "RDB looks OK!"
k -n data exec redis-0 -c redis -- cat /data/dump.rdb >"$BACKUP_DIR/redis-legacy.rdb"
k -n data exec redis-0 -c redis -- cat /data/appendonly.aof >"$BACKUP_DIR/redis-legacy.aof"
k -n data exec redis-0 -c redis -- cat /data/dump.rdb | cmp - "$BACKUP_DIR/redis-legacy.rdb"
# expect: no output and exit 0 (the image has no sha256sum)
sha256sum "$BACKUP_DIR"/redis-legacy.* >"$BACKUP_DIR/redis-legacy.sha256"
```

No deletion; nothing to undo.

## Step 7: Delete legacy data
**Irreversible except by restore.** Run only when all are true: Issue #42 has
decided that this data is not kept in place, step 6 completed and verified,
and the owner approved this step. Every PV uses reclaim policy `Delete`, so
deleting a PVC destroys its data.

CNPG check:

```bash
k get deploy,sts,cronjob,job,configmap -A -o json | grep -c 'minishop-postgres-rw'
# expect: 0 (the chart backend uses minishop-postgresql)
```

Run:

```bash
k -n data delete clusters.postgresql.cnpg.io minishop-postgres --wait=true
k -n data get pvc minishop-postgres-1 minishop-postgres-2
# expect: NotFound for both (CNPG owns and removes its PVCs)
k -n data delete secret postgres-creds
```

The Cluster's generated Secrets and Services are garbage-collected with it.
Data-reversible: bootstrap a new Cluster, then restore with
`pg_restore --no-owner -d kumademo` from `kumademo.dump`.

Legacy Redis check:

```bash
k get deploy,sts,cronjob,job,configmap -A -o json \
  | grep -cE '"(redis-0\.)?redis\.data(\.svc(\.cluster\.local)?)?"'
# expect: 0 (the chart backend uses minishop-redis.data.svc.cluster.local)
```

Run:

```bash
k -n data delete statefulset redis --wait=true
k -n data delete service redis
k -n data delete pvc data-redis-0
```

The StatefulSet retains its PVC on deletion, so the PVC is deleted explicitly.
Data-reversible: re-apply the exports, then load `redis-legacy.rdb` into the
new volume before Redis starts.

## Step 8: Remove MetalLB (owner decision)
Recommended: after step 3 nothing uses a LoadBalancer Service, and
ingress-nginx on kind uses hostPorts. The owner decides; skip this step to keep
MetalLB for teaching.

Check:

```bash
k get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
# expect: empty
```

Run:

```bash
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output "$BACKUP_DIR/metallb-native-v0.14.9.yaml" \
  https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
echo "951065e85692aa106f1bb5d5a487d9306154923a794ab1d82122881cbaf588e4  $BACKUP_DIR/metallb-native-v0.14.9.yaml" \
  | sha256sum --check
# expect: OK. On a mismatch, stop: do not delete from that file.
k -n metallb-system delete l2advertisement minishop-pool
k -n metallb-system delete ipaddresspool minishop-pool
k delete -f "$BACKUP_DIR/metallb-native-v0.14.9.yaml"
```

The v0.14.9 manifest (SHA-256 above, computed 2026-11-08) matched the running
install in a read-only `kubectl diff` that day, apart from the CA bundle
MetalLB injects at runtime. Deleting it removes the namespace, CRDs, webhooks,
and RBAC.

Reversible: re-run the checksum on the saved file, then
`k apply -f "$BACKUP_DIR/metallb-native-v0.14.9.yaml"`, wait for
`k -n metallb-system rollout status deployment/controller`, and re-apply the
two pool exports.

## Step 9: Final verification

```bash
k -n webapp get deploy,svc,ingress,hpa,cronjob,job
# expect: minishop-* objects and HPA minishop-backend only
k -n data get sts,svc,pvc
k get pv
bash scripts/validate-app.sh
curl -fsS -o /dev/null -w '%{http_code}\n' -H 'Host: minishop.local' http://127.0.0.1/items
```

Record the results on Issue #38.

## Related Docs
- [ADR 0011](decisions/0011-ingress-ownership-and-legacy-retirement.md)
- [Helm packaging decision](decisions/0009-helm-packaging.md)
- [Issue #38](https://github.com/thanhdu-hcmus/minishop-k8s/issues/38),
  [Issue #42](https://github.com/thanhdu-hcmus/minishop-k8s/issues/42)
