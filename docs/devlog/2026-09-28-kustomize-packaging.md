---
title: Kustomize packaging implementation record
requirement: Issue #28 — package MiniShop manifests with Kustomize
status: in progress
last_updated: 2026-09-28
date: 2026-09-28
issue: "#28"
pr: ""
tier: T2
reconstructed: false
source: ""
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: 0, ci_failures: 0 }
---

# Kustomize Packaging Implementation Record

## Problems encountered
### Kustomize base source restrictions
- **Symptom:** The base initially failed to build because Kustomize rejected raw manifests referenced outside `kustomize/base`.
- **Root cause:** Kubectl's default `LoadRestrictionsRootOnly` prevents reading files outside the Kustomization root.
- **Fix:** Build with `--load-restrictor LoadRestrictionsNone`; sources remain explicit, local repository files, with no plugins or remote sources.
- **Verified by:** The pinned Kustomize in kubectl rendered the base and pinned kubeconform accepted all 25 resources.

### Offline kubectl client dry-run
- **Symptom:** `kubectl apply --dry-run=client` attempted discovery from `localhost:8080` and was blocked by the sandbox.
- **Root cause:** Client dry-run still needs API discovery for the configured resource mapper; this isolated worktree has no usable cluster context.
- **Fix:** Validate rendered output with the repository's existing pinned kubeconform container instead of requiring API discovery.
- **Verified by:** Kubeconform `v0.6.7` parsed 25 resources with zero invalid resources or errors.
