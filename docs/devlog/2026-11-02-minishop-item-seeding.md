---
title: MiniShop item seeding and validator targeting repair
requirement: Issue #36 — restore MiniShop item reads
status: verified
last_updated: 2026-11-02
date: 2026-11-02
issue: "#36"
pr: "not recorded"
tier: T2
reconstructed: false
source: "Owner-approved scope brief and runtime evidence from this implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# MiniShop Item Seeding and Validator Targeting Repair

## Goal
Make `GET /items?q=` and the reviews route return data on the MiniShop stack,
make `POST /upload` fail honestly, and make validation prove the MiniShop Pods
rather than the legacy Pods that share their labels.

## Scope
The Issue text on GitHub is stale and could not be updated. The owner directly
approved widening it to the end-to-end item fix, including the interim seed.

## Key Concepts
| Concept | Plain-language explanation |
|---|---|
| Selector overlap | A Service or Deployment selects every Pod whose labels match, so two workloads with shared labels can receive each other's traffic. |
| Fire-and-forget | A function starts asynchronous work and returns before it ends, so its caller cannot see failures. |
| Interim seed | A one-time data load into the running cluster, used because the fixed image is not yet published. |

## Implementation Walkthrough
1. Added regression tests first and confirmed they failed on the unfixed code.
2. `images/backend/app/redis.js` now writes string keys.
3. `images/backend/app/postgresql.js` `importData` returns a promise, awaits
   parameterized inserts one at a time inside the transaction, and rethrows the
   original error after rollback. If rollback fails, the pool discards the
   connection. A client `error` listener stays attached for the whole import
   and is removed before release.
4. `images/backend/index.js` awaits both imports in a `try`/`catch`, returns 500
   on failure, and listens only when run as the entry point so tests can load it.
5. `scripts/validate-app.sh` resolves the Pod with the three-label selector,
   limited to `status.phase=Running` so a Failed or Evicted Pod is not selected. It
   skips `POST /upload` when items exist and fails, without uploading, on any
   response other than an empty list or `42P01`. It also checks the reviews route.
   The `kubectl wait` on that selector exits at once if no Pod is Running, rather
   than waiting out its 180-second timeout: the filter leaves nothing to wait for,
   so the validator stops there.
6. The operator guide port-forward now targets the resolved Pod, using the same
   `Running` filter.
7. Seeded the running cluster once from a MiniShop backend Pod, using a script
   that was not committed.

## Problems encountered
### Item route failed after the password was aligned
- **Symptom:** With the role password aligned by the owner, `GET /items?q=`
  returned HTTP 200 with error code `42P01`, and the reviews route returned an
  empty object. The MiniShop database had no `marketitems` table and MiniShop
  Redis had 0 keys.
- **Cause:** The data was never seeded. `redis.js` passed numeric keys, which
  redis 6.2.1 rejects with a `TypeError`. `/upload` awaits Redis first, so
  PostgreSQL never ran and the rejection went unhandled in Express 4.
- **What was tried:** The failure was reproduced earlier with the pinned image
  against a throwaway Redis. The new `redis-import` test reproduced the same
  error message with a fake client that mirrors the argument check.
- **Fix:** Convert keys with `String(item.index)`.
- **Verification:** The regression test failed before the fix and passed after.

### PostgreSQL import could not report failure
- **Symptom:** `/upload` could report success with no table written.
- **Cause:** `importData` was fire-and-forget, inserts were not awaited, its
  catch block referenced an undefined `err`, and an outer `.catch` swallowed
  failures.
- **What was tried:** Added tests that assert ordering and the error path; they
  failed on the unfixed code.
- **Fix:** See walkthrough steps 3 and 4.
- **Verification:** The tests cover commit ordering, rollback, connection
  release, a failing rollback, and a 500 from `/upload` for each failing import.

### Validator was testing the legacy stack
- **Symptom:** `kubectl exec deployment/minishop-frontend` landed on legacy Pod
  `frontend-85c5567878-ws7q9`.
- **Cause:** The `minishop-frontend` Deployment and Service selectors use only
  `component=frontend` and `name=minishop`, which legacy frontend Pods also
  carry. Service endpoints still list both legacy Pods and the MiniShop Pod.
