# ADR 0001: Repository-only learning artifacts and local runtime configuration

## Decision

The initial delivery wrote repository artifacts only. That boundary was superseded after WSL2, Docker, Kubernetes, and Kind became available: the Bash scripts now provision and validate the local `kind-learn` cluster. `scripts/setup.sh` is a preflight that checks Docker, kind, kubectl, and Helm; it does not install or upgrade them.

Database credentials are supplied from a local, ignored `.env` file. `.env.example` is committed with a placeholder only. `scripts/create-runtime-config.ps1` creates the runtime Secrets and schema ConfigMap with `kubectl`; no Secret manifest or password is committed.

The learning persona is a ServiceAccount named `developer`. It has separate namespace-scoped Roles and RoleBindings in `webapp` and `data`, with `get`, `list`, and `watch` only. Secrets are deliberately excluded. The learning check must use `kubectl auth can-i --as=system:serviceaccount:<namespace>:developer` in each namespace.

The Kuma source is pinned at db9e13301b4936fd9aa47521db79cc6b7ee8e169. The three retained Kuma runtime images are pinned by manifest digest. The final active path deploys CNPG and Redis first; it does not teach a disposable intermediate database because that would duplicate lifecycle state and obscure the final dependency contract.

## Consequences

- Static validation renders Kustomize overlays and lints/templates the Helm chart. `yamllint` runs only when installed; it was unavailable during the verified run.
- The WSL2 runtime path has been validated for core workload readiness, persistence, dependency readiness, HPA, RBAC, ingress, MetalLB, Grafana, and Alertmanager. See [the runtime runbook](../runtime-validation.md) for evidence and the unverified browser GUI interaction.
- CNPG receives a basic-auth Secret in data; the app receives a separate password-only Secret in webapp, because Kubernetes Secrets are namespace-scoped.
- The database node is intentionally a single failure domain. Two CNPG instances demonstrate replication, not host-level HA.
- The immutable upstream backend has no HTTP health endpoints. TCP probes establish process availability; Postgres and Redis sidecars control aggregate Pod readiness. This is a Kubernetes-only compatibility pattern, not a replacement for application-level health checks.
- The log-shipper concept is not active: the upstream binary writes stdout and exposes no shared log path without rebuilding it.
- Chaos, VPA, NetworkPolicy, simulated cluster autoscaling, and an orders endpoint are inactive stretch exercises under `stretch/`. Each requires an explicit opt-in and its documented prerequisite.
