# MiniShop documentation

1. [Git workflow](./process/git-workflow.md) — Issue-to-PR delivery rules.
2. [Process scaffold baseline](./decisions/0001-process-scaffold-baseline.md) — public-repository protections, history exception, and sanitized backup decision.
3. [Process-controls remediation decision](./decisions/0002-process-controls-remediation.md) — T2 forward-only correction decision.
4. [Local storage foundation decision](./decisions/0003-local-storage-foundation.md) — T2 node-local storage and default-class decision.
5. [Runtime data foundation decision](./decisions/0004-runtime-data-foundation.md) — T2 persistent PostgreSQL and Redis decision.
6. [Backend image publishing decision](./decisions/0005-backend-image-publishing.md) — T2 source-derived Redis-authenticated image and protected-main GHCR publication.
7. [Application workload and network boundary decision](./decisions/0006-application-network-boundary.md) — T2 app workload and internal traffic policy decision.
8. [Platform observability decision](./decisions/0007-platform-observability.md) — T2 least-privilege RBAC, autoscaling, and monitoring decision.
9. [Process scaffold devlog](./devlog/2026-09-25-process-scaffold.md) — Issue #1 implementation and verification record.
10. [Process-controls remediation record](./devlog/2026-09-26-process-controls-remediation.md) — Issue #3 remediation and its validation status.
11. [PR review handoff policy](./devlog/2026-09-27-pr-review-handoff-policy.md) — ready-for-review and owner review-request requirement.
12. [Agent workflow governance](./devlog/2026-09-27-agent-workflow-governance.md) — Issue #13 role boundaries, completion gate, and invocation logging.
13. [Local storage foundation record](./devlog/2026-09-27-local-storage-foundation.md) — Issue #15 storage implementation and verification record.
14. [Runtime data foundation record](./devlog/2026-09-27-runtime-data-foundation.md) — Issue #17 persistent data services and verification record.
15. [Backend image record](./devlog/2026-09-27-backend-image.md) — Issue #21 source-derived Redis-authenticated backend and validation record.
16. [Application network boundary record](./devlog/2026-09-27-application-network-boundary.md) — Issue #20 app deployment, credential setup, network policies, and validation record.
17. [Platform RBAC, scaling, and observability record](./devlog/2026-09-27-platform-rbac-scaling-observability.md) — Issue #26 implementation and verified runtime behavior.
18. [Kustomize packaging decision](./decisions/0008-kustomize-packaging.md) — T2 shared base, dev/prod overlays, and scoped teardown decision.
19. [Kustomize packaging record](./devlog/2026-09-28-kustomize-packaging.md) — Issue #28 implementation, runtime validation, and follow-ups.
20. [CI and runtime troubleshooting](./troubleshooting.md) — curated workflow and runtime failure diagnosis and fixes.