- **What was tried:** Compared Pod labels and Service endpoints; only
  `part-of=minishop` separates the two.
- **Fix:** Resolve the Pod by all three labels in the validator and operator
  guide. The shared selectors are unchanged; see Follow-ups.
- **Verification:** The validator printed
  `minishop-frontend-75c5d596b5-z8972` and passed. The "validate-app passed"
  records in [2026-09-27-application-network-boundary](./2026-09-27-application-network-boundary.md)
  and [2026-09-28-kustomize-packaging](./2026-09-28-kustomize-packaging.md)
  predate this finding and may have tested the legacy stack. That is unconfirmed,
  and those records are left unchanged.

### Validator could destroy existing data
- **Symptom:** The validator always called `POST /upload`, which drops and
  recreates the table.
- **Cause:** The probe seeded unconditionally.
- **What was tried:** Ran the extracted probe against a fake server for seven
  responses, because only one branch can be reached safely on the live cluster.
- **Fix:** Upload only for an empty list or `42P01`.
- **Verification:** All seven scenarios passed. The upload ran only for an
  absent or empty table, including the scenario where it returned 500, and not
  for populated items, `28P01`, or a 502.

### Shell variables were expanded before reaching bash
- **Symptom:** A first probe through `wsl.exe ... bash -lc '...'` reported
  `context "kind-learn" does not exist` and an empty Pod name.
- **Cause:** `wsl.exe` expanded `$` expressions in an outer shell, before the
  inner script exported `KUBECONFIG` or assigned its variables.
- **What was tried:** The failed command made no change.
- **Fix:** Moved commands containing `$` into script files and ran those.
- **Verification:** The script ran and returned the expected Pod name.

### PostgreSQL password did not follow the Secret
- **Symptom:** `GET /items?q=` returned `28P01` before the password was aligned.
- **Cause:** The password was persisted in the PVC, so Secret changes did not
  apply to the existing role.
- **What was tried:** Not recorded.
- **Fix:** The owner aligned the role password; the exact steps are not recorded.
- **Verification:** The route moved from `28P01` to `42P01`, then returned 100
  items after the seed.

### First test-stage build did not finish
- **Symptom:** A `docker build --target test` run on the unfixed code produced no
  output for more than 180 seconds and was stopped.
- **Cause:** Partly determined; this corrects the "determined cause" wording of
  commit `9be34c2`. Why the build never finished has a supported explanation. Why
  it printed nothing was not determined.
  - **Hang (reproduced, but not in the original build):** The HEAD
    `upload.test.js` fails against the unfixed `index.js`, then never exits. That
    `index.js` exports nothing, so each test fails with
    `app.listen is not a function`, and its top-level `app.listen` keeps
    `node --test` alive.
  - **Silence (not determined):** The reproduction ran one test file outside
    `docker build`, and it reported three test failures. So it shows a hang with
    results, not the original total silence. No later run tested `docker build`
    output on the unfixed code, and the build's own log is not recorded.
- **What was tried:** First, each test file ran separately with a hard timeout in
  the dependencies-stage image, and all were recorded as finished. The timeout
  tool, its duration, the exit codes, and the file versions were not recorded.
  Later, the HEAD `upload.test.js` ran against the `index.js` from before
  `dfd8c86`. A first attempt used the image's busybox `timeout`, whose exit 1 did
  not show whether the run had ended on its own. Timed from the host instead, all
  three tests failed and the run was still alive when killed at 40 seconds.
- **Conflict between those two results:** The first says `upload.test.js`
  finished, and the second says it did not exit. The record cannot show why. The
  busybox result shows that a hard timeout alone cannot separate a run that ended
  from one that was stopped, so "finished" may have meant only that the timeout
  returned; that is not confirmed. `dfd8c86` added `upload.test.js`, so no earlier
  commit shows which version the first run used. The host-timed run is the stronger
  evidence, because it directly observed the process alive.
- **Fix:** The `require.main` guard in `index.js` removes the listener that kept
  the reproduction alive, because loading the module no longer opens one. No
  separate fix was made for the silence. The guard arrived with the other `dfd8c86`
  changes, so its effect on the original build was not isolated.
- **Verification:** The same build later exited 0 with 9 of 9 tests passing on the
  fixed code. The 180-second build itself was not re-run.

