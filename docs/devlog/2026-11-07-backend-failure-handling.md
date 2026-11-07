---
title: Backend failure handling and dependency-aware readiness
requirement: Issue #39 — return non-2xx on PostgreSQL and Redis errors, add readiness, keep liveness process-only
status: verified
last_updated: 2026-11-07
date: 2026-11-07
issue: "#39"
pr: "not recorded"
tier: T2
reconstructed: false
source: "Recorded during implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# Backend Failure Handling and Dependency-Aware Readiness

## Goal
Stop the backend exiting on idle PostgreSQL pool errors, return non-2xx
responses on dependency failures, bound the Redis wait, and split liveness from
a dependency-aware readiness check.

## Changes
All changes are in the backend image source and `scripts/validate-app.sh`. No
chart, Kustomize, or raw manifest file changed on this branch.

- **Idle pool errors** (`app/postgresql.js`): `pool.on("error")` now logs
  `idle postgresql client error; the pool discarded it` instead of calling
  `process.exit(-1)`. `pool` is exported for the regression test.
- **Error responses** (`index.js`): `GET /items`, `GET /items/:id/reviews`, and
  `POST /upload` catch every failure and return JSON `{ "error": "<message>" }`,
  plus `"code"` only when the error is a PostgreSQL server error (its SQLSTATE,
  for example `42P01`). The error text and stack are never returned. Status is
  503 when the dependency is unreachable or refusing service, otherwise 500.
- **Classification** (new `app/dependency.js`, `isDependencyUnavailable`): 503
  for network codes (`ECONNREFUSED`, `ECONNRESET`, `ENOTFOUND`, `EAI_AGAIN`,
  `ETIMEDOUT`, `EHOSTUNREACH`, `ENETUNREACH`, `EPIPE`), PostgreSQL SQLSTATE
  classes `08` and `28`, `53300`, and `57P01`-`57P03`, pg connection-failure
  messages, node-redis connection and timeout error classes, Redis replies
  `WRONGPASS`, `NOAUTH`, `LOADING`, `MASTERDOWN`, `BUSY`, and the new
  `DependencyTimeoutError`. Nested `errors` and `cause` are checked.
- **Reviews of a missing item:** unchanged from `origin/main`: 200 with `{}`.
  `redis.search` now resolves `null` for a missing key and the route answers
  `{}` explicitly (see Problems for the reverted 404).
- **Redis bounds** (`app/redis.js`): `reconnectStrategy: false`,
  `disableOfflineQueue: true`, and `connectTimeout` from
  `REDIS_CONNECT_TIMEOUT_MS` (default 2000 ms), plus a deadline around
  `connect()` that also covers DNS and the AUTH handshake. `withClient` bounds
  all commands of one request together, including the wait for each reply, by
  `REDIS_COMMAND_TIMEOUT_MS` (default 2000 ms; the readiness timeout for
  `/ready`), and destroys the client when that expires. It closes the socket
  with `destroy()` on every path instead of `quit()`. node-redis's own
  `commandOptions.timeout` is still set but covers only queue time. A new client
  is still opened per request.
- **PostgreSQL bounds:** `query_timeout` from `POSTGRES_QUERY_TIMEOUT` (default
  5000 ms); the logging DNS lookup in `search` is bounded by the connection
  timeout. Timeout env values that are not positive integers fall back to the
  default.
- **New routes:** `GET /live` returns 200 `{ "status": "ok" }` without touching
  any dependency. `GET /ready` runs PostgreSQL `SELECT 1` and Redis `PING` in
  parallel, each bounded by `READINESS_TIMEOUT_MS` (default 2000), and returns
  200 or 503 with `{ status, checks: { postgresql, redis } }`.
- **`addOffer`:** no longer indexes past the result when `TOTAL_OFFER` exceeds it.
- **Validator** (`scripts/validate-app.sh`): treats 500 with `42P01` as unseeded,
  and still accepts the old image's 200 with `42P01`.
- **Tests:** new `dependency`, `health`, `postgresql-pool`, `readiness-bounds`,
  `redis-bounds`, `redis-replies`, and `routes` test files, a fake RESP server
  in `test/fake-redis.js`, and new cases in `redis-options` and `redis-import`.
- **Provenance:** `index.js` and `app/postgresql.js` carry a "Derived from ...
  Modified for ..." header like `app/redis.js`, and `images/backend/UPSTREAM.md`
  lists the modifications per file.
- **Probes not switched:** the chart and manifests still probe `/` for both
  liveness and readiness. The intended change, made and validated during
  implementation but not on this branch, is: in
  `charts/minishop/templates/backend.yaml` and
  `manifests/20-webapp/backend.yaml`, liveness `httpGet.path` `/` to `/live`
  and readiness `httpGet.path` `/` to `/ready`, with timings unchanged. It was
  held back because the pinned and deployed image `sha256:44a87d71...` returns
  404 on `/live` and `/ready`, so probing them before the new image is deployed
  would restart every backend.

## Problems

