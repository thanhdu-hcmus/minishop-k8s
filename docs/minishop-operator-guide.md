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

The chart pins a #40 image (`b0c282b0...`). Until a cluster is redeployed from
`main` it may still run a pre-#40 image; there, or mid-rollout, expect the
WARNING and `POST /upload probe skipped`. The script still exits 0 when the
read checks pass.

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

Enable it only after the cluster runs the #40 image (`b0c282b0...`, pinned by
the #40 pin PR); older images have no `seed.js`. Check the running digest with
the read-only command below. Only for an empty database, seed it as follows (`deploy-helm.sh` has no flag for it):

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
`sha256:b0c282b0eac6269fc7da0a4155fe1fd89f2e8073bf2da922e0460ed94a1937ac`
(tag `sha-8ed5cfe4f7f0878b133fc9951907fe0d27d30343`, built from #55, Issue
#40). The previous pin was `599480a8...` from #46. A pin
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
- `POST /upload` is removed and answers 404. The image ships `seed.js` for the
  opt-in seed Job. Pre-#40 images still serve the destructive route, so
  `validate-app.sh` warns and skips its `/upload` probe on them.
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

Known gap: until a cluster is redeployed with this pin, its running image
still serves the unauthenticated, destructive `POST /upload`.
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

## Centralized logging (ELK)

Issue #59 adds an ECK-managed logging stack in `manifests/40-logging/`:
one-node Elasticsearch 9.4.9, Kibana 9.4.9, and a Filebeat 9.4.9 DaemonSet in
namespace `logging`. The ECK 3.2.0 operator runs in `elastic-system`.
Prometheus and Grafana remain the metrics and alerting stack; Elasticsearch
holds logs only ([ADR 0017](./decisions/0017-eck-logging-stack.md),
[ADR 0007](./decisions/0007-platform-observability.md)). As of 2026-11-14 the
stack is **not deployed on kind-learn**; it was verified on a throwaway
cluster only.

**Prerequisites.** The ECK CRDs, the operator's cluster-wide RBAC, Filebeat's
ClusterRole, and Filebeat running as root with hostPath mounts all need the
owner's approval at deploy time. Check memory first and continue only with
about 6 GiB available in WSL:

```bash
free -m
```

The stack measured about 2.8-2.9 GiB (estimated for four nodes from a
three-node test), and `vm.max_map_count` must be at least 262144 on every
node (it is on kind-learn today).

**Deploy, in order,** from the repository root. Each step changes the
cluster:

```bash
bash scripts/deploy-eck.sh         # CRDs, RBAC, webhook (cluster-wide); operator manages only logging
bash scripts/deploy-logging.sh     # namespace, policies, Elasticsearch, ILM, Kibana, Filebeat
bash scripts/validate-logging.sh   # health, ILM, and a backend test line searchable
```

Then record the real usage:

```bash
export KUBECONFIG=./.kube/config
kubectl --context kind-learn top pods -n logging
kubectl --context kind-learn top pods -n elastic-system
kubectl --context kind-learn top nodes
free -m
```

**Kibana access.** There is no Ingress. Port-forward in its own terminal and
keep it running:

```bash
kubectl --context kind-learn -n logging port-forward service/logging-kb-http 5601
```

Open <https://localhost:5601>. ECK serves a self-signed certificate, so the
browser shows a certificate warning; accept it for `localhost` only.

The user is `elastic`. Its password is in Secret
`logging/logging-es-elastic-user`. Read it only in your own terminal, and
never paste it into docs, Issues, or logs:

```bash
kubectl --context kind-learn -n logging get secret logging-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d; echo
```

The scripts never read this Secret; they call the Elasticsearch API from
inside its container.

**Find logs.** Filebeat does not load Kibana dashboards. Once, create a data
view: **Stack Management → Data views → Create**, index pattern `filebeat-*`,
timestamp `@timestamp`. Then use **Discover**. Useful fields:

- `message`: the log line; for the backend, the pino `msg`.
- `log.level`: for the backend, the pino number mapped to a name (30 is
  `info`).
- `pino.*`: the backend's decoded JSON fields, such as `pino.name` and
  `pino.level`. Only Pods in `webapp` with
  `app.kubernetes.io/component=minishop-backend` are decoded.
- `kubernetes.*`: namespace, Pod, container, node, and labels, for example
  `kubernetes.namespace : "webapp"`.

**Retention.** ILM policy `minishop-logs` rolls an index over daily or at a
1gb primary shard and deletes it 3 days after rollover, so logs live about 4
days. Indices have 0 replicas. local-path does not enforce the 10Gi volume
size; the ILM delete phase is the bound.

**Validate** at any time with `bash scripts/validate-logging.sh`
(`--timeout SECONDS`, default 180, for the test line).

**Memory budget.** Measured on the throwaway cluster (run 7): Elasticsearch
1608 MiB, Kibana 946 MiB, Filebeat 49-76 MiB per Pod, operator 37 MiB.
Requests add about 1000m CPU and 4.2Gi memory; limits add about 5.7Gi. Real
numbers on kind-learn are not recorded yet.

**Teardown.** This deletes every stored log; MiniShop namespaces are not
touched:

```bash
bash scripts/teardown-logging.sh                    # lists what would go; changes nothing
bash scripts/teardown-logging.sh --yes              # remove the stack, keep ECK
bash scripts/teardown-logging.sh --yes --remove-eck # also remove the operator and CRDs
```

`--remove-eck` refuses while any resource of any `*.k8s.elastic.co` CRD
exists outside `logging`, and the script stops before changing anything if
it cannot list the CRDs or their resources.
Filebeat's registry stays on each node at
`/var/lib/logging/filebeat/filebeat-data`. Problems are in
[troubleshooting](./troubleshooting.md); the full record is the
[ECK logging devlog](./devlog/2026-11-14-elk-logging.md).

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

## Rotate data passwords

Issue #40 part 3 added `scripts/rotate-data-credentials.sh`. It rotates the
PostgreSQL role `minishop` and the Redis password, and updates both Secrets,
`data/minishop-data-credentials` and `webapp/minishop-app-credentials` (keys
`postgres-password` and `redis-password`), together. The design is in
[ADR 0015](./decisions/0015-data-credential-rotation.md) (proposed). It does
not touch the legacy `webapp/postgres-app-creds`, `data/postgres-creds`, or
the CNPG cluster `minishop-postgres`; those go away at
[runbook step 6](./legacy-retirement-runbook.md).

Run it from WSL on an up-to-date `main` (a stale checkout has already once
redeployed an old image):

```bash
bash scripts/backup-data.sh                                    # 1. fresh backup
bash scripts/rotate-data-credentials.sh --context kind-learn   # 2. dry run; review the plan
bash scripts/rotate-data-credentials.sh --context kind-learn --apply   # 3. rotate
bash scripts/validate-app.sh                                   # 4. check the app
```

- The default is a dry run; only `--apply` changes anything. `--context` is
  required; there is no default. `--only postgresql|redis` rotates one
  component; the default rotates both.
- Order: `ALTER ROLE` (over the container's trusted local socket, with
  statement logging off for that session), the data Secret, the app Secret, a
  rolling restart of the Redis StatefulSet, a rolling restart of the backend,
  then verification. The PostgreSQL StatefulSet is not restarted.
- Expect failed requests from `ALTER ROLE` until the backend rollout
  completes, measured at ~39 s in the self-test (2 backend replicas; kind-learn
  runs at least 3, so expect longer). Old backend Pods cannot open new
  connections and go NotReady once Redis restarts; requests on pooled
  PostgreSQL connections keep working. The script prints the measured window
  as `client window:`. This is an owner decision; there are no dual roles.
- `--apply` holds a lock on `<state-dir>/.lock` (default
  `~/.local/state/minishop-rotation`), so only one rotation or recovery runs
  at a time. A Secret changed by someone else after the checks makes the
  patch fail with 409 Conflict, and the script rolls back.
- Verification: the new passwords log in, the old ones are rejected, the Redis
  keys without a TTL are unchanged, and every new backend Pod answers 200 on
  `/ready`, `/items` and `/items/<i>/reviews`.
- Passwords are 64 hex characters. They pass only through stdin and mode-600
  `mktemp` files and are never printed.
- Pre-flight refusals: no `--context`; no backup of the same target in the last
  24 hours (`--skip-backup-check` overrides); the two Secrets disagree; the
  current password does not log in; the backend is unhealthy; a running Job
  reads the Secrets. See [troubleshooting](./troubleshooting.md).
- On failure it rolls back automatically and prints the state of each
  component. If the rollback also fails it prints `!!! ROLLBACK INCOMPLETE.`
  and a `--recover DIR --to old|new` command; run it, and re-run it until it
  succeeds.
- Afterwards, update or discard any stored `MINISHOP_*_PASSWORD` values.
  Re-running `scripts/create-{data,app}-credentials.sh` with old values, either
  directly, through `deploy-data.sh`, or through `deploy-kustomize-dev.sh` with
  the password variables set, reverts the rotation. `helm upgrade` does not:
  the chart only references the Secrets by name.

Test the script on a throwaway kind cluster (`minishop-rotation-test`, deleted
on exit); it never touches kind-learn:

```bash
bash scripts/test-data-rotation.sh
```

The run is in the [rotation record](./devlog/2026-11-10-credential-rotation.md).

## Data network policy

The chart renders NetworkPolicies `minishop-postgresql` and `minishop-redis`
in `data` ([ADR 0016](./decisions/0016-data-tier-network-policy.md)). They
admit TCP 5432 / 6379 only from Pods in `webapp` labelled
`app.kubernetes.io/component=minishop-backend, app.kubernetes.io/name=minishop,
app.kubernetes.io/part-of=minishop` (plus the seed Job while `seed.enabled`), and deny all egress from the two
data Pods. The legacy `redis-0` and CNPG Pods are not selected. There is no
toggle.

Deploy from an up-to-date `main` (adds the two policies; no Pod restarts):

```bash
PATH="$PWD/.tools/bin:$PATH" bash scripts/deploy-helm.sh values-dev.yaml
```

Verify:

```bash
bash scripts/validate-app.sh
KUBECONFIG=./.kube/config kubectl --context kind-learn -n data get networkpolicy
```

Optional proof from the legacy `redis-0`, which has no backend labels. It
connects before the deploy (`rc=0`) and times out after (`rc=124`):

```bash
pg_ip=$(KUBECONFIG=./.kube/config kubectl --context kind-learn -n data \
  get pod minishop-postgresql-0 -o jsonpath='{.status.podIP}')
KUBECONFIG=./.kube/config kubectl --context kind-learn -n data exec redis-0 -c redis -- \
  timeout 4 bash -c "exec 3<>/dev/tcp/$pg_ip/5432"; echo "rc=$?"
```

Optionally run `bash scripts/backup-data.sh --context <ctx>` to confirm the
data tools still work; they use `kubectl exec` and are not affected.

Roll back with `helm rollback minishop <previous revision> -n webapp`, or
delete the two policies in `data`.

Test on a throwaway kind cluster (`minishop-netpol-test`, deleted on exit):

```bash
bash scripts/test-data-network-policy.sh
```

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
