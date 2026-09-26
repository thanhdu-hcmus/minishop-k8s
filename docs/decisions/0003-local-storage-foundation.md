---
title: Local storage foundation
requirement: Issue #15 — local storage foundation
status: verified
last_updated: 2026-09-27
---

# Local Storage Foundation

## Goal
Record the T2 decision to provide dynamic, node-local persistent-volume
provisioning for MiniShop's local Kind cluster.

## Prerequisites
- [Issue #15](https://github.com/thanhdu-hcmus/minishop-k8s/issues/15).
- A working `kind-learn` cluster and its repository-local kubeconfig.

## Decision
Deploy the Rancher local-path provisioner at release `v0.0.32`. Keep
`standard` as the cluster's only default `StorageClass`; retain `local-path`
as a non-default class. Both classes use `rancher.io/local-path`,
`WaitForFirstConsumer`, and a `Delete` reclaim policy.

The provisioner runs as one replica in `local-path-storage`. Its controller
has bounded CPU and memory resources, and its helper image is pinned to
`busybox:1.36.1`.

## Rationale
The configuration gives a PVC without `storageClassName` a deterministic
default while preserving an explicit non-default option. Delayed volume
binding allows Kubernetes to select a consumer node before provisioning the
node-local volume.

## Consequences
- Storage is local to the selected Kind node and uses a `Delete` reclaim
  policy.
- The provisioner is a single replica.
- The upstream manifest does not include an application health endpoint.

## Verification
The implementation validated all ten manifest resources with a Kubernetes
client dry-run and kubeconform, observed the provisioner rollout, and
completed an isolated PVC-and-Pod mount test. The temporary
`minishop-storage-e2e-15` namespace was deleted; a final check found no
remaining test namespace.

## Related Docs
- [Storage foundation devlog](../devlog/2026-09-27-local-storage-foundation.md)
- [Git workflow](../process/git-workflow.md)
