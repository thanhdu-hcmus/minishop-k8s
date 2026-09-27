---
title: MiniShop RBAC, autoscaling, and observability
requirement: Issue #26 — RBAC, autoscaling, and observability
status: verified
last_updated: 2026-09-27
---

# MiniShop RBAC, Autoscaling, and Observability

## Goal
Record the T2 decision to add scoped developer access, metrics-backed scaling,
and application/cluster observability for the existing MiniShop Kind runtime.

## Prerequisites
- [Issue #26](https://github.com/thanhdu-hcmus/minishop-k8s/issues/26).
- The existing application resources in `webapp` and data resources in `data`.
- The local `kind-learn` cluster.

## Decision
Give the backend a dedicated ServiceAccount with token automount disabled and
no API permissions. Bind the `minishop:developers` group to a role permitting
pod get/list/watch and pod-log get only, in the `webapp` and `data` namespaces.
Do not grant Secret access or general workload-resource access.

Install metrics-server `v0.7.2` with the kubelet TLS option required by the
tested Kind environment and explicit resource bounds. Scale the backend by CPU
at 50% average utilization, with a minimum of three and maximum of eight
replicas. Use preferred pod anti-affinity rather than a hard placement
requirement.

Install kube-prometheus-stack chart `69.8.2` sized for the local cluster,
preserving the existing release values during the tested upgrade. Add a
workload CPU/restart dashboard ConfigMap, a ServiceMonitor for the backend's
existing Prometheus-compatible `/metrics` endpoint, and an alert for backend
container restarts.

## Rationale
These controls exercise least privilege and operational feedback without
changing database topology, credentials, image source, ingress, or packaging.
The existing backend exposes a compatible metrics endpoint, so the monitoring
slice can scrape application metrics directly in addition to cluster metrics.

## Consequences
- Developer permissions apply only to the `minishop:developers` group and the
  two named namespaces; identity provisioning is outside this Issue.
- The HPA can scale only within 3–8 replicas and depends on metrics-server.
- Monitoring adds cluster-wide components and resource consumption; chart
  values bound components for the local Kind environment.
- The local `kindnet` CNI does not enforce NetworkPolicy. Applying narrow policy
  objects does not prove denied traffic is blocked.
- The host did not have Helm, so the full deployment script was not run as a
  single end-to-end command. The chart operation and component actions were
  instead exercised with a pinned Helm container.

## Verification
Pinned ShellCheck `0.10.0`, yamllint `1.35.1`, and kubeconform `0.6.7` checks
passed; kubeconform accepted 14 resources and skipped two custom Prometheus
Operator schemas. Server-side dry-run passed. Runtime checks verified RBAC
allow/deny behavior, metrics-server resource metrics, HPA scale-up from 3 to 8
and return to 3, healthy Prometheus scraping of the backend endpoint, and the
controlled backend-restart alert. Temporary load-test resources were removed.

## Related Docs
- [Platform implementation record](../devlog/2026-09-27-platform-rbac-scaling-observability.md)
- [Issue #26](https://github.com/thanhdu-hcmus/minishop-k8s/issues/26)
