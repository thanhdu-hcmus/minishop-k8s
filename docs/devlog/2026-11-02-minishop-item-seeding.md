---
title: MiniShop item seeding and validator targeting repair
requirement: Issue #36 — restore MiniShop item reads
status: verified
last_updated: 2026-11-02
date: 2026-11-02
issue: "#36"
pr: "not recorded"
tier: "not labelled on the Issue; owner to confirm"
reconstructed: false
source: "Owner-approved scope brief and runtime evidence from this implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# MiniShop Item Seeding and Validator Targeting Repair

## Goal
Make `GET /items?q=` and the reviews route return data on the MiniShop stack,
make `POST /upload` fail honestly, and make validation prove the MiniShop Pods
rather than the legacy Pods that share their labels.

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
   connection.
4. `images/backend/index.js` awaits both imports in a `try`/`catch`, returns 500
   on failure, and listens only when run as the entry point so tests can load it.
5. `scripts/validate-app.sh` resolves the Pod with the three-label selector. It
   skips `POST /upload` when items exist and fails, without uploading, on any
   response other than an empty list or `42P01`. It also checks the reviews route.
6. The operator guide port-forward now targets the resolved Pod.
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
  `minishop-frontend-75c5d596b5-z8972` and passed. Earlier validator results
  recorded in other devlog entries may describe the legacy stack.

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

### First test-stage build did not finish
- **Symptom:** A `docker build --target test` run on the unfixed code produced no
  output for more than 180 seconds and was stopped.
- **Cause:** Not determined.
- **What was tried:** Ran each test file separately with a hard timeout in the
  dependencies-stage image; all finished.
- **Fix:** None needed for the code. The same build later ran on the fixed code.
- **Verification:** That build exited 0 with 9 of 9 tests passing.

## Verification Evidence
- `docker build --target test images/backend`: 9 tests, 9 passed, 0 failed. The
  image was not published.
- Interim seed: `marketitems` was absent before the run; afterwards it held 100
  rows and Redis held 100 keys. Only counts were printed.
- Through `minishop-frontend-75c5d596b5-z8972`, before the seed: `/items?q=`
  was HTTP 200 with object code `42P01`. After: `/items?q=` was HTTP 200 with an
  array of 100, and `/items/1/reviews` was HTTP 200 with an array of 5.
- `scripts/validate-app.sh` exited 0, reported the MiniShop Pod, and skipped
  `POST /upload`.
- `scripts/validate-kustomize.sh` and `scripts/validate-helm.sh` exited 0.
- `bash -n` and `koalaman/shellcheck:v0.10.0` passed on `scripts/validate-app.sh`.
- All five PVC names and UIDs matched the baseline taken before the seed.
  The three backend Pods stayed Ready with 0 restarts.
- The operator guide commands, run on spare local port 18080, resolved the
  MiniShop Pod and returned HTTP 200 and a list of 100 items.

## Limitations
- The running backend image is still the old one. The fixes reach the cluster
  only after the owner merges, the image publishes, and a digest-pin PR follows.
  Until then, do not call `POST /upload` on the running stack, because the old
  code path can still fail as described above.
- The seed is data only. A rebuilt database needs the new image or another seed.
- `/items` and the reviews route still return HTTP 200 for backend errors.
- `POST /upload` remains unauthenticated and drops the table when called.

## Decisions
- The seed script was kept out of the repository because it is one-time and is
  superseded by the fixed `/upload`.
- The seed wrote Redis first: `SET` is idempotent, so a PostgreSQL failure would
  leave a safe rerun, while the table check gates the rerun in the other order.
- No architecture changed; no ADR was created.

## Follow-ups
- Publish the fixed image and open a digest-pin PR.
- Narrow the `minishop-frontend` Service and Deployment selectors. A Deployment
  selector is immutable, so that needs its own planned change.
- Return non-2xx from `/items` and the reviews route on backend errors.

## Related Docs
- [Issue #36](https://github.com/thanhdu-hcmus/minishop-k8s/issues/36)
- [Operator guide](../minishop-operator-guide.md)
- [Troubleshooting](../troubleshooting.md)
