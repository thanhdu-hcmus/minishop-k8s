---
title: Application workload and network boundary
requirement: Issue #20 — MiniShop application workloads and internal network boundary
status: verified
last_updated: 2026-09-27
---

# Application Workload and Network Boundary

## Goal
Record the T2 design for deploying the MiniShop frontend and backend in the
`webapp` namespace and limiting their network paths to required peers.

## Prerequisites
- [Issue #20](https://github.com/thanhdu-hcmus/minishop-k8s/issues/20).
- The runtime services and credential contract in
  [Runtime data foundation](0004-runtime-data-foundation.md).
- The source-derived backend image and provenance in
  [Backend image publishing](0005-backend-image-publishing.md).

## Decision
Deploy one frontend and one backend replica with Services in `webapp`, using
the immutable image digests recorded in their manifests. Create a separate
`minishop-app-credentials` Secret in `webapp` from the same two operator-supplied
password inputs used by the data layer; do not read the data namespace Secret
or store credential values in repository files.

Apply a default-deny ingress and egress policy to MiniShop pods. Allow frontend
egress to the backend, backend ingress only from the frontend, backend egress to
PostgreSQL and Redis in `data`, and DNS egress to CoreDNS. Do not add an ingress
controller, RBAC, autoscaling, observability, Kustomize, Helm, or data-layer
changes in this slice.

## Rationale
Namespace-local credentials respect Kubernetes Secret namespace boundaries.
Explicit peer and port rules make the intended application traffic inspectable
without broadening the application to external ingress. Digest references make
the deployed images immutable and connect the manifests to recorded provenance.

## Consequences
- Both application workloads are single replicas; this is a learning topology,
  not a high-availability design.
- Kubernetes NetworkPolicy enforcement depends on the cluster network plugin.
  The tested local Kind `kindnet` setup did not enforce the policies, so a
  successful policy-object apply is not evidence that denied traffic is blocked.
- Deployers must create the `webapp` namespace and app Secret before deploying
  the workloads; scripts consume runtime environment variables without
  displaying them.

## Verification
Static manifest and shell checks passed; Kubernetes server-side dry-run admitted
all eight resources. In-cluster rollouts reached 1/1 Ready, and the validation
script exercised frontend-to-backend-to-data connectivity. The clean denied-path
probe still reached the backend under the active `kindnet` CNI; policy
enforcement therefore remains unverified on this cluster.

## Related Docs
- [Application network boundary devlog](../devlog/2026-09-27-application-network-boundary.md)
- [Runtime data foundation](0004-runtime-data-foundation.md)
- [Backend image publishing](0005-backend-image-publishing.md)
