# MiniShop Local Operator Guide

This guide describes the current WSL2/Kind development setup. It uses the
repository's Helm chart or Kustomize dev overlay; legacy raw manifests and the
original Windows-oriented draft are not deployment paths.

## Local prerequisites

- WSL2 with Docker available to the WSL shell, plus `kind` and `kubectl`.
- A Kind cluster named `learn`, using `cluster/kind-config.yaml`.
- From the repository root, use `KUBECONFIG=./.kube/config` and context
  `kind-learn`. `scripts/lib.sh` pins these for the deploy scripts. The
  kubeconfig is local, ignored, and must never be committed or printed.
- For deploy scripts, Docker must be running. Helm runs in the pinned
  `alpine/helm:3.17.3` container; a host Helm install is not required. Render
  validators also run pinned tools in containers.

Read-only checks from the repository root:

```bash
kind get clusters
KUBECONFIG=./.kube/config kubectl --context kind-learn cluster-info
KUBECONFIG=./.kube/config kubectl --context kind-learn get nodes
```

`bash scripts/create-cluster.sh` creates the local Kind cluster if it is absent
or refreshes its kubeconfig if it exists. This changes local cluster state; it
does not install the application.

Since Issue #50, a newly created cluster also gets
`scripts/tune-kindnet-resources.sh --apply`, which replaces the node image's
kindnet limits (100m CPU and 50Mi memory) with requests of 100m CPU and 128Mi,
a 256Mi memory limit, and no CPU limit, and sets
`priorityClassName: system-node-critical`. For an existing cluster the script
only reports and dry-runs, and `create-cluster.sh` only warns if that check
fails. Those limits cause Service outages after a Docker restart
([troubleshooting](./troubleshooting.md#kindnet-xtables-lock),
[ADR 0012](./decisions/0012-kindnet-resource-limits.md)). On an existing
cluster such as `kind-learn`, run
`bash scripts/tune-kindnet-resources.sh --apply` once, with owner approval; it
rolls kindnet one node at a time and persists across Docker restarts. As of
2026-11-08 it has not been applied to `kind-learn`.

## Reach minishop.local on a fresh cluster

Added by Issue #38. This sequence was assembled from the scripts; it has not
been run end to end on a newly created cluster. Every step changes local state.

1. `bash scripts/create-cluster.sh` creates `learn` from
   `cluster/kind-config.yaml`. The control-plane node gets the label
   `ingress-ready=true` and maps container ports 80 and 443 to host ports 80
   and 443. No `listenAddress` is set, so kind uses its default bind address
   (all interfaces). Creation fails if another process already holds host
   port 80 or 443. If `learn` already exists, the script only refreshes the
   kubeconfig; it does not add the label to an existing node.
2. `bash scripts/deploy-ingress-nginx.sh` installs the kind provider manifest
   for ingress-nginx `controller-v1.12.4` after a SHA-256 check, waits for the
   controller rollout, and waits up to 180 s for the admission webhook CA
   bundle. It stops if no node carries `ingress-ready=true` and prints the
   `kubectl label node` command for an existing cluster (owner approval
   needed).
3. Deploy the data and application runtime with one packaging path, after the
   prerequisites listed under [Deployment choices](#deployment-choices):
   `bash scripts/deploy-kustomize-dev.sh` or `bash scripts/deploy-helm.sh`.
   Both create Ingress `webapp/minishop` (class `nginx`, host
   `minishop.local`, path `/`, Service `minishop-frontend`). The older
   `scripts/deploy-app.sh` does not apply `manifests/20-webapp/ingress.yaml`.
4. Add `127.0.0.1 minishop.local` to the hosts file of the machine running the
   browser (on Windows, `C:\Windows\System32\drivers\etc\hosts`).
5. Open `http://minishop.local`. No port-forward is needed. Plain HTTP only;
   TLS is not configured.

On the existing `kind-learn` cluster, the hand-applied Ingress
`webapp/minishop-frontend` still claims `minishop.local`. Until step 2 of the
[legacy retirement runbook](./legacy-retirement-runbook.md) deletes it,
`deploy-helm.sh` and `deploy-kustomize-dev.sh` stop at a preflight check (see
[troubleshooting](./troubleshooting.md)). That cluster already has the node
label and the controller and is not recreated.

## Deployment choices

Use one runtime packaging path at a time. The Helm chart and the Kustomize
overlay describe the same app/data runtime; do not apply both over one another.
The Helm deploy script requires the `data` and `webapp` namespaces, both
MiniShop credential Secret objects, the `webapp/minishop-backend`
ServiceAccount, and the platform backend HPA with `minReplicas` of at least
three to exist before deployment. Kustomize deploy requires the ServiceAccount
for its backend Pods. If both `MINISHOP_POSTGRES_PASSWORD` and
`MINISHOP_REDIS_PASSWORD` are set, it creates the namespaces and both
credential Secrets; otherwise it expects the namespaces and Secrets to already
exist. Kustomize does not require the platform HPA. When installed, that HPA
can raise the dev overlay/chart request of one backend replica to its minimum.
Kustomize dev also brings in the shared local-path storage resources. The local
cluster described here already has the external platform and runtime
prerequisites. For the component-level setup and migration boundary, see
[Helm packaging](./decisions/0009-helm-packaging.md) and [Kustomize
packaging](./decisions/0008-kustomize-packaging.md).

### Helm (current local release)

The default deployment script selects the development values. It validates the
chart and waits for stateful and application workloads; it does not create or
change credentials, namespaces, storage, ServiceAccount, or platform
components. This command changes cluster state by installing or upgrading the
`minishop` Helm release in `webapp`:

```bash
bash scripts/deploy-helm.sh
```

The explicit local equivalent is `bash scripts/deploy-helm.sh values-dev.yaml`.
`values-prod.yaml` is a production-oriented configuration example, not the
local default or a recommendation for this Kind cluster. It requests three
backend and two frontend replicas and was render-validated, not deployed. The
chart defaults likewise are not the dev profile.

### Kustomize (development overlay)

The dev overlay requests one backend and one frontend replica. This deploy
script renders and validates the overlay, then applies the runtime resources;
it changes cluster state:

```bash
bash scripts/deploy-kustomize-dev.sh
```

The script reuses existing Secrets when no runtime password inputs are set. If
initializing or intentionally rotating credentials, it requires both
`MINISHOP_POSTGRES_PASSWORD` and `MINISHOP_REDIS_PASSWORD` together and creates
the data/app Secret objects. Handle those inputs through your approved local
secret-handling method; do not put values in source, command arguments, logs, or
this guide. Applying a changed Secret does not itself guarantee the running
workloads adopt it. The prod Kustomize overlay is also an example only and is
not deployed by this local workflow.

If changing a cluster from Kustomize runtime ownership to Helm, first review
`scripts/migrate-kustomize-to-helm.sh` and the Helm decision. The migration is
state-changing; do not install the Helm release over Kustomize-managed runtime
objects.

## Request and data flow

The browser talks to the frontend in namespace `webapp`; the frontend proxies
requests to the `minishop-backend` Service, also in `webapp`. The backend uses
the PostgreSQL and Redis Services in namespace `data`. The frontend Service is
cluster-internal, so these read-only local inspection commands briefly open a
local port-forward; stop it with Ctrl-C when finished, then browse to
`http://127.0.0.1:8080`:

```bash
frontend_pod=$(KUBECONFIG=./.kube/config kubectl --context kind-learn -n webapp \
  get pods --field-selector=status.phase=Running \
  -o 'jsonpath={.items[0].metadata.name}' --selector \
  app.kubernetes.io/component=frontend,app.kubernetes.io/name=minishop,app.kubernetes.io/part-of=minishop)
KUBECONFIG=./.kube/config kubectl --context kind-learn -n webapp \
  port-forward "pod/$frontend_pod" 8080:8080
```

Forward to the Pod, not `service/minishop-frontend`: the Service selector also
matches legacy frontend Pods, and only the `part-of=minishop` label separates
them. The port-forward is temporary and does not create a Kubernetes resource.
The Kind host-port mappings for 80/443 do not by themselves provide an Ingress
controller or expose the ClusterIP frontend Service.

## Namespaces, persistence, and platform

- `data`: PostgreSQL and Redis StatefulSets/Services; each StatefulSet owns its
  persistent claim. PVCs bind to the `standard` StorageClass and local-path
  provisioner.
- `webapp`: frontend and backend Deployments/Services, credential references,
  NetworkPolicies, and backend HPA.
- `monitoring`: Prometheus/Grafana stack and MiniShop dashboard/alert resources.
  `kube-system` contains metrics-server, which supplies resource metrics to the
  HPA.
- The Kind local-path storage is node-local, not replicated or highly
  available. Pod recovery was tested, but a node/storage failure is not
  equivalent to a durable off-cluster backup. PVC/PV and shared storage are
  outside both runtime packaging boundaries.
- The backend HPA is platform-owned and targets 3–8 replicas. It can raise the
  dev overlay/chart request of one backend replica to its minimum. The tested
  Kind `kindnet` CNI accepts NetworkPolicy objects but does not enforce them;
  successful apply is not proof of traffic isolation.

## Inspect and validate

These examples only query/render resources; they do not write to the cluster.
Do not query Secret data:

```bash
KUBECONFIG=./.kube/config kubectl --context kind-learn -n webapp \
  get deployments,services,hpa
KUBECONFIG=./.kube/config kubectl --context kind-learn -n data \
  get statefulsets,services,pvc
bash scripts/validate-kustomize.sh
bash scripts/validate-helm.sh
```

The two validators render the dev/prod configurations and run schema checks;
they do not install or upgrade workloads. Since Issue #40 `bash
scripts/validate-app.sh` no longer seeds. Before any request it checks every
backend container:

- Both its requested image (Pod spec) and its running image ID must be an
  anchored `ghcr.io/thanhdu-hcmus/minishop-backend@sha256:<64 hex>` reference;
  otherwise, or if no backend Pod reports a container, it exits 1. The spec is
  checked too because the runtime reports the image ID by content, so a Pod
  that requests the same bytes under another name still shows the ghcr.io name.
- It runs `test -f /usr/src/app/seed.js` in the container (`kubectl exec`).
  Only #40 and later images ship that file. If any container lacks it, or runs
  one of the four pre-#40 published digests (`e87390d3...`, `44a87d71...`,
  `599480a8...`, `f10f726b...`), the script prints a WARNING and skips only the
  `POST /upload` probe, because those images would drop and reseed the table.
  If the exec itself fails, it exits 1.

It then probes through the Pod resolved by the `part-of=minishop` selector:

- `GET /items?q=` must return items. An empty list or 500 with `42P01` fails
  with a hint to seed through the chart seed Job; no POST is sent.
- Unless skipped, `POST /upload` must answer 404 and leave the item list
  unchanged.
- The reviews route must return reviews.

While the chart still pins a pre-#40 image (until the #40 pin PR is
deployed), expect the WARNING and `POST /upload probe skipped`; the script
still exits 0 when the read checks pass.

### Seeding an empty database

#40 removes `POST /upload` from the backend (Express answers 404). Seeding is
an opt-in chart Job, `seed.enabled` (default `false`), that runs `seed.js` from
the backend image. It creates `marketitems` only if missing, inserts the 100
items only into an empty table (one transaction under an advisory lock, with
`ON CONFLICT DO NOTHING`), and writes Redis keys with `SET NX`. It never drops,
truncates, or overwrites data. It does refill a deliberately emptied table, and
a rerun recreates any deliberately deleted Redis review key, because `SET NX`
writes every absent key. See
[ADR 0014](./decisions/0014-seed-job-replaces-upload.md).

Do not enable it while the chart pins `599480a8...`; that image has no
`seed.js`. After the pin PR that moves to a #40 image is deployed, and only for
an empty database, seed it as follows (`deploy-helm.sh` has no flag for it):

1. Edit `charts/minishop/values-dev.yaml` locally to add:

   ```yaml
   seed:
     enabled: true
   ```

   Helm merges this over `values.yaml`, so `seed.resources` keeps its
   defaults. Never commit this edit.
2. Back up first: `bash scripts/backup-data.sh` (from PR #54).
3. Deploy: `PATH="$PWD/.tools/bin:$PATH" bash scripts/deploy-helm.sh
   values-dev.yaml`.
4. Wait until the Job is Complete (this only reads the cluster):

   ```bash
   KUBECONFIG=./.kube/config kubectl --context kind-learn -n webapp \
     wait --for=condition=complete job -l app.kubernetes.io/component=seed \
     --timeout=900s
   KUBECONFIG=./.kube/config kubectl --context kind-learn -n webapp \
     get jobs,pods -l app.kubernetes.io/component=seed
   ```

5. Revert the edit (`git checkout -- charts/minishop/values-dev.yaml` in WSL)
   and deploy again with the same command. Helm then deletes the seed Job and
   NetworkPolicy `minishop-seed`.
6. Run `bash scripts/validate-app.sh`. Confirm `git status` shows no change to
   `values-dev.yaml`.

The Job name includes a pod-template hash, so a new image creates a new Job.
It retries up to `backoffLimit: 6` within `activeDeadlineSeconds: 900`; early
`ECONNREFUSED` failures are expected while the data services start. It is
deleted 24 h after finishing, and the next `helm upgrade` recreates it, which
is harmless because it is idempotent. NetworkPolicy `minishop-seed` allows its
egress only to PostgreSQL, Redis, and DNS.

The frontend root check is distinct from database-backed item behavior, so
inspect the response body as well as the status. The item route first returned
`28P01` (authentication failed), then `42P01` (table absent) after the owner
aligned the role password; it was seeded during Issue #36. See
[troubleshooting](./troubleshooting.md) and the
[Issue #36 record](./devlog/2026-11-02-minishop-item-seeding.md).

The backend image is pinned to
`sha256:599480a80f5fa26755cf368c0b13fdc9406580421477e8970981c39fc2f35114`
(tag `sha-3925f188dc5103386881ae7c7a64ac300d8d8f68`, built from #46). A pin
applies only after the cluster is deployed from `main` (`helm upgrade`). This
read-only command shows which digest the Deployment requests:

```bash
KUBECONFIG=./.kube/config kubectl --context kind-learn -n webapp   get deployment minishop-backend   -o 'jsonpath={.spec.template.spec.containers[0].image}'
```

On this image:

- `/items` and the reviews route return 503 when PostgreSQL or
  Redis is unreachable, refusing service, or timed out, and 500 for other
  failures, with JSON `{"error": "...", "code": "<SQLSTATE>"}` (`code` only for
  PostgreSQL errors). An unseeded table returns 500 with `42P01`, the only
  unseeded form. Reviews of an item with no
  reviews still return 200 with `{}`.
- `POST /upload` is still served: it is unauthenticated and drops the table
  first. The #40 backend removes it, but only after a pin PR deploys that
  image; until then `validate-app.sh` warns and skips its `/upload` probe.
- The liveness probe uses `GET /live` (process only) and the readiness probe
  uses `GET /ready` (PostgreSQL and Redis), in both the chart and the raw
  manifest. Probe timings are unchanged.
- Timeouts are set by `REDIS_CONNECT_TIMEOUT_MS`, `REDIS_COMMAND_TIMEOUT_MS`,
  `READINESS_TIMEOUT_MS` (default 2000 ms each) and `POSTGRES_QUERY_TIMEOUT`
  (default 5000 ms). `REDIS_COMMAND_TIMEOUT_MS` bounds all Redis commands of
  one request together, including the wait for a reply.
- A Redis or PostgreSQL outage makes every backend Pod unready, which also
  removes `/items`; liveness stays 200, so Pods are not restarted. In Docker
  tests `/ready` answered 503 in about 2 s and recovered about 1 s after the
  dependency returned. See
  [ADR 0010](./decisions/0010-backend-dependency-health.md) and the
  [Issue #47 record](./devlog/2026-11-08-health-image-pin.md).

Known gap: the pinned image still serves the unauthenticated, destructive
`POST /upload` until the #40 image is pinned and deployed.
The legacy frontend that overlapped the `minishop-frontend` selectors was
retired by the Issue #38 runbook.

## Monitoring

The `monitoring` Helm release (`kube-prometheus-stack-69.8.2`) runs Prometheus,
Grafana, Alertmanager, kube-state-metrics, and node-exporter. Prometheus scrapes
every `minishop-backend` Pod at `/metrics` through the `minishop-backend`
ServiceMonitor. None of these UIs has an Ingress, so reach them with a
port-forward. Run each command in its own WSL terminal from the repository root
and keep it running:

```bash
export KUBECONFIG=./.kube/config
kubectl --context kind-learn -n monitoring port-forward svc/monitoring-grafana 3000:80
kubectl --context kind-learn -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
kubectl --context kind-learn -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093
```

Then open Grafana at <http://127.0.0.1:3000>, Prometheus at
<http://127.0.0.1:9090>, and Alertmanager at <http://127.0.0.1:9093> from a
Windows browser.

Grafana's user is `admin`. Its password is in Secret
`monitoring/monitoring-grafana`. Read it only in your own terminal, and never
paste it into docs, Issues, or logs:

```bash
kubectl --context kind-learn -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Where to look:

- **Grafana → Dashboards → MiniShop Backend**: the MiniShop dashboard. It
  currently has one panel, backend CPU.
- **Kubernetes / Compute Resources / Namespace (Pods)**: CPU and memory per Pod.
  Choose `webapp` or `data`.
- **Node Exporter / Nodes**: load, memory, and disk for each kind node.
- **Prometheus → Graph**: the backend exports `http_request_duration_seconds`
  with `method` and `status_code` labels.

```promql
# Requests per second
sum(rate(http_request_duration_seconds_count{namespace="webapp"}[5m]))
# Requests per second by status code
sum by (status_code) (rate(http_request_duration_seconds_count{namespace="webapp"}[5m]))
# 95th percentile latency
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="webapp"}[5m])))
# Backend container restarts
kube_pod_container_status_restarts_total{namespace="webapp"}
```

The kubelet's `/ready` probe requests are counted as well. A `503` series
usually means a dependency was down, for example during a Docker restart.

**Alerts.** The MiniShop rules are `MiniShopBackendRestarting` and
`MiniShopBackendRestart`, in the `minishop-backend` and
`minishop-backend-restarts` PrometheusRules. These alerts are expected on this
cluster and are not MiniShop faults:

- `Watchdog` and `InfoInhibitor` always fire by design. They prove that the
  alert pipeline works.
- `KubeProxyDown` and `TargetDown` (kube-system) are kind false positives.
  kind binds kube-proxy's metrics endpoint to `127.0.0.1`, so Prometheus cannot
  scrape it. kube-proxy itself works.
- `CPUThrottlingHigh` in `monitoring` means some monitoring Pods reach their CPU
  limits. It is worth reviewing, but it is not an outage.

Known monitoring gaps:

- The MiniShop dashboard lacks request rate, error rate, latency, and readiness
  panels.
- The `monitoring/backend` ServiceMonitor still selects the legacy backend
  retired in Issue #38, so it matches nothing.
- The kind false positives above are not silenced.
- Alertmanager receivers have not been checked. Alerts may be visible only in
  its UI.

## Back up and restore data

Issue #40 part 1 added scripts that back up and restore the Helm-owned
`data/minishop-postgresql` and `data/minishop-redis`. They do not cover the
legacy CNPG cluster or the legacy `redis` StatefulSet; see
[runbook step 6](./legacy-retirement-runbook.md#step-6-back-up-legacy-data-no-deletion)
for those. Run them from WSL. The design is in
[ADR 0013](./decisions/0013-data-backup-restore.md) (proposed).

Back up kind-learn. This only reads from the cluster:

```bash
bash scripts/backup-data.sh --keep 7
```

- Source: context `kind-learn`, namespace `data`, by default. `--context`,
  `--kubeconfig`, `--namespace`, `--pg-pod`, and `--redis-pod` change it.
  `--docker --pg-container NAME --redis-container NAME` reads from Docker
  containers instead.
- It runs `pg_dump -Fc` and `redis-cli --rdb -` through `kubectl exec`. It
  checks the files from the chart's pinned images with `pg_restore --list`, a
  full read of the dump (`pg_restore -f /dev/null`; `--list` alone reads only
  the table of contents and passes a truncated dump), and `redis-check-rdb`.
  It fails if row counts, row digests, or the Redis key set change during the
  run.
- Location: `~/minishop-backups/<UTC stamp>/`, or `--backup-dir DIR` or
  `MINISHOP_BACKUP_DIR`. The directory must be outside the repository, owned
  by you, and mode 700, so Windows drives under `/mnt` are refused. Files are
  written with umask 077. Each set holds `postgresql.dump`, `redis.rdb`,
  `manifest.txt` (counts, digests, versions, images), and `SHA256SUMS`. The set
  is built as `.partial-<stamp>-<pid>` and renamed only after every check
  passes. `SHA256SUMS` catches corruption, not deliberate tampering: anyone who
  can write the set can rewrite it.
- Output: counts, sizes, and checksums only.
- `--keep N`: after a successful backup, delete all but the newest N complete
  sets, never the new one. A backup whose UTC stamp does not sort after the
  newest set (a clock that stepped back) is refused before it writes.

Restore into a target you name. There is no default target:

```bash
# A throwaway or rebuilt cluster:
bash scripts/restore-data.sh --from ~/minishop-backups/<stamp> \
  --kubeconfig <path> --context <context>
# Docker containers:
bash scripts/restore-data.sh --from ~/minishop-backups/<stamp> \
  --docker --pg-container <name> --redis-container <name>
```

- It checks `SHA256SUMS` first, restores PostgreSQL with a single-transaction
  `pg_restore --clean`, then loads Redis through a temporary replica source on
  `127.0.0.1:16379` inside the Redis container (`--restore-port PORT` moves
  it). Afterwards it checks counts and digests against the manifest.
  `--only postgresql|redis` restores one component.
- During the Redis step the target is a read-only replica for a few seconds,
  so backend writes fail briefly. The script retries `REPLICAOF NO ONE` until
  the target is master again, and says so on stderr if it never is.
- The backup holds no roles or passwords; the target keeps its own. Tables
  that exist only in the target are kept, with a warning. If one of them has a
  foreign key to a restored table, the restore fails and rolls back; drop or
  detach it first.
- **kind-learn rule:** unless `--allow-kind-learn` is given, restore refuses a
  context named `kind-learn`, one whose cluster is `kind-learn`, one whose API
  server URL matches cluster `kind-learn` in `./.kube/config`, and any target
  that has the node `learn-control-plane`. Pass the flag only when the owner
  has decided to roll the live data back.

Test the scripts and the backups. Both use throwaway containers with no
network and touch no cluster:

```bash
bash scripts/test-data-restore.sh                                  # self-test
bash scripts/test-data-restore.sh --from ~/minishop-backups/<stamp> # restore drill
```

Cadence (manual; there is no CronJob, see ADR 0013):

- Before any risky change: a cluster rebuild or kind upgrade, a Helm upgrade
  that touches the data templates, password rotation, a seeding change, a
  legacy retirement step, or a restore.
- Otherwise weekly while the cluster is in use, with `--keep 7`.
- A restore drill once a month.
- The self-test after any change to the scripts.

Known gaps: backups are unencrypted, there is one copy on the same machine,
and losing the WSL disk loses them. Failures and fixes are in
[troubleshooting](./troubleshooting.md); the drill is in the
[Issue #40 record](./devlog/2026-11-09-data-backup-restore.md).

## Scoped cleanup

Choose cleanup matching the active packaging path. These commands delete
MiniShop runtime resources and are state-changing:

```bash
bash scripts/teardown-helm.sh
bash scripts/teardown-kustomize-dev.sh
```

Run only the command for the runtime packaging path currently in use. Helm
uninstall and Kustomize teardown retain namespaces, credential Secrets, PVCs,
shared storage, and platform resources. They do not serve as a full cluster
reset. Never delete the `data` namespace, PVCs, or PVs for routine application
cleanup; doing so can destroy persistent data. Detailed preservation evidence
and safe recovery commands are in [resilience validation results](./validation-results.md).

## Further reading

- [Kustomize packaging decision](./decisions/0008-kustomize-packaging.md) and
  [implementation record](./devlog/2026-09-28-kustomize-packaging.md).
- [Helm packaging decision](./decisions/0009-helm-packaging.md) and
  [implementation record](./devlog/2026-09-28-helm-packaging.md).
- [Platform observability decision](./decisions/0007-platform-observability.md)
  and [implementation record](./devlog/2026-09-27-platform-rbac-scaling-observability.md).
- [Pod recovery and persistent data record](./devlog/2026-09-28-pod-recovery-data-persistence.md)
  and [validation results](./validation-results.md).
- [Data backup and restore decision](./decisions/0013-data-backup-restore.md)
  and [implementation record](./devlog/2026-11-09-data-backup-restore.md).
