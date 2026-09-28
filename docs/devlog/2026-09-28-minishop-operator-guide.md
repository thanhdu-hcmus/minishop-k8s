---
title: MiniShop operator guide
requirement: Issue #34 — backfill the current local operator guide
status: verified
last_updated: 2026-09-28
date: 2026-09-28
issue: "#34"
pr: "not recorded"
tier: T1
reconstructed: true
source: "Issue #34 acceptance criteria, current repository audit, and devops handoff summary"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# MiniShop Operator Guide Record

## Goal
Provide one concise operator entry point for the current WSL2/Kind development
deployment paths, validation, known limitations, and safe cleanup boundary.

## Work completed
- Audited the current chart, Kustomize overlays, deploy/validation/teardown
  scripts, packaging decisions, runtime evidence, and troubleshooting notes.
- Added [the local operator guide](../minishop-operator-guide.md), linked it
  from the docs index, and connected it to the Kustomize/Helm decisions and
  records, platform observability, resilience evidence, and troubleshooting.
- Clearly separated dev settings from prod examples, documented scoped
  read-only checks versus state-changing commands, and preserved the unresolved
  `/items?q=` PostgreSQL `28P01` behavior as a limitation.

## Decisions
- The guide treats the Helm chart and Kustomize dev overlay as current local
  deployment paths, with production values presented only as examples.
- Helm's external namespace, Secret, ServiceAccount, and HPA prerequisites are
  distinguished from Kustomize's conditional namespace/credential creation and
  ServiceAccount requirement. Kustomize has no HPA prerequisite.
- Related design choices are recorded in the
  [Kustomize packaging decision](../decisions/0008-kustomize-packaging.md),
  [Helm packaging decision](../decisions/0009-helm-packaging.md), and
  [platform observability decision](../decisions/0007-platform-observability.md).

## Problems and fixes
- The existing `/items?q=` path returned HTTP 200 with PostgreSQL error code
  `28P01` rather than item data. The credential mismatch remains unresolved;
  the guide and [troubleshooting entry](../troubleshooting.md) document it as a
  limitation. No credentials or persisted data were changed. No other problem
  or fix was recorded in the handoff.

## Validation
- `git diff --check` passed.
- All local Markdown links in the changed guide and index resolve.
- Shell code blocks in the new guide passed `bash -n` parsing. Commands were
  reviewed against the checked-in scripts; no cluster commands were run.
- No runtime, manifest, CI, credential, or environment changes were made.

## Follow-ups
- Diagnosis of the existing PostgreSQL `28P01` response is not recorded as a
  follow-up Issue; the guide points operators to troubleshooting and cautions
  against treating the route as successful data-path validation.
- PR, CI, and additional follow-up details are not recorded in the handoff.

## Related Docs
- [Local MiniShop operator guide](../minishop-operator-guide.md)
- [Kustomize packaging decision](../decisions/0008-kustomize-packaging.md)
- [Helm packaging decision](../decisions/0009-helm-packaging.md)
- [Pod recovery and persistent data record](2026-09-28-pod-recovery-data-persistence.md)
- [Validation results](../validation-results.md)
- [Troubleshooting](../troubleshooting.md)
