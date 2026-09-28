---
title: Kustomize packaging
requirement: Issue #28 — package MiniShop manifests with Kustomize
status: verified
last_updated: 2026-09-28
---

# Kustomize Packaging

## Goal
Record the T2 choice to package the existing MiniShop resources with a shared
Kustomize base and minimal environment overlays.

## Prerequisites
- [Issue #28](https://github.com/thanhdu-hcmus/minishop-k8s/issues/28).
- Existing canonical resources under `manifests/`.
- A local `kind-learn` cluster for the dev deployment path.

## Decision
Use a Kustomize base that references the existing storage, data, and webapp
manifests rather than duplicating them. The dev overlay sets backend/frontend
replicas to 1/1; the prod overlay sets them to 3/2. These overlays differ only
in those replica counts. The deployment script applies dev only; prod is
rendered and schema-validated, not deployed to the local cluster.

Permit explicit local source references outside `kustomize/base` with
`--load-restrictor LoadRestrictionsNone`; the base contains only repository
manifest references and no plugins or remote sources. Keep teardown scoped to
the app/data runtime objects so credentials, PVCs, namespaces, shared storage,
and platform resources remain in place.

## Rationale
Reusing the canonical manifests avoids multiple copies of the same Kubernetes
resource definitions. Overlays expose the requested environment replica targets
without changing the underlying application configuration. A separate,
explicit teardown bundle avoids deleting stateful data or shared platform
components during an application reset.

## Consequences
- The dev backend overlay asks for one replica, but the active platform HPA has
  a minimum of three and can raise the live replica count. The deploy script
  reports and waits for that minimum.
- Prod settings are configuration examples validated by rendering; no prod
  deployment was performed.
- Kind's `kindnet` CNI does not enforce NetworkPolicy, so policy objects alone
  do not prove denied traffic is blocked.
- Existing credential Secrets must be present, or both runtime password inputs
  must be supplied together before deployment.

## Verification
Dev and prod render to the same 25 resources as the base, with only the two
Deployment replica counts differing; kubeconform `v0.6.7` accepted both renders.
It accepted all 13 teardown objects as well. Dev deployment and scoped teardown
were exercised in `kind-learn`; credentials, PVCs, namespaces, shared storage,
and platform resources were preserved. PostgreSQL, Redis, frontend, and backend
became Ready. The HPA kept the backend at three replicas. Prod was not deployed.

## Related Docs
- [Kustomize packaging implementation record](../devlog/2026-09-28-kustomize-packaging.md)
- [Issue #28](https://github.com/thanhdu-hcmus/minishop-k8s/issues/28)
