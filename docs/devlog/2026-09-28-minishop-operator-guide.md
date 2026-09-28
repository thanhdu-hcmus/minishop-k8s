---
title: MiniShop operator guide
requirement: Issue #34 — backfill the current local operator guide
status: verified
last_updated: 2026-09-28
date: 2026-09-28
issue: "#34"
pr: "not recorded"
tier: T1
reconstructed: false
source: "Issue #34 acceptance criteria and merged repository implementation"
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

## Validation
- `git diff --check` passed.
- All local Markdown links in the changed guide and index resolve.
- Shell code blocks in the new guide passed `bash -n` parsing. Commands were
  reviewed against the checked-in scripts; no cluster commands were run.
- No runtime, manifest, CI, credential, or environment changes were made.

## Related Docs
- [Local MiniShop operator guide](../minishop-operator-guide.md)
- [Kustomize packaging decision](../decisions/0008-kustomize-packaging.md)
- [Helm packaging decision](../decisions/0009-helm-packaging.md)
- [Pod recovery and persistent data record](2026-09-28-pod-recovery-data-persistence.md)
- [Validation results](../validation-results.md)
- [Troubleshooting](../troubleshooting.md)
