---
title: Pod recovery and persistent data validation record
requirement: Issue #32 — validate pod recovery and data persistence
status: verified
last_updated: 2026-09-28
date: 2026-09-28
issue: "#32"
pr: "not recorded"
tier: T2
reconstructed: false
source: "Issue #32, devops handoff summary, and docs/validation-results.md runtime evidence"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# Pod Recovery and Persistent Data Validation Record

## Goal
Validate recovery of MiniShop Pods, persistence across PostgreSQL and Redis Pod
recreation, and the 3–8 backend HPA while preserving legacy workloads and all
existing storage.

## Key Concepts
| Concept | Plain-language explanation |
|---|---|
| Controller recovery | A Deployment or StatefulSet creates a replacement Pod after a selected Pod is deleted. |
| Persistent-volume recovery | Data remains available after a StatefulSet Pod is recreated while its PVC remains bound. |
| Bounded HPA test | A controlled load checks scaling behavior without changing the HPA's configured range. |

## Implementation Walkthrough
1. Captured pre-test resource metadata, then selected only MiniShop Pods using
   labels that excluded legacy workloads.
2. Recreated one frontend Pod, one backend Pod, the MiniShop PostgreSQL Pod,
   and the MiniShop Redis Pod individually. Temporary database and Redis markers
   were removed after persistence was verified.
3. Ran the existing bounded HPA load Job, observed scale-up and scale-down, and
   removed the Job, its Pod, and temporary NetworkPolicies.
4. Compared post-test metadata with the baseline to verify workload, HPA, PVC,
   and PV state was preserved. No application code, manifests, or runtime
   configuration changed.

## Runtime results
- Read-only baseline snapshots covered 18 Deployments/StatefulSets, both HPAs,
  all five PVCs, and all five PVs. Exact pre/post metadata projections matched.
- The frontend Pod selected with `component=frontend`, `name=minishop`, and
  `part-of=minishop` was replaced and became Ready; its root endpoint returned
  HTTP 200. One backend Pod selected with the disjoint MiniShop backend labels
  was replaced; the Deployment returned to three Ready Pods.
- A uniquely named PostgreSQL test table/marker survived recreation of only
  `minishop-postgresql-0`, then the table was dropped. A Redis test key with a
  900-second TTL survived recreation of only `minishop-redis-0`, then the key
  was explicitly deleted and verified absent.
- The existing bounded HPA test moved the backend from 3 baseline replicas to
  8 peak Ready replicas and back to 3 settled Ready replicas. The Job, Pod, and
  both temporary NetworkPolicies were removed. The HPA remained within 3–8.
- No legacy workloads, platform workloads, Secret objects, PVCs/PVs, or HPA
  configuration were changed. The local Kind `kindnet` CNI does not enforce
  NetworkPolicies; the test does not claim policy enforcement.
- Full commands and measurements are in
  [validation results](../validation-results.md).

## Limitations
- The read-only frontend `GET /items?q=` response returned HTTP 200 with
  PostgreSQL error code `28P01`, not application data. No credential values or
  row contents were accessed, and credentials were not changed. This failure is
  outside Issue #32's permitted scope and is recorded for owner follow-up.
- The isolated worktree had no ignored kubeconfig. Read-only cluster queries
  used the existing root-checkout kubeconfig path in place under the owner's
  localhost authorization; the file itself was never read or copied.

## Decisions
- No architecture or implementation decision changed in this validation-only
  Issue; no ADR was created.

## Problems encountered
### Isolated worktree did not contain the ignored kubeconfig
- **Symptom:** The Issue #32 worktree had no `./.kube/config`, and the first
  read-only API call from the default sandbox failed to connect to
  `127.0.0.1:34077` with `socket: operation not permitted`.
- **Cause:** The credential-bearing kubeconfig is ignored and remains only in
  the owner's root checkout; the command sandbox also blocks the local API
  socket by default.
