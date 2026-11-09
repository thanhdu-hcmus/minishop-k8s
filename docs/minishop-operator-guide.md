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
they do not install or upgrade workloads. `bash scripts/validate-app.sh` is only
conditionally read-only. It probes through the Pod resolved by the
`part-of=minishop` selector and checks `GET /items?q=`:

- Items present: it skips `POST /upload`, then checks the reviews route.
- Empty list or PostgreSQL code `42P01`: it calls `POST /upload`, which drops
  and recreates the table, then rechecks both routes.
- Any other response: it fails without uploading.

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

- `/items`, the reviews route, and `POST /upload` return 503 when PostgreSQL or
  Redis is unreachable, refusing service, or timed out, and 500 for other
  failures, with JSON `{"error": "...", "code": "<SQLSTATE>"}` (`code` only for
  PostgreSQL errors). An unseeded table returns 500 with `42P01`, the only
  unseeded form `validate-app.sh` accepts; the 200-with-`42P01` form of older
  images now fails the validator without uploading. Reviews of an item with no
  reviews still return 200 with `{}`.
- `POST /upload` returns 200 and loads 100 rows and 100 Redis keys; a repeat
  upload stays at 100 rows. It is unauthenticated and drops the table first.
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

Known gaps: the `minishop-frontend` Service and Deployment selectors still
overlap legacy frontend Pods, and `POST /upload` is unauthenticated and drops the
table when called.

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
