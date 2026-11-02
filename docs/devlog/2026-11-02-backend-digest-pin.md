---
title: Backend digest pin and pre-deploy upload test
requirement: Issue #44 — pin the fixed image digest and close Issue #36 leftovers
status: verified
last_updated: 2026-11-02
date: 2026-11-02
issue: "#44"
pr: "not recorded"
tier: T1
reconstructed: false
source: "Throwaway container runs from this implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# Backend Digest Pin and Pre-Deploy Upload Test

## Goal
Pin `sha256:44a87d71dda575c0e062e1474eafbe5885169aeb0ce4c123b81f2b497dd1d7af`
and test `POST /upload` on that image before any cluster deploy.

## Changes
The digest was replaced in `charts/minishop/values.yaml`,
`manifests/20-webapp/backend.yaml`, and `deploy/30-platform/hpa-load-test.yaml`.
The manifest provenance comment now names the published tag, because "built by
Issue #21" no longer described this image.

## Problems

### Backend exits when PostgreSQL stops with an idle pooled client
- **Symptom:** After a successful `POST /upload`, stopping PostgreSQL made the
  backend container exit with code 255. The next request found no backend.
- **Cause:** `images/backend/app/postgresql.js` calls `process.exit(-1)` in
  `pool.on("error")`. A released client stays idle in the pool for 10 seconds
  (`idleTimeoutMillis`), and its dropped connection reaches that handler. The
  #43 listener covers only a client checked out by an import.
- **Tried:** Stopping PostgreSQL after one upload, after two uploads, and after
  `GET /items`; all exited, so this is not specific to upload. Stopping it 12
  seconds after the last use, or during an import, did not exit.
- **Fix:** None in this change. The original "without crashing the process"
  criterion was not met, so testing stopped and the case went up for a decision
  instead of being worked around. Acting on the owner's instruction to proceed
  with its recommendations, the main session kept this pin unchanged. The handler
  is identical at f1d65e9, so this is not a regression. Issue #44's criterion now
  covers failures during an upload and excludes this exit, which moved to #39.
- **Verified by:** Six of six polled trials exited with code 255 and logged
  `error on postgresql pool`, 2.5 to 3.5 seconds after the stop returned. Two
  more trials had exited when read 1 and 2 seconds after the stop. Two other
  2-second readings showed "running"; those trials were not polled further.

### Redis stopped returns 500 only after about a minute
- **Symptom:** The first run's 45-second client timeout fired before a response.
- **Cause:** Likely DNS. A stopped container's name stops resolving, and the
  client makes 11 connection attempts. One failed lookup took 5.8 s on the
  internal network; the per-attempt time was not measured.
- **Fix:** None in this change. The response is correct and the process stays
  alive. Bounding the wait is tracked in #39.
- **Verified by:** A 200-second timeout returned 500 after 67 s on an internal
  Docker network and 64 s on a user bridge. With the host resolving and the port
  closed, 500 came back in 74 ms.

## Verification
- `scripts/validate-kustomize.sh` and `scripts/validate-helm.sh` exited 0.
- yamllint 1.35.1 and kubeconform v0.6.7 passed on the changed YAML.
- Helm (default, dev, prod) and Kustomize (dev, prod, dev teardown) each render
  the new digest once and the old digest zero times.
- `scripts/validate.sh` does not exist, and the cluster validators were not run
  because this Issue makes no cluster change.
- The pinned image ran against throwaway PostgreSQL and Redis containers, using
  the chart's env names and security settings. `POST /upload` returned 200 and
  wrote 100 `marketitems` rows and 100 Redis keys.
- A dependency failure returned 500 and the process stayed alive in each of
  these cases: PostgreSQL stopped with no idle client, PostgreSQL stopped during
  an upload, Redis stopped, either port closed, and either password wrong. The
  mid-upload case kept the 100 rows through rollback.

## Follow-up
- #39 covers the idle pooled client exit, the Redis wait, and a later image and
  digest pin. Until then this image can still exit if PostgreSQL stops within
  about 10 seconds of its last use.
- The owner deploys, or authorizes deploying, after merge.
