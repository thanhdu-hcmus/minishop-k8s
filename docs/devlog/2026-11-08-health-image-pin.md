---
title: Pin the dependency-health backend image and switch probes
requirement: Issue #47 — pin the image built from #46 and probe /live and /ready in the same change
status: verified
last_updated: 2026-11-08
date: 2026-11-08
issue: "#47"
pr: "not recorded"
tier: T1
reconstructed: false
source: "Recorded during implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# Pin the Dependency-Health Backend Image and Switch Probes

## Goal
Deploy the #39 failure handling by pinning the image built from merge commit
`3925f18` (#46) and moving the backend probes to its health routes. The old
image answers 404 on `/live` and `/ready`, so the pin and the probe switch ship
together.

## Changes
- `fb082bf` pins `sha256:599480a80f5fa26755cf368c0b13fdc9406580421477e8970981c39fc2f35114`
  (tag `sha-3925f188dc5103386881ae7c7a64ac300d8d8f68`) in
  `charts/minishop/values.yaml`, `manifests/20-webapp/backend.yaml` (image and
  provenance comment), and `deploy/30-platform/hpa-load-test.yaml`.
- `40a0d01` sets liveness to `/live` and readiness to `/ready` in
  `charts/minishop/templates/backend.yaml` and the raw manifest. Timings are
  unchanged.
- `c4d6ff9` makes `scripts/validate-app.sh` accept only the 500-with-`42P01`
  form as unseeded; the old 200 form now fails closed instead of triggering
  `POST /upload`.
- `257b8cc` adds a "Runtime notes" heading to `images/backend/UPSTREAM.md`
  (the formatting Nit from #46).

## Decisions
- Probe contract and rollout order follow
  [ADR 0010](../decisions/0010-backend-dependency-health.md).
- The 200 form was removed because the new pin no longer produces it.

## Problems and fixes
- The first runtime test read the backend's published port as empty and hit an
  nginx 404 on port 80. Fixed by calling the backend from a client container on
  the same Docker network. Test harness only; no product defect.

## Verification
Docker only, pinned image, throwaway PostgreSQL and Redis:

| Case | Result |
|---|---|
| Healthy | `/ready` 200 in 0.083 s, `/live` 200 |
| Redis stopped | `/ready` 503 in about 2.06 s naming redis, `/live` 200 |
| PostgreSQL stopped | `/ready` 503 in 2.1 s naming postgresql, `/items` 503 in 2.04 s |
| Redis or PostgreSQL paused | `/ready` 503 in about 2.06 s |
| Recovery | about 1 s |
| Unseeded `/items` | 500 with `42P01`; 100 items after upload |

Container restarts: 0. Helm/Kustomize render and repo validator output were not
passed to doc-writer in detail; the implementation report states all commits
validate.

## Deployment
No cluster change in this PR. The cluster must be deployed from `main`
(`helm upgrade`) after merge for the pin and probes to apply; before that it
runs `sha256:44a87d71...`, which fails the new probes with 404.

## Follow-ups
- Post-deploy cluster check of `/live`, `/ready`, and `validate-app.sh`: not
  recorded yet.
- `POST /upload` remains unauthenticated; frontend selector overlap remains.