### Pool regression test needed the pool exported
- **Symptom:** The idle pool `error` handler was private to `app/postgresql.js`.
- **Fix:** Export `pool`; the new test emits `error` on it with `process.exit` mocked.
- **Verified by:** Against the old handler the test failed (`exit` called once,
  expected 0); with the fix all 12 tests passed.

### Redis bound test hung the run against the old client
- **Symptom:** Running the new `redis-bounds.test.js` against the pre-fix
  `app/redis.js` never finished; the throwaway test container had to be stopped
  after 3 minutes.
- **Cause:** With no connect deadline, the old client waits forever on a server
  that accepts TCP but never replies, and the tests had no per-test timeout.
- **Fix:** Each bound test now has a 10 s test timeout, and the before-fix run
  used `--test-force-exit`.
- **Verified by:** Before the fix 5 of 7 Redis tests failed: closed port (error
  wrapped, no `ECONNREFUSED` code), silent server (timed out after 10000 ms),
  unresolvable host (5783 ms, bound 1500 ms), and the two options tests. After
  the fix all 24 tests passed.

### Probe comment exceeded the YAML line length
- **Symptom:** yamllint 1.35.1 failed `manifests/20-webapp/backend.yaml:93`
  (82 > 80 characters).
- **Fix:** Shortened the probe comment before committing.
- **Verified by:** yamllint passed on the manifest and `.github`. This applied to
  the probe change described under Changes, which is not on this branch; the
  manifest on this branch is unchanged.

### Redis readiness failed while only PostgreSQL was stopped
- **Symptom:** In the Docker failure tests, `GET /ready` reported
  `redis: unavailable` (node-redis `Connection timeout`) right after a
  `GET /items` with PostgreSQL stopped. `/ready` alone reported only PostgreSQL.
- **Cause:** A stopped container's name takes 5007 ms to fail (`EAI_AGAIN`) on
  Docker's embedded DNS. Each lookup holds a libuv threadpool thread (4 by
  default) after the request deadline gives up on it, so the Redis lookup queued
  past its 2000 ms connect timeout.
- **Tried:** With `UV_THREADPOOL_SIZE=16` the same sequence reported only
  PostgreSQL, which confirmed the cause.
- **Fix:** None. The Pod is unready either way, because readiness needs both
  dependencies; only the per-dependency detail is wrong, and every request
  stayed within about 2 s. In the cluster both data Services are headless and
  CoreDNS answers `cluster.local` itself, so a stopped Pod should not cause slow
  lookups (inferred, not tested).
- **Verified by:** Reproduced in two runs at the default size of 4, after one
  and after two parallel `GET /items`; absent in one run at 16.

### PostgreSQL stop after the upload started missed the 50 ms import
- **Symptom:** Stopping PostgreSQL 40 to 150 ms after `POST /upload` started
  returned 200 three times; the import takes about 50 ms.
- **Fix:** Issued `docker stop` first and the upload 0 to 200 ms later.
- **Verified by:** All five returned 503 (SQLSTATE 57P01 at 0 ms, 57P03 at
  20 ms, connection timeout at 100 and 200 ms), the backend kept running, and
  the table kept 100 rows each time.

### Written Redis commands had no reply bound (review blocker)
- **Symptom:** Review found that a Redis server which completes the handshake
  and then never answers left `GET` or `PING` pending forever, and a stalled
  `QUIT` added 2 s and left the socket open.
- **Cause:** node-redis 6.2.1 applies `commandOptions.timeout` only while a
  command waits in its queue; it removes the timer once the command is written.
  `quit()` marks the client closed before its reply arrives, so the fallback
  `destroy()` threw `ClientClosedError`, which was swallowed, and the socket
  stayed open.
- **Fix:** `withClient` puts a deadline of `REDIS_COMMAND_TIMEOUT_MS` (or the
  readiness timeout) on the whole callback and destroys the client on expiry;
  every path closes with `destroy()`, and `quit()` is no longer used.
- **Verified by:** New `redis-replies.test.js` uses a fake RESP server that
  answers the handshake but never `GET`, `PING`, `SET`, or `QUIT`; four of its
  five tests failed against the previous client and all pass now. The
  reviewer's probe, run against the fix with 200 ms bounds: `GET` never
  answered rejected with `DependencyTimeoutError` after 244 ms, `PING` after
  223 ms, and the server saw the socket close 5 and 4 ms later; with `QUIT`
  stalled, `search` resolved in 19 ms and the socket closed at once. On the
  rebuilt image, Redis reported `connected_clients:1` (only `redis-cli`) after
  the success path and after Redis was paused and unpaused.

### Missing-item reviews changed to 404 (review finding)
- **Symptom:** The first implementation returned 404 for an item without a
  reviews key. Review noted this was outside #39 and that the pinned frontend
  shows an error with an endless spinner on a non-2xx.
- **Fix:** Restored the previous response. Running `origin/main` at 8b4bffd
  with a missing key returned `200 application/json; charset=utf-8 "{}"`; the
  route now returns exactly that, and the test asserts status, content type,
  and body.
