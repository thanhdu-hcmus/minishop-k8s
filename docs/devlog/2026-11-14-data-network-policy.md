---
title: NetworkPolicy coverage for the data tier
requirement: Issue #40 — NetworkPolicy coverage for data (part 4 of 4)
status: implemented
last_updated: 2026-11-14
date: 2026-11-14
issue: "#40"
pr: "not recorded"
tier: T2
reconstructed: false
source: "Recorded during implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# NetworkPolicy Coverage for the Data Tier

## Goal
Part 4 of Issue #40: the chart's PostgreSQL and Redis Pods in `data` accept
connections only from the MiniShop backend (and the seed Job) in `webapp`.
Parts 1-3 (backup and restore, seed Job, credential rotation) are merged. The
legacy `redis-0` and CNPG `minishop-postgres-1/-2` in `data` must keep working
until the retirement runbook removes them. kind-learn is read-only for this
work; the live deploy is the owner's.

## Enforcement on kind-learn (read-only proof)
Done before writing policy, with gets, logs, and `kubectl exec` of TCP connect
probes from existing Pods only. Nothing was created, applied, or deleted.

- kindnet DaemonSet: image `docker.io/kindest/kindnetd:v20250512-df8de77b`, no
  args. Every kindnet Pod logs `Starting controller name="kube-network-policies"`
  and `Started plugin 10-kube-network-policies`, so the network-policy
  controller runs on all four nodes.
- The kindnet Pod on `learn-worker` also logged once at start
  `reading nfqueue stats ... open /proc/net/netfilter/nfnetlink_queue: no such
  file or directory`. Because `minishop-postgresql-0` runs on that node, the
  probes below check enforcement on it specifically.
- Probes (Node `net.connect`, 3 s timeout, from backend Pods; bash `/dev/tcp`
  with `timeout 4` from the legacy `redis-0`, whose namespace has no policy):

  | Source | Destination | Result | Why |
  | --- | --- | --- | --- |
  | backend (worker2) | `minishop-postgresql-0:5432` | OPEN | backend egress allows it |
  | backend (worker2) | `minishop-redis-0:6379` | OPEN | backend egress allows it |
  | each of the 3 backends (worker, worker2) | legacy `redis-0:6379` | TIMEOUT | backend egress denies it |
  | backend (worker2) | another backend `:3001` | TIMEOUT | backend egress denies it |
  | legacy `redis-0` | `minishop-postgresql-0:5432`, `minishop-redis-0:6379` | OPEN | no policy in `data` |
  | legacy `redis-0` | each backend `:3001` (worker and worker2) | TIMEOUT | backend ingress allows only frontend and Prometheus |
  | legacy `redis-0` | its own IP `:6379` | OPEN | the target listens |
  | Prometheus | backend `/metrics` | 3/3 targets `up` | ingress rule for Prometheus |

  The same destination port in the same namespace is open for an allowed peer
  and dropped for a denied one, and denied SYNs time out instead of being
  refused. **kindnet enforces NetworkPolicy on kind-learn**, ingress and
  egress, on `learn-worker` and `learn-worker2` (where the data Pods run). The
  backend's `httpGet` probes stay Ready under its ingress policy, so kubelet
  traffic from the node is not blocked.
- Who connects to the data Pods today: no ServiceMonitor or PodMonitor selects
  `data` (Prometheus has 0 active targets there; the only MiniShop monitors
  select `webapp`). The data Pods' liveness and readiness probes are `exec`
  probes. Backup, restore, and rotation use `kubectl exec`; rotation's TCP
  login check connects from inside the PostgreSQL Pod to its own Pod IP, and
  restore's Redis `REPLICAOF` targets 127.0.0.1 inside the Redis Pod.

