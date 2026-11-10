---
title: Pin the seed-capable backend image
requirement: Issue #40 part 2 follow-up — pin the image built from #55 so the cluster can drop POST /upload and run the seed Job
status: verified
last_updated: 2026-11-10
date: 2026-11-10
issue: "#40"
pr: "not recorded"
tier: T1
reconstructed: false
source: "Recorded during implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# Pin the Seed-Capable Backend Image

## Goal
#55 removed `POST /upload` and added `seed.js`, but the repo publishes backend
images only on push to `main`, so #55 could not pin its own image. This change
pins the image built from merge commit `8ed5cfe` (#55).

## Changes
- Pins `sha256:b0c282b0eac6269fc7da0a4155fe1fd89f2e8073bf2da922e0460ed94a1937ac`
  (tag `sha-8ed5cfe4f7f0878b133fc9951907fe0d27d30343`, "Backend image" run
  42838469623) in `charts/minishop/values.yaml`,
  `manifests/20-webapp/backend.yaml` (image and provenance comment), and
  `deploy/30-platform/hpa-load-test.yaml`.
- The operator guide and troubleshooting now describe this pin. They keep the
  note that a cluster still running a pre-#40 image makes `validate-app.sh`
  warn and skip its `/upload` probe.
- `scripts/validate-app.sh` is unchanged. Its pre-#40 block list keeps
  `599480a8...`, and the new digest passes its `seed.js` check.

## Validation
- The workflow log `containerimage.digest` and
  `docker buildx imagetools inspect ...:sha-8ed5cfe...` both report
  `b0c282b0...`.
- In the pulled image, `/usr/src/app/seed.js` exists. `index.js` mentions
  `/upload` only in comments, with no route. The process runs as UID 1000. The
  `org.opencontainers.image.revision` label is `8ed5cfe4...`.
- `scripts/validate-helm.sh` passes. No YAML in `charts/`, `deploy/` or
  `manifests/` still references `599480a8`.

## Problems
None in this change.

## Follow-ups
Owner deploy:
1. Take a backup with `bash scripts/backup-data.sh`.
2. Deploy with `PATH="$PWD/.tools/bin:$PATH" bash scripts/deploy-helm.sh values-dev.yaml`.
3. Run `bash scripts/validate-app.sh`. It should send the probe and get 404.

The database is already seeded, so the seed Job stays off. Parts 3 and 4 of
#40 remain.
