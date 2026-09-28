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

## Deployment choices

Use one runtime packaging path at a time. The Helm chart and the Kustomize
overlay describe the same app/data runtime; do not apply both over one another.
Both expect namespaces `data` and `webapp`, the two MiniShop credential Secret
objects and the `webapp/minishop-backend` ServiceAccount. The Helm deployment
script additionally requires the platform backend HPA with `minReplicas` of at
least three; Kustomize deploy does not require that HPA. When installed, the
platform HPA can raise the dev overlay/chart request of one backend replica to
its minimum. Kustomize dev also brings in the shared local-path storage
resources. The local cluster described here already has the external platform
and runtime prerequisites. For the component-level setup and migration
boundary, see [Helm packaging](./decisions/0009-helm-packaging.md) and
[Kustomize packaging](./decisions/0008-kustomize-packaging.md).

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
cluster-internal, so this read-only local inspection command briefly opens a
local port-forward; stop it with Ctrl-C when finished, then browse to
`http://127.0.0.1:8080`:

```bash
KUBECONFIG=./.kube/config kubectl --context kind-learn -n webapp \
  port-forward service/minishop-frontend 8080:8080
```

The port-forward is temporary and does not create a Kubernetes resource. The
Kind host-port mappings for 80/443 do not by themselves provide an Ingress
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
they do not install or upgrade workloads. `bash scripts/validate-app.sh` is not
read-only: it submits an application record as part of its end-to-end check.
Consult the script before running any validation that writes application data.

The frontend root check is distinct from database-backed item behavior. The
last scoped validation observed `GET /` returning HTTP 200, while
`GET /items?q=` returned HTTP 200 with PostgreSQL error code `28P01`, not item
data. This credential mismatch is unresolved. See
[troubleshooting](./troubleshooting.md) and [resilience validation results](./validation-results.md);
do not treat the item route as passing data-path validation or change
credentials as part of routine inspection.

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
- [Platform RBAC, scaling, and observability record](./devlog/2026-09-27-platform-rbac-scaling-observability.md).
- [Pod recovery and persistent data record](./devlog/2026-09-28-pod-recovery-data-persistence.md)
  and [validation results](./validation-results.md).
