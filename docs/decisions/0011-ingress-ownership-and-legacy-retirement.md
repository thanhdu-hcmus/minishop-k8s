---
title: Ingress ownership and legacy retirement
requirement: Issue #38 — retire the legacy stack and own the Ingress in Git
status: proposed
last_updated: 2026-11-08
---

# Ingress Ownership and Legacy Retirement

## Goal
Record the T2 decisions that move `minishop.local` onto Git-owned resources:
who owns the Ingress, how the frontend selects its Pods, who owns ingress-nginx
and MetalLB, and what happens to legacy data. Status is proposed; the owner
accepts it on merge and approves each runbook step separately.

## Prerequisites
- [Issue #38](https://github.com/thanhdu-hcmus/minishop-k8s/issues/38).
- [Helm packaging](0009-helm-packaging.md) and the
  [application network boundary](0006-application-network-boundary.md).
- Live state, read-only, on 2026-11-08: the legacy Ingress
  `webapp/minishop-frontend` (class `nginx`, host `minishop.local`, Service
  `frontend`) is not Helm-owned; ingress-nginx v1.12.4 and MetalLB v0.14.9 run
  but were installed by hand; legacy frontend Pods carry the same `component`
  and `name` labels as the Helm frontend, without `part-of`.

## Decision
1. **Ingress ownership.** The chart owns Ingress `webapp/minishop`
   (`ingress.enabled: true`, class `nginx`, host `minishop.local`, path `/`
   Prefix, Service `minishop-frontend` port `http`), and the raw manifests
   carry the same Ingress for the Kustomize path. The name differs from the
   legacy `minishop-frontend` because Helm refuses to take over an object
   without its ownership metadata; adopting the legacy object by annotating it
   in the cluster was rejected. A NetworkPolicy
   `minishop-frontend-from-ingress` admits only ingress-nginx controller Pods
   to the frontend on TCP 8080. This extends the chart boundary in
   [ADR 0009](0009-helm-packaging.md), which did not list an Ingress: the
   chart now also owns this Ingress and NetworkPolicy. ADR 0009's list of
   resources kept outside the chart is unchanged, and the ingress-nginx
   controller stays outside the chart.
2. **Cutover.** ingress-nginx admission rejects a second Ingress for the same
   host and path, so the two cannot coexist. The legacy Ingress is deleted
   first and `deploy-helm.sh` then creates `webapp/minishop`; `minishop.local`
   returns 404 for about a minute in between. `deploy-helm.sh` and
   `deploy-kustomize-dev.sh` refuse to run while any other Ingress claims the
   host, so an upgrade never fails part-way on the webhook.
3. **Selector strategy.** The `minishop-frontend` Service selector, the
   `minishop-frontend` NetworkPolicy podSelector, and the backend policy's
   frontend peer add `app.kubernetes.io/part-of=minishop`. The Deployment
   `spec.selector` stays unchanged: it is immutable, so changing it would
   break `helm upgrade` and need a delete-and-recreate with downtime.
   ReplicaSets manage only Pods they own, and deleting the legacy `frontend`
   Deployment removes the remaining overlap. The backend selectors do not
   overlap legacy objects and are unchanged.
4. **ingress-nginx ownership.** Git owns it through
   `scripts/deploy-ingress-nginx.sh`: the upstream kind provider manifest for
   `controller-v1.12.4`, verified by SHA-256 before it is applied.
   `cluster/kind-config.yaml` labels the control plane `ingress-ready=true`, so
   on a fresh cluster the controller binds the published host ports 80 and
   443. v1.12.4 matches the running controller; a read-only diff showed no
   change other than re-creating the two self-deleting admission Jobs.
5. **MetalLB ownership.** MetalLB stays out of Git. Only the legacy
   `frontend-loadbalancer-demo` Service uses it, and ingress-nginx on kind uses
   host ports instead. The recommendation is to remove it after that Service
   is retired (runbook step 8); keeping it for teaching is an owner decision.
6. **Legacy retirement.** `docs/legacy-retirement-runbook.md` orders the
   deletions, puts a check before each step, and marks each step reversible,
   data-reversible, or irreversible. It exports every legacy object first and
   never exports Secret values.
7. **Data retention is deferred to Issue #42**, where the owner decides
   between CNPG and the plain StatefulSet. Until then, the CNPG Cluster
   `minishop-postgres` (database `kumademo`) and the legacy Redis stay in
   place. The runbook takes a `pg_dump` and a Redis `SAVE` copy before any data
   deletion, and data deletion waits for that decision.

## Rationale
Distinct names and a host-conflict preflight make the cutover explicit and
fail before anything changes, rather than in the middle of a Helm upgrade. An
exact Service selector fixes routing at once without touching an immutable
field. Pinning ingress-nginx to the running version gives a fresh cluster the
same controller as the live one without changing the live one. A checksum
protects the downloaded manifest, whose images are already digest-pinned.
Data deletion is irreversible, because every PV uses reclaim policy `Delete`,
so it waits for an explicit storage decision and a verified backup.

## Consequences
- Until the legacy Ingress is deleted, `deploy-helm.sh` and
  `deploy-kustomize-dev.sh` stop with a message that points to the runbook.
  Deploy any other pending chart change (for example the backend probe PR)
  either before this merge or as part of runbook step 2.
- A fresh cluster reaches `http://minishop.local` through
  `create-cluster.sh`, `deploy-ingress-nginx.sh`, the runtime deploy, and a
  hosts entry for `127.0.0.1 minishop.local`; this sequence has not been run
  on a newly created cluster. The existing kind-learn cluster already has the
  node label and controller and is not recreated.
- Upstream `kubernetes/ingress-nginx` is archived, as the GitHub API
  confirmed on 2026-11-08; its last releases, `controller-v1.15.1`,
  `v1.14.5`, and `v1.13.9`, were published on 2026-03-19. The v1.12 line
  shipped v1.12.5 through v1.12.8 (the last on 2025-11-04), so v1.12.4 is four
  patch releases behind. It is kept only to match the live controller. A
  follow-up Issue should weigh v1.12.8 (same minor version, smallest change)
  against v1.15.1 (the final release) against moving to a maintained Gateway
  API implementation.
- The controller keeps the upstream single replica, CPU and memory requests,
  and no limits. Plain HTTP only; TLS for `minishop.local` is out of scope.
- NetworkPolicy enforcement is still unverified on `kindnet` (ADR 0006).
  `minishop-frontend-from-ingress` is required on a CNI that enforces policy;
  on kind-learn, earlier tests found policies were not enforced.
- The Deployment selector keeps matching legacy frontend Pods until runbook
  step 3 runs; `validate-app.sh` keeps resolving the Pod with `part-of`.

## Verification
Helm lint, render, and kubeconform passed for default, dev, and prod values,
along with the new schema and disabled-Ingress checks. The Kustomize dev,
prod, and teardown renders validated. A read-only `helm upgrade
--dry-run=server` against the live release with `replicas.backend=1` and
`replicas.frontend=1` reported no
ownership or immutable-field error. A `kubectl diff --server-side` of the
render showed only the three `part-of` additions with the Ingress disabled,
and the expected webhook denial with it enabled while the legacy Ingress
exists. Full commands and results are in the devlog.

## Related Docs
- [Legacy retirement runbook](../legacy-retirement-runbook.md)
- [Implementation record](../devlog/2026-11-08-ingress-ownership.md)
- [Helm packaging](0009-helm-packaging.md)
- [Application network boundary](0006-application-network-boundary.md)
- [Issue #38](https://github.com/thanhdu-hcmus/minishop-k8s/issues/38),
  [Issue #42](https://github.com/thanhdu-hcmus/minishop-k8s/issues/42)