## Features implemented
- `39f05c7` feat(chart): NetworkPolicies `minishop-postgresql` and
  `minishop-redis` in `data`, in `templates/networkpolicy.yaml`, on by default
  with no toggle (like the `webapp` policies):
  - `podSelector` is the StatefulSet selector (`component=database,
    name=minishop-postgresql` and `component=cache, name=minishop-redis`), so
    the legacy `redis-0` (`component=redis, name=minishop`) and the CNPG Pods
    (`name=postgresql`) are not selected and keep their access, including CNPG
    operator and replication traffic. No namespace-wide default-deny.
  - Ingress: TCP 5432 / 6379 only from peers with `namespaceSelector`
    `kubernetes.io/metadata.name=webapp` AND `podSelector` backend
    (`component=minishop-backend, name=minishop`, the Deployment selector;
    `part-of=minishop` added in the review fix pass below) in one entry; the seed Job peer (`component=seed, name=minishop,
    part-of=minishop`) is added only while `seed.enabled`.
  - Egress: `policyTypes` includes `Egress` with no rules, so the data Pods
    cannot open connections. A deviation from the recommended ingress-only
    design: PostgreSQL and Redis never initiate connections here (no
    replication, no DNS use), so denying egress costs nothing and limits what a
    compromised data Pod can reach.
  - No rule for monitoring (nothing scrapes `data`) or for probes (exec
    probes; resident-node traffic is not filtered anyway).
  - `validate-helm.sh` checks the rendered data policies for seed on and off.
    Three mutations were each caught: peers split into OR form ("expected 0
    peers without a namespaceSelector, found 2"), the seed peer rendered
    unconditionally, and `Egress` removed from `policyTypes`. Default renders outside the two new
    documents are unchanged against `origin/main` (0 removed lines).
- `ae86ea6` test(scripts): `scripts/test-data-network-policy.sh` builds a
  throwaway kind cluster `minishop-netpol-test` (control plane and two
  workers, node image from `cluster/kind-config.yaml`, own kubeconfig in a
  `mktemp -d` directory, deleted on exit) and checks every allowed and denied
  path listed under Verification.

## Problems and fixes
- **Test harness: stale Redis Pod IP after rotation.** First run of
  `test-data-network-policy.sh` (380 s): every check passed up to the
  "remove the policies" control, which failed with `webapp/plain ->
  10.244.1.12:6379: expected OPEN, got TIMEOUT`. Cause: the rotation restarts
  `minishop-redis-0`, so the IP read at the start belonged to the deleted Pod.
  Fix: read both data Pod IPs again after the data tools run.
- **Test harness: no cross-node traffic.** The same run placed every Pod on the
  single worker (the control plane is tainted), so only same-node paths were
  tested, while kind-learn runs the data Pods and clients on different nodes.
  Fix: the throwaway cluster has two workers and the client Pods are pinned,
  after the data Pods are placed, half to PostgreSQL's node and half to the
  other worker.

## Verification
- `bash scripts/validate-helm.sh`: lint and kubeconform pass for defaults,
  dev, prod, and seed on (17 resources, 19 with the seed); the new data-policy
  checks pass. `shellcheck` (koalaman/shellcheck:v0.10.0) is clean for
  `validate-helm.sh` and `test-data-network-policy.sh`.
- `bash scripts/test-data-network-policy.sh` on kind v0.30.0, node
  `kindest/node:v1.30.13`, kindnet `v20250512-df8de77b` (the same kindnet
  image as kind-learn), 379 s, `All data NetworkPolicy tests passed.`:
  - kube-network-policies started in all 3 kindnet Pods.
  - Seed Job completed; both backends: `ready=200 items=200 count=100
    reviews=200`; both reach the data Services (OPEN).
  - Placement: PostgreSQL on worker, Redis on worker2, backends on both;
    clients pinned to both workers, so same-node and cross-node paths ran.
  - Denied (TIMEOUT) on 5432 and 6379, by Service name and Pod IP:
    `webapp/plain` (no backend labels), `netpol-other/plain`,
    `netpol-other/backend-labels` (backend labels in another namespace), and
    `data/plain`. All four reach the legacy `redis-0` stand-in (OPEN).
  - Data Pod egress BLOCKED to the stand-in and to each other; PostgreSQL to
    its own IP OPEN.
  - Each data Pod's node reaches it (OPEN); data Pods Ready, 0 restarts,
    0 `Unhealthy` events.
  - `backup-data.sh`, `restore-data.sh` (incl. Redis `REPLICAOF 127.0.0.1`),
    and `rotate-data-credentials.sh --apply` (TCP login to the Pod IP, old
    passwords rejected, `/items 200`) all completed; the rotated backends read
    items and reviews.
  - Control: with the two data policies deleted, `webapp/plain`,
    `netpol-other/plain`, and `data/plain` reach both data Pods (OPEN); with
    them re-applied all denials return.
  - No initial password appears in any output.
- `bash scripts/test-data-rotation.sh` (unchanged) now also applies the data
  policies, because it renders `templates/networkpolicy.yaml`. All rotation
  tests passed in 579 s and the cluster was deleted. Full-rotation client
  window 46.0 s; prober `/items` 0/158 failed, `/items/0/reviews` 60/158
  failed. The 2026-11-10 record had 38.8 s, 0/137 and 60/137: the same
  failure pattern, which comes from the Redis restart by design. The window
  is a single run on a different cluster and is not compared further.
- `git diff --check` is clean; no CRLF in changed files.

## Review fixes (one pass, no Blockers)
- `6be5ff3` fix(chart): the backend peer also requires
  `app.kubernetes.io/part-of=minishop`, the backend Pod template's full label
  set. A read-only `kubectl get pods --show-labels` in `webapp` on kind-learn
  showed all three live backends carry it. `validate-helm.sh` now also asserts
  every peer's `name=minishop` and `part-of=minishop` labels, exactly one
  `from` rule per policy, and no other rule-level list item. Mutations caught:
  an empty allow-all rule (`expected 6 rule-level list items ..., found 8`),
  `part-of` removed, and `name` removed from the backend peer. ADR 0016 and
  troubleshooting list the label.
- `dd74b80` docs(operator): the verify and proof commands use
  `KUBECONFIG=./.kube/config kubectl --context kind-learn`, look up the
  PostgreSQL Pod IP, and print `rc=` (0 connected, 124 timed out).
- test(scripts) on `test-data-network-policy.sh`:
  - kindnet logs are captured before `grep -q`, avoiding SIGPIPE under
    `pipefail`;
  - the `Unhealthy` event check covers only `minishop-postgresql-0` and
    `minishop-redis-0` (`involvedObject.name`), not the legacy stand-in;
  - the rotated passwords are read from a new backend Pod's environment into
    private files after the rotation; the final scan covers initial and
    rotated passwords (8 patterns), and a log printed on failure is checked
    first and withheld if it holds a known password. Limit, stated in the
    header: if the rotation itself fails, its new passwords are unknown, so
    its log is checked against the initial ones only;
  - the cross-namespace impostor carries the full backend label set;
  - git mode set to 100755.
- Re-verification:
  - `bash scripts/validate-helm.sh`: passes (17 resources by default, 19 with
    the seed).
  - ShellCheck v0.10.0 (Docker) clean on both scripts; `bash -n` clean;
    `git diff --check` clean; no CRLF.
  - Full `bash scripts/test-data-network-policy.sh` rerun: **not completed.**
    It created the cluster and passed the kindnet check, then Claude Code
    stopped it while it waited for the data stack because the host was
    critically low on memory. The exit trap deleted the cluster (`kind get
    clusters` shows only `learn`). Per the stop notice it was not restarted
    without the owner. The last full pass is the 379 s run above, on the
    chart before `part-of` was added and the script before these fixes.

## Not deployed; known gaps
- kind-learn is unchanged. The live rollout is the owner's: the usual
  `bash scripts/deploy-helm.sh <values file>` adds the two policies; nothing
  restarts. Rollback is `helm rollback minishop <previous revision> -n webapp`,
  or deleting the two policies in `data`.
- Trust is label-based: any Pod in `webapp` that carries the backend labels
  reaches the data Pods. Who can create Pods in `webapp` is the real
  boundary (RBAC, out of scope).
- The raw `manifests/` and Kustomize path get no data policies; the chart is
  the deployed path.
- No HA: a future PostgreSQL or Redis replica would need its own ingress and
  egress rules for replication.

## Decisions
- [ADR 0016: Data-tier NetworkPolicy](../decisions/0016-data-tier-network-policy.md)
  (proposed): pod-selected scope, no namespace deny, legacy untouched, egress
  denied, label-based trust, no toggle.
- [ADR 0006](../decisions/0006-application-network-boundary.md) and
  [validation results](../validation-results.md) carry dated notes that the
  2026-09 "kindnet does not enforce" statement is superseded by the read-only
  proof above.

## Minor notes
- ShellCheck ran through the `koalaman/shellcheck:v0.10.0` Docker image.

## Follow-ups
- Rerun `bash scripts/test-data-network-policy.sh` in full on the final
  commits once the host has memory to spare, and record the result here.
- Owner: deploy, then verify and prove the denial as in the
  [operator guide](../minishop-operator-guide.md#data-network-policy); record
  the result here or in a follow-up record.
- Data policies for the raw `manifests/` and Kustomize paths, if those paths
  stay supported.
- Restrict who can create Pods in `webapp` (RBAC), since trust is label-based.
- Replication rules if PostgreSQL or Redis gains a replica.
- Owner accepts ADR 0016 (status proposed).
