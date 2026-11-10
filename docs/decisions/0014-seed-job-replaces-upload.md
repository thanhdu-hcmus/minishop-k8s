---
title: Seed Job replaces POST /upload
requirement: Issue #40 — protect seeding (part 2 of 4)
status: proposed
last_updated: 2026-11-10
---

# Seed Job Replaces POST /upload

## Goal
Record the T2 decision on how MiniShop seeds its demo data once the
unauthenticated, destructive `POST /upload` route is gone. Status is proposed;
the owner accepts it on merge.

## Prerequisites
- [Issue #40](https://github.com/thanhdu-hcmus/minishop-k8s/issues/40).
- Before #40, `POST /upload` dropped and recreated `marketitems` and rewrote
  the Redis keys, with no authentication.

## Decision
- **Remove `/upload`, do not protect it.** Owner decision. The route and the
  `importData` functions are deleted, so Express answers 404. Removal over a
  token or a 410 stub: no destructive code path remains and there is no flag
  or token to misconfigure. A unit test asserts POST, GET and PUT `/upload`
  return 404.
- **Seed with a non-destructive command.** `images/backend/seed.js` calls
  `seedData` in `app/postgresql.js` and `app/redis.js`. PostgreSQL work runs in
  one transaction under an advisory lock: create the table only if missing and
  insert only when it is empty, with `ON CONFLICT DO NOTHING`. Redis uses
  `SET NX`. It exits 1 on failure. The data equals the old `/upload` output.
- **Run it as an opt-in chart Job.** Owner decision. `seed.enabled: false` by
  default; `templates/seed-job.yaml` adds the Job and NetworkPolicy
  `minishop-seed` (egress only to PostgreSQL, Redis and DNS). Default renders
  are byte-identical to before.
- **A plain Job, not a Helm hook**, because it:
  - stays in the release manifest and is removed when disabled;
  - never blocks `helm --wait`;
  - retries until the data services answer.
  The Job name includes a pod-template hash, so a new image creates a new Job
  instead of failing on the immutable pod template.
- **Job settings:** `restartPolicy: Never`, `backoffLimit: 6`,
  `activeDeadlineSeconds: 900`, `ttlSecondsAfterFinished: 86400`; non-root
  UID 1000, read-only root filesystem, all capabilities dropped,
  `RuntimeDefault` seccomp, `automountServiceAccountToken: false`; requests
  50m/64Mi, limits 250m/128Mi; credentials from the existing app Secret via
  `secretKeyRef`.
- **The validator no longer seeds.** `validate-app.sh` asserts `/upload` is
  disabled and refuses to run against the three published digests that still
  serve it.

## Consequences
- The chart still pins `599480a8...`, which has no `seed.js` and still serves
  `/upload`. A follow-up pin PR is required before the seed can be enabled or
  `validate-app.sh` can pass.
- After the 24 h TTL, the next `helm upgrade` reruns the Job; harmless because
  it is idempotent.
- A deliberately emptied table is reseeded if the Job runs.
- The Job uses the default ServiceAccount, without a token.
- A future `data`-namespace ingress policy must allow the seed Pod.

## References
- [Seed Job record](../devlog/2026-11-10-seed-job.md).
- [ADR 0010](./0010-backend-dependency-health.md).