- **Verified by:** `routes.test.js` passes, and the rebuilt image answered
  `GET /items/99999/reviews` with 200 `{}`.

## Verification
- Coordinator re-run on 4f4bd95, before the review fixes: `npm test` 45 of 45 in
  the `node:22.16.0` container, `validate-kustomize.sh` and `validate-helm.sh`
  passed, and `git diff --check` was clean.
- Final re-run after the review fixes: `npm ci` and `npm test` on a clean export
  of every code commit in `node:22.16.0-alpine3.21` (Dockerfile digest), ending
  at 50 of 50, with `git diff --check` clean per commit. The Dockerfile `test`
  stage, built from `git archive HEAD`, also passed 50 of 50.
- `scripts/validate-kustomize.sh` and `scripts/validate-helm.sh` passed.
  yamllint 1.35.1 passed on `manifests/20-webapp/backend.yaml` and `.github`;
  kubeconform v0.6.7 passed on the manifest. These first ran with the probe
  change in place, when the renders contained `/live` and `/ready`. In the
  final re-run on this branch, where the chart and manifests match `origin/main`
  and probe `/`, `validate-kustomize.sh`, `validate-helm.sh`, yamllint, and
  kubeconform passed again and `git diff --check` was clean.
- shellcheck v0.10.0 and `bash -n` passed on `scripts/validate-app.sh`, and its
  embedded probe parses with `node --check`.
- The image was rebuilt from the final code commit and run against throwaway
  PostgreSQL, Redis, and frontend containers on a private Docker network, with
  the chart's env names and security settings. Results (the first run, before
  the review fixes, matched within 0.1 s except where noted):

| Case | Request | Result |
| --- | --- | --- |
| Unseeded | `GET /items`, direct and through the frontend | 500 `42P01`, 6 and 19 ms |
| Success | `POST /upload` | 200, 50 ms, 100 rows |
| Success | `/items`, reviews (through the frontend), `/ready` | 200 |
| Success | reviews for item 99999 | 200 `{}` (first run: 404, since reverted) |
| Success | Redis `connected_clients` after the requests | 1 (only `redis-cli`) |
| PostgreSQL stopped after use (3 trials) | backend after 15 s | running, 0 restarts; idle pool error logged 3 times |
| PostgreSQL stopped | `GET /items` | 503, 1.96 to 2.04 s |
| PostgreSQL stopped | `/ready`; `/live` | 503, 2.0 s; 200, 1 ms |
| PostgreSQL started | `/ready` back to 200 | within 0.16 s of PostgreSQL accepting queries |
| PostgreSQL stopped as upload starts (5 runs) | `POST /upload` | 503 in 8 ms to 2.06 s (57P01, 57P03, timeouts); 100 rows kept |
| Redis stopped (name does not resolve) | reviews; `POST /upload` | 503, 2.01 s; 503, 2.02 s |
| Redis stopped | `/ready`; `/live`; `GET /items` | 503, 2.02 s; 200; 200 |
| Redis started | `/ready` back to 200 | 0.01 s after Redis answered |
| Redis paused (no replies) | reviews; `/ready` | 503, 2.05 s each; 1 Redis client after unpause |
| PostgreSQL paused (no replies) | `GET /items`; `/ready` | 503, 5.09 s (query timeout); 503, 2.04 s |
| Closed ports | `/items`, reviews, upload, `/ready` | 503 in 3 to 32 ms; `/live` 200 |
| Wrong passwords | `/items` (`28P01`), reviews, upload, `/ready` | 503 in 4 to 32 ms; `/live` 200 |

- Before this change, Redis stopped took 64 to 67 s and wrong Redis password
  5928 ms (from the #44 devlog). No backend restarted or exited in any case, and
  neither throwaway password appeared in the backend logs.
- The pinned image `sha256:44a87d71...` answers 404 on `/live` and `/ready`.
- All test containers and the network were removed. No cluster change was made,
  so `scripts/validate-app.sh` and the cluster validators were not run.

## Decisions
- The image digest pin is unchanged, as the Issue comment asks. The probes stay
  on `/`, because the pinned image answers 404 on `/live` and `/ready`; the probe
  switch ships with the follow-up pin. See
  [ADR 0010](../decisions/0010-backend-dependency-health.md) for liveness,
  readiness, status classification, and timeouts.

## Follow-up
- Publish the image and pin the new digest in a follow-up PR (Issue #39 comment),
  together with the probe change described under Changes: liveness `/` to
  `/live` and readiness `/` to `/ready` in `charts/minishop/templates/backend.yaml`
  and `manifests/20-webapp/backend.yaml`.
- None of these fixes reach the cluster until that image is deployed.
- Open gaps: a new Redis connection per request and per readiness check; a Redis
  outage makes every Pod unready, which also removes `/items`; no SIGTERM
  handling; no startupProbe; `/ready` can name Redis when only PostgreSQL is down
  under slow DNS (Docker only).
- After the pin, drop the old 200-with-`42P01` form from `scripts/validate-app.sh`.