### Dropped connection during import crashed the backend
- **Symptom:** Review found that a fake PostgreSQL server dropping the socket on
  the first `INSERT` made the process exit 1 with `Connection terminated
  unexpectedly`, and `POST /upload` sent no response.
- **Cause:** `pg-pool` removes its idle `error` listener at checkout and restores
  it at release. During the import the client had no listener, so the `error`
  event was unhandled.
- **What was tried:** Confirmed the checkout and release lines in the installed
  `pg-pool` source. Added two tests using a fake client built on `EventEmitter`,
  which throws on an unhandled `error` as a real client does. Both failed on the
  unfixed code, and the dropped-connection test failed with an `uncaughtException`.
- **Fix:** `importData` attaches a logging `error` listener after checkout and
  removes it in `finally`, before release. The failed query still rejects, so the
  existing rollback and 500 paths run.
- **Verification:** Both tests passed after the fix. The same fake server then
  received HTTP 500 from `POST /upload`, and the process stayed up until the
  harness exited it with code 0.

## Verification Evidence
- `docker build --target test images/backend`: 11 tests, 11 passed, 0 failed. The
  image was not published.
- Interim seed: `marketitems` was absent before the run; afterwards it held 100
  rows and Redis held 100 keys. Only counts were printed.
- Through `minishop-frontend-75c5d596b5-z8972`, before the seed: `/items?q=`
  was HTTP 200 with object code `42P01`. After: `/items?q=` was HTTP 200 with an
  array of 100, and `/items/1/reviews` was HTTP 200 with an array of 5.
- `scripts/validate-app.sh` exited 0, reported the MiniShop Pod, and skipped
  `POST /upload`. A re-run with the `Running` filter, after a read-only check
  counted 100 items, gave the same result and named
  `minishop-frontend-75c5d596b5-z8972`. The operator guide lookup resolved the same
  Pod.
- `scripts/validate-kustomize.sh` and `scripts/validate-helm.sh` exited 0.
- `bash -n` and `koalaman/shellcheck:v0.10.0` passed on `scripts/validate-app.sh`.
- All five PVC names and UIDs matched the baseline taken before the seed.
  The three backend Pods stayed Ready with 0 restarts.
- The operator guide commands, run on spare local port 18080, resolved the
  MiniShop Pod and returned HTTP 200 and a list of 100 items.

## Limitations
- The running backend image is still the old one. The fixes reach the cluster
  only after the owner merges, the image publishes, and a digest-pin PR follows.
  Until then, do not call `POST /upload` on the running stack: on the old image it
  crashes the backend container (unhandled rejection, exit 1) and writes no data.
- The seed is data only. A rebuilt database needs the new image or another seed.
- `/items` and the reviews route still return HTTP 200 for backend errors.
- `POST /upload` remains unauthenticated and drops the table when called.
- `scripts/validate-app.sh` still calls `POST /upload` for an empty list or
  `42P01`, so it must not run in that state until the new image is deployed.
- The `minishop-frontend` Service and Deployment selectors still overlap legacy
  Pods, so the Service can route to them.

## Decisions
- The seed script was kept out of the repository because it is one-time and is
  superseded by the fixed `/upload`.
- The seed wrote Redis first: `SET` is idempotent, so a PostgreSQL failure would
  leave a safe rerun, while the table check gates the rerun in the other order.
- No architecture changed; no ADR was created.
- ADR waiver: the owner did not explicitly state a waiver. The coordinator
  recommended waiving the ADR (bug fix, no architecture change), and the owner
  approved proceeding with the recommendations on 2026-11-02.

## Follow-ups
- Publish the fixed image and open a digest-pin PR.
- Narrow the `minishop-frontend` Service and Deployment selectors. A Deployment
  selector is immutable, so that needs its own planned change.
- Return non-2xx from `/items` and the reviews route on backend errors.
- Authenticate or remove `POST /upload`.

## Related Docs
- [Issue #36](https://github.com/thanhdu-hcmus/minishop-k8s/issues/36)
- [Operator guide](../minishop-operator-guide.md)
- [Troubleshooting](../troubleshooting.md)
- [Resilience validation results](../validation-results.md)
