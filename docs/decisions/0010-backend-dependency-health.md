---
title: Backend dependency health
requirement: Issue #39 — return non-2xx on dependency errors, add readiness, keep liveness process-only
status: proposed
last_updated: 2026-11-07
---

# Backend Dependency Health

## Goal
Record the T2 decision on how the backend reports PostgreSQL and Redis failures
to clients and to Kubernetes. Status is proposed; the owner accepts it on merge.

## Prerequisites
- [Issue #39](https://github.com/thanhdu-hcmus/minishop-k8s/issues/39).
- The backend image source in `images/backend/` and the backend probes in
  `charts/minishop` and `manifests/20-webapp/backend.yaml`.

## Decision
- **Liveness is process-only.** `GET /live` answers 200 without touching any
  dependency. A PostgreSQL or Redis outage must never restart backends.
- **Readiness is dependency-aware.** `GET /ready` returns 200 only when
  PostgreSQL `SELECT 1` and Redis `PING` both succeed within
  `READINESS_TIMEOUT_MS` (default 2000 ms), otherwise 503 with per-dependency
  checks.
- **503 versus 500.** A request that fails because a dependency is unreachable or
  refusing service (network errors, timeouts, PostgreSQL SQLSTATE classes `08`
  and `28`, `53300`, `57P01`-`57P03`, Redis connection errors and refusal
  replies such as `WRONGPASS`) returns 503. Any other failure, such as a missing
  table (`42P01`), returns 500. The JSON body carries a fixed message and, for
  PostgreSQL server errors only, the SQLSTATE; never the error text.
- **Bounded waits.** Each request opens its own Redis client, with no reconnect
  and no offline queue. It must connect within `REDIS_CONNECT_TIMEOUT_MS` and
  finish all of its commands, including the wait for each reply, within
  `REDIS_COMMAND_TIMEOUT_MS` (2000 ms each by default). The application enforces
  the reply bound and then destroys the client, because node-redis 6.2.1 times a
  command only while it waits in the client queue. The client socket is closed
  with `destroy()` on every path, never `quit()`. PostgreSQL queries time out at
  5000 ms. The idle pool error is logged instead of exiting the process.
- **Unchanged contract.** An item with no reviews still returns 200 with `{}`,
  as before #39; the pinned frontend shows an endless spinner on a non-2xx.
- **Rollout order.** The probes switch to `/live` and `/ready` only together with
  the pin of an image that serves them. Issue #47 shipped both in one change:
  digest `sha256:599480a8...5114` (built from #46) and the probe paths in the
  chart and the raw manifest.

## Rationale
Restarting every replica because a shared dependency is down does not repair the
dependency and loses in-flight work, as the exit on idle pool errors showed.
Readiness takes Pods out of the Service instead. Separating 503 from 500 lets
clients and validators tell a transient outage from a code or data fault, and
bounded waits keep failures inside client and probe timeouts (a Redis host that
stopped resolving previously took 64-67 s).

## Consequences
- Readiness needs both dependencies, so a Redis outage makes every backend Pod
  unready and also removes `GET /items`, which only needs PostgreSQL. This
  trade-off was accepted for a simple, single readiness signal.
- Each request and each readiness check opens its own Redis connection.
- No SIGTERM handling and no startupProbe were added.
- None of this takes effect in the cluster until the new image is published,
  pinned, and deployed.

## Verification
Unit and route tests passed (50 of 50), and the image was exercised against
throwaway PostgreSQL and Redis containers in Docker; cluster behavior was not
tested. Details are in the implementation record.

## Related Docs
- [Backend failure handling record](../devlog/2026-11-07-backend-failure-handling.md)
- [Backend image publishing decision](0005-backend-image-publishing.md)
- [Issue #39](https://github.com/thanhdu-hcmus/minishop-k8s/issues/39)
