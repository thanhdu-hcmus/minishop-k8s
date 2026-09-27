---
title: Runtime data foundation
requirement: Issue #17 — persistent PostgreSQL and Redis foundation
status: verified
last_updated: 2026-09-27
---

# Runtime Data Foundation

## Goal
Record the T2 decision to provide persistent, internal PostgreSQL and Redis
services for the MiniShop learning cluster.

## Prerequisites
- [Issue #17](https://github.com/thanhdu-hcmus/minishop-k8s/issues/17).
- The `standard` StorageClass from the local storage foundation.

## Decision
Run one PostgreSQL StatefulSet and one Redis StatefulSet in the `data`
namespace. Each workload has a governing headless Service and a stable
cluster-internal Service, and each uses an explicitly named `standard` PVC.

Pin PostgreSQL 16.10 Bookworm and Redis 7.4.7 Bookworm to the Docker Official
Image digests recorded in their manifests. PostgreSQL stores its database under
`PGDATA`; Redis enables AOF with `appendfsync everysec`. Runtime passwords are
created from required environment inputs by a local script and are not tracked
in repository files.

## Rationale
The design gives later application slices stable in-cluster connection points
and restart-persistent local storage while preserving a small, inspectable
learning topology. Digest-pinned images and resource, probe, and security
settings make the runtime dependencies explicit.

## Consequences
- PostgreSQL and Redis are single replicas backed by node-local storage; this
  is not a high-availability design.
- Services are internal only; TLS, NetworkPolicies, backup/restore, and
  application integration remain future work.
- Deployers must supply both required passwords at runtime before creating the
  credential Secret.

## Verification
Client dry-run accepted the runtime manifests. Kind validation observed bound
PVCs using `standard`, ready Pods, authenticated PostgreSQL and Redis checks,
and persistence after controlled Pod restarts. Temporary validation records
were removed afterward without displaying credential values.

## Related Docs
- [Runtime data foundation devlog](../devlog/2026-09-27-runtime-data-foundation.md)
- [Local storage foundation decision](0003-local-storage-foundation.md)
