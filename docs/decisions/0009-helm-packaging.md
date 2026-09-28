---
title: Helm packaging
requirement: Issue #30 — package the MiniShop runtime with Helm
status: verified
last_updated: 2026-09-28
---

# Helm Packaging

## Goal
Record the T2 decision to package the MiniShop data and application runtime as
a Helm chart while keeping platform and persistent prerequisites outside the
release.

## Prerequisites
- [Issue #30](https://github.com/thanhdu-hcmus/minishop-k8s/issues/30).
- Namespaces `data` and `webapp`, their existing credential Secrets, and the
  backend ServiceAccount.
- The `standard` StorageClass and the existing platform HPA and observability
  resources.
- Docker, kubectl, and readable cluster configuration; Helm 3.17.3 is run from
  the pinned `alpine/helm:3.17.3` container rather than requiring a host Helm
  installation.

## Decision
Package the PostgreSQL and Redis Services/StatefulSets and the backend and
frontend Services/Deployments and NetworkPolicies in `charts/minishop`. Pin all
four images by digest and keep resource requests and limits consistent with the
canonical manifests. Provide default, dev, and prod values; dev sets backend and
frontend replicas to 1/1, and prod sets them to 3/2.

Keep namespaces, credential Secrets, the backend ServiceAccount, persistent
storage, the platform HPA, RBAC, and monitoring outside the chart. The migration
path removes only the prior Kustomize runtime objects before Helm installation;
the chart uninstall retains stateful data and external prerequisites.

## Rationale
Helm provides a release-managed package for the runtime without duplicating
operator-owned prerequisites or taking ownership of shared platform resources.
Digest-pinned images and constrained values make chart rendering reproducible;
the narrow migration and teardown paths preserve existing data and platform
state.

## Consequences
- The deploy path requires the existing namespaces, Secrets, ServiceAccount,
  and platform HPA; it does not create or modify those prerequisites.
- The platform HPA has a minimum of three backend replicas and may override the
  dev chart's requested backend replica count of one.
- `kindnet` in the tested Kind cluster does not enforce NetworkPolicy, so
  successful policy application is not evidence of denied-path enforcement.
- The host does not need a Helm binary; chart commands use the pinned Helm
  container and mount the cluster configuration read-only.

## Verification
Helm lint and render passed for default, dev, and prod values. Kubeconform
`v0.6.7` accepted the rendered resources, and chart output matched canonical
manifests except for the approved replica differences. Runtime validation
verified the scoped Kustomize-to-Helm handoff, Helm install, uninstall, and
reinstall, workload rollouts, and frontend POST/GET end-to-end behavior. The
final release was deployed; the backend HPA remained at its minimum of three
ready replicas. All five PVC/PV bindings and the namespaces, Secret objects,
storage, platform resources, legacy workloads, and local-path provisioner were
preserved.

## Related Docs
- [Helm packaging implementation record](../devlog/2026-09-28-helm-packaging.md)
- [Kustomize packaging decision](0008-kustomize-packaging.md)
- [Issue #30](https://github.com/thanhdu-hcmus/minishop-k8s/issues/30)
