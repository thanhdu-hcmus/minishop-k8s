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
- **The validator no longer seeds.** `validate-app.sh` asserts `POST /upload`
  answers 404 without changing items, but only when every backend container
  passes a positive check: its requested image and its running image ID are
  both anchored `ghcr.io/thanhdu-hcmus/minishop-backend@sha256:<64 hex>`
  references and it contains `/usr/src/app/seed.js`, which only #40 and later
  images ship. The
  four digests that pre-#40 publish runs produced (#24 `e87390d3...`, #43
  `44a87d71...`, #46 `599480a8...`, #48 `f10f726b...`, from `gh run list
  --workflow=backend-image.yml --branch main`) are a second guard only. Any
  other image fails the validator.

## Consequences
- The chart still pins `599480a8...`, which has no `seed.js` and still serves
  `/upload`. A follow-up pin PR is required before the seed can be enabled.
- **Interim window.** Between this merge and the deployed pin PR, the backend
  runs a pre-#40 image. `validate-app.sh` then prints a WARNING, skips only the
  `POST /upload` probe, still runs the items and reviews checks, and exits 0,
  so validation on `main` keeps passing. The 404 assertion only runs once the
  pin is deployed.
- After the 24 h TTL, the next `helm upgrade` reruns the Job; harmless because
  it is idempotent.
- A deliberately emptied table is reseeded if the Job runs, and a rerun
  recreates any deliberately deleted Redis review key (`SET NX` writes every
  absent key). Rows in a non-empty table are never added back.
- The Job uses the default ServiceAccount, without a token.
- A future `data`-namespace ingress policy must allow the seed Pod.

## References
- [Seed Job record](../devlog/2026-11-10-seed-job.md).
- [ADR 0010](./0010-backend-dependency-health.md).
