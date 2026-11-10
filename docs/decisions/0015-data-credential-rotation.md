---
title: Data credential rotation
requirement: Issue #40 — rotate data passwords (part 3 of 4)
status: proposed
last_updated: 2026-11-10
---

# Data Credential Rotation

## Goal
Record the T2 decision on how MiniShop rotates the PostgreSQL and Redis
passwords so the role and both Secrets change together. Status is proposed;
the owner accepts it on merge.

## Prerequisites
- [Issue #40](https://github.com/thanhdu-hcmus/minishop-k8s/issues/40).
- Parts 1 (backup and restore, [ADR 0013](./0013-data-backup-restore.md)) and
  2 (seed Job, [ADR 0014](./0014-seed-job-replaces-upload.md)) are merged.
- The passwords live in `data/minishop-data-credentials` and
  `webapp/minishop-app-credentials` (keys `postgres-password`,
  `redis-password`), created by `scripts/create-{data,app}-credentials.sh`.
  The Helm chart only references them by name.

## Decision
- **Accept an authentication gap instead of dual roles.** Owner decision.
  `scripts/rotate-data-credentials.sh` changes one role, `minishop`, in place.
  From `ALTER ROLE` until the backend rollout completes, old backend Pods
  cannot open new connections, and once Redis restarts they fail readiness
  and go NotReady. The self-test measured this window at ~39 s (38.8 s, 2
  backend replicas on a one-node kind cluster); the script prints it on every
  run. Requests on pooled PostgreSQL connections kept working (0 of 137
  `/items` probes failed), while requests that open a new Redis connection
  failed (60 of 137 `/items/0/reviews` probes). Dual or alternating roles are
  not used; the reasoning behind the owner's choice is not recorded.
- **Order:** `ALTER ROLE`, data Secret, app Secret, rolling restart of the
  Redis StatefulSet, rolling restart of the backend, then verification. Redis
  restarts before the backend so new backend Pods only become ready once Redis
  accepts the new password. Failed steps are undone in reverse order; if that
  fails, `--recover DIR --to old|new` converges idempotently.
- **PostgreSQL is not restarted.** `ALTER ROLE` runs over the container's
  trusted local socket with session statement logging off, so it needs no
  current password and the password never reaches the server log. The
  StatefulSet's `POSTGRES_PASSWORD` only initialises an empty volume, and its
  probes use the trusted socket.
- **Redis is restarted, not reconfigured.** `requirepass` comes from
  `$REDIS_PASSWORD` at start, and the probes and backup scripts read the same
  variable. `CONFIG SET requirepass` was rejected because it would leave those
  on the old value. AOF keeps the data; the script checks the key set.
- **Legacy Secrets are scoped out.** `webapp/postgres-app-creds`,
  `data/postgres-creds`, and the CNPG cluster `minishop-postgres` (database
  `kumademo`) are a different server and role, and they are retired at
  [runbook step 6](../legacy-retirement-runbook.md).
- **Safe by default:** dry run unless `--apply`; `--context` required; refuses
  without a backup of the same target in the last 24 hours, when the Secrets
  disagree, when the current password fails, when an old value is not 16 or
  more base64-alphabet characters (it could not be pasted back on rollback),
  when the backend is unhealthy, or while a Job reads the Secrets.
- **Concurrency:** `--apply` takes a lock on `<state-dir>/.lock`, and each
  Secret patch carries the `resourceVersion` read during the checks, so a
  concurrent change fails with 409 Conflict and triggers the rollback. The
  patches also remove the `last-applied-configuration` annotation, which kept
  a copy of the old value.

## Consequences
- A rotation causes failed requests from `ALTER ROLE` until the backend
  rollout completes, measured at ~39 s in the self-test. It grows with the
  number of backend replicas and their readiness time: kind-learn runs at
  least 3.
- Possible follow-up, not implemented: Redis can accept several passwords at
  once (`ACL SETUSER default >new`, sent over stdin). A later version could
  add the new Redis password, roll the backend, then restart Redis with only
  the new one, which would remove the Redis part of the window. PostgreSQL
  would still need dual roles to do the same, and the owner decided against
  them.
- Re-running `create-{data,app}-credentials.sh` with old values (directly,
  via `deploy-data.sh`, or via `deploy-kustomize-dev.sh` with the password
  variables set) reverts the Secrets but not the role. The script warns about
  this; stored `MINISHOP_*_PASSWORD` values must be updated or discarded.
- The legacy Secrets stay unrotated until runbook step 6.
- If the rollback fails, the old and new passwords stay on disk (mode 600)
  until `--recover` finishes.

## References
- [Rotation record](../devlog/2026-11-10-credential-rotation.md).
- [Operator guide: rotate data passwords](../minishop-operator-guide.md#rotate-data-passwords).
