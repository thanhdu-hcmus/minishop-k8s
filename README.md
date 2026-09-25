# MiniShop Kubernetes learning platform

MiniShop runs on a local WSL2 Kind cluster and demonstrates application deployment, stateful dependencies, ingress, scaling, RBAC, MetalLB, and Prometheus-based observability.

## Quick start

1. Optionally export `POSTGRES_PASSWORD` before the first deployment to choose the database password. If it is unset, deployment generates one for the initial runtime Secrets. A local `.env` is optional and is not sourced by the scripts.
2. Run `./scripts/setup.sh`, `./scripts/provision.sh`, and `./scripts/deploy.sh` from WSL2.
3. Run `./scripts/provision-observability.sh`, configure `METALLB_ADDRESS_POOL`, and run `./scripts/configure-metallb.sh`.
4. Add `127.0.0.1 minishop.local` to the Windows hosts file from an elevated PowerShell session, then browse to `http://minishop.local`.

The scripts set `KUBECONFIG=./.kube/config` and target context `kind-learn`. See [the runtime runbook](docs/runtime-validation.md) for exact prerequisites, validation evidence, and troubleshooting.

## Packaging

Run `./scripts/validate.sh` to render Kustomize overlays and lint/template the Helm chart. The raw manifests remain the primary learning artifacts; the Helm chart and Kustomize overlays package equivalent resources for comparison.

## Documentation

See [the documentation index](docs/README.md).
