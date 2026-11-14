---
title: Data-tier NetworkPolicy
requirement: Issue #40 — NetworkPolicy coverage for data (part 4 of 4)
status: proposed
last_updated: 2026-11-14
---

# Data-Tier NetworkPolicy

## Goal
Record the T2 decision on which traffic may reach the chart's PostgreSQL and
Redis Pods in `data`. Status is proposed; the owner accepts it on merge.

## Prerequisites
- [Issue #40](https://github.com/thanhdu-hcmus/minishop-k8s/issues/40). Parts
  1-3 ([ADR 0013](./0013-data-backup-restore.md),
  [ADR 0014](./0014-seed-job-replaces-upload.md),
  [ADR 0015](./0015-data-credential-rotation.md)) are merged.
- The `webapp` policies from [ADR 0006](./0006-application-network-boundary.md),
  now in `charts/minishop/templates/networkpolicy.yaml`.

## Decision
- **Pod-selected scope, no namespace default-deny.** Two policies,
  `minishop-postgresql` and `minishop-redis`, select only the chart's
  StatefulSet Pods (`component=database, name=minishop-postgresql` and
  `component=cache, name=minishop-redis`). The legacy `redis-0` and the CNPG
  `minishop-postgres-*` Pods are not selected and keep their current access
  until the [legacy retirement runbook](../legacy-retirement-runbook.md)
  removes them.
- **Ingress only from the backend in `webapp`.** TCP 5432 / 6379 from one peer
  entry that combines `namespaceSelector kubernetes.io/metadata.name=webapp`
  and `podSelector component=minishop-backend, name=minishop,
  part-of=minishop` (the backend Pod template's full label set), so both must
  match. A second peer for the seed Job (`component=seed, name=minishop,
  part-of=minishop`) renders only while `seed.enabled` is true.
- **Egress denied.** `policyTypes` lists `Egress` with no rules. This deviates
  from an ingress-only design: neither store opens connections (no
  replication, exec probes), so it costs nothing and limits a compromised data
  Pod. In-Pod checks (rotation's login to the Pod's own IP, restore's
  `REPLICAOF 127.0.0.1`) stay inside the Pod's network namespace.
- **No toggle.** The policies render by default, like the `webapp` policies.
  Rollback is `helm rollback minishop <previous revision> -n webapp`, or
  deleting the two policies.

## Rationale
Selecting Pods instead of the namespace keeps the change additive: nothing
else in `data` changes behaviour, so the legacy objects need no exceptions.
Putting both selectors in one peer stops a Pod with copied backend labels in
another namespace from connecting.

## Consequences
- **Trust is label-based.** Any Pod in `webapp` with the backend labels
  reaches the data Pods. Who may create Pods in `webapp` (RBAC, out of scope)
  is the real boundary.
- A new data client is silently dropped (connection timeout, not refusal)
  until it carries the backend labels in `webapp` or gets its own rule; see
  [troubleshooting](../troubleshooting.md).
- The raw `manifests/` and Kustomize paths get no data policies; the chart is
  the deployed path.
- A future PostgreSQL or Redis replica needs replication ingress and egress
  rules.

## Verification
- **Enforcement on kind-learn, read-only (2026-11-14).** kindnet
  `kindest/kindnetd:v20250512-df8de77b`; every kindnet Pod logs `Starting
  controller name="kube-network-policies"`. `kubectl exec` TCP probes from
  existing Pods: backend to `minishop-postgresql-0:5432` and
  `minishop-redis-0:6379` OPEN; backend to legacy `redis-0:6379` and to another
  backend `:3001` TIMEOUT; legacy `redis-0` to backends `:3001` TIMEOUT. The
  same port is open to an allowed peer and dropped for a denied one, so the
  existing `webapp` policies are enforced. Nothing was applied to kind-learn.
- **Throwaway cluster.** `scripts/test-data-network-policy.sh` (control plane
  and two workers, same kindnet) passed in 379 s: allowed paths work, four
  denied clients time out on both ports by Service and Pod IP, data-Pod
  egress is blocked, backup, restore, and rotation work, and deleting the
  policies restores the denied paths.
- `scripts/validate-helm.sh` asserts selectors, ports, no egress rules,
  namespace-scoped peers, and the seed peer following `seed.enabled`.
- Not yet deployed to kind-learn. Details: the
  [data network policy record](../devlog/2026-11-14-data-network-policy.md).

## Related Docs
- [Data network policy record](../devlog/2026-11-14-data-network-policy.md)
- [ADR 0006](./0006-application-network-boundary.md)
- [Operator guide: data network policy](../minishop-operator-guide.md#data-network-policy)