- **What was tried:** Checked only whether the expected file existed, without
  reading it; retried a read-only cluster query using the existing root-checkout
  path as `KUBECONFIG` under the owner-approved localhost escalation.
- **Fix:** Used the existing kubeconfig in place for scoped `kubectl` commands;
  did not copy, inspect, or print it.
- **Verification:** The read-only namespace, workload, HPA, pod-label, PVC, and
  PV queries succeeded, with no credential values returned.

### Application item route returned a PostgreSQL authentication error
- **Symptom:** After deleting and observing recreation of only the selected
  MiniShop frontend Pod, `GET /` returned HTTP 200, while read-only `GET
  /items?q=` returned HTTP 200 with a PostgreSQL error object and code
  `28P01` rather than an item array.
- **Cause:** Not yet determined. The error indicates a database authentication
  failure, but the exact mismatch cannot be established without accessing
  credential values or expanding the approved scope.
- **What was tried:** Checked HTTP status and top-level response shape/code only;
  response bodies, row contents, and credential values were not emitted.
- **Fix:** No credential or database changes were made because they are outside
  Issue #32 constraints. Continue only reversible checks that do not require
  modifying credentials; report this as a pre-existing runtime limitation.
- **Verification:** The MiniShop frontend Pod was replaced with a new Ready Pod;
  its root endpoint returned HTTP 200. The item route's DB-authentication
  failure remains unresolved and must not be represented as a successful app
  data-path check.

### Backend replacement assertion used an invalid JSONPath filter
- **Symptom:** The MiniShop backend Deployment completed rollout after one
  Pod deletion, but the follow-up `kubectl get pod` assertion reported several
  Pod names as one resource name.
- **Cause:** The JSONPath filter embedded a dynamic UID incorrectly and emitted
  all selected names rather than a single replacement name.
- **What was tried:** Read the exact Pod list, UIDs, and container readiness
  using the same three-label MiniShop selector.
- **Fix:** Verify the Deployment still has three Ready MiniShop backend Pods;
  the deleted Pod name is gone and the controller-created replacement has a
  distinct name and UID.
- **Verification:** `deployment/minishop-backend` rollout succeeded, with
  three selector-matched backend Pods all Ready.

### Referenced aggregate validator is absent
- **Symptom:** Repository guidance references `scripts/validate.sh`, but no
  file with that name exists in the `scripts/` directory.
- **Cause:** The checked-in repository provides focused validators instead of
  the aggregate path named in the guide.
- **What was tried:** Listed the checked-in scripts. The application validator
  performs `POST /upload`, which would create unrelated app data; the platform
  validator also restarts a backend container beyond this Issue's scope.
- **Fix:** Did not run either broader script. Executed the Issue-specific
  read-only, recovery, persistence, and bounded HPA checks directly.
- **Verification:** Runtime evidence and final resource comparisons are
  recorded in [validation results](../validation-results.md); no unrelated
  record or platform resource was modified.

## Verification Evidence
- Frontend and backend replacements returned Ready; frontend `GET /` returned
  HTTP 200.
- A unique PostgreSQL table marker and Redis key with a 900-second TTL survived
  their respective StatefulSet Pod recreations, then were cleaned up.
- The backend HPA moved from 3 Ready replicas to 8 and settled at 3; its
  configured range remained 3–8.
- Final metadata projections matched for 18 Deployments/StatefulSets, 2 HPAs,
  5 PVCs, and 5 PVs. Temporary test resources were absent after cleanup.
- Focused whitespace checks passed. No code, YAML, or shell files changed.
  Full runtime details are in [validation results](../validation-results.md).

## Follow-ups
- The `/items?q=` route returned PostgreSQL error code `28P01`; diagnosis and
  credential repair were not part of this Issue. The cause is not recorded.
- No additional follow-up Issue or PR was recorded in the handoff.

## Related Docs
- [Issue #32](https://github.com/thanhdu-hcmus/minishop-k8s/issues/32)
- [Validation results](../validation-results.md)
- [Troubleshooting](../troubleshooting.md)
