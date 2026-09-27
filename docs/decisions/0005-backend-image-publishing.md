---
title: Source-derived backend image publishing
requirement: Issue #21 — Redis-authenticated MiniShop backend image
status: verified
last_updated: 2026-09-27
---

# Source-Derived Backend Image Publishing

## Goal
Record the T2 decision to build a MiniShop backend image from tracked,
attributed source and to publish it only after a protected `main` push.

## Prerequisites
- [Issue #21](https://github.com/thanhdu-hcmus/minishop-k8s/issues/21).
- The Apache-2.0 upstream source revision recorded in
  `images/backend/UPSTREAM.md`.
- GitHub Container Registry package permission for the protected-main workflow.

## Decision
Track an Apache-2.0-derived backend source from
`kumahq/kuma-demo` commit
`db9e13301b4936fd9aa47521db79cc6b7ee8e169`. The backend accepts an
optional `REDIS_PASSWORD`; an absent or empty value preserves its
no-password Redis connection behavior.

Build from the tracked lockfile with `npm ci` and the pinned Node runtime
image. Pull requests validate the test image without publishing. A protected
`main` push alone may publish the GHCR discovery tag
`sha-<commit>` and record the resulting immutable digest. Only the publish
job receives `packages: write`.

## Rationale
The current declarative Redis service requires authentication, while the
legacy local backend does not provide a password setting. A source-derived
variant closes that compatibility gap without changing the legacy
no-password behavior. Build provenance, exact dependencies, and digest
pinning make the later application deployment reproducible.

## Consequences
- Later workload manifests must use the published immutable digest, not the
  discovery tag.
- The first GHCR package defaults to private. Its owner must explicitly set
  package visibility after the first publication; this workflow does not
  change visibility.
- This decision publishes no package from pull requests and does not deploy
  the backend. Application manifests, data integration, and NetworkPolicies
  remain outside this Issue.

## Verification
The source-derived build completed `npm ci`, backend tests, and an audit
reporting zero known vulnerabilities. The Docker test and runtime targets,
workflow lint, YAML parse, and whitespace checks passed. On pull requests,
the publishing job is skipped by design.

## Related Docs
- [Backend image devlog](../devlog/2026-09-27-backend-image.md)
- [Runtime data foundation decision](0004-runtime-data-foundation.md)
