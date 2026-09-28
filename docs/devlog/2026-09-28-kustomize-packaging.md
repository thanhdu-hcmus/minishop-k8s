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

### Dev overlay and platform HPA replica conflict
- **Symptom:** The requested dev backend replica count is 1, while the existing platform HPA has a minimum of 3.
- **Root cause:** The HPA is intentionally outside the Kustomize application overlays and can override the Deployment's dev replica target at runtime.
- **Resolution:** The owner approved keeping the HPA active and the dev overlay at 1 backend replica. The deploy path reports and waits for the HPA's configured minimum; live backend replicas are therefore at least 3 while the HPA is active.
- **Verified by:** The dev render sets the backend to 1; live `minishop-backend` HPA status has a minimum/current/desired count of 3, and all three backend replicas are Ready after deployment.

### Stale validator loop terminator
- **Symptom:** `bash -n` rejected `scripts/validate-kustomize.sh` after extending its overlay checks to include teardown.
- **Root cause:** The loop was refactored to a helper function but retained the old `done` terminator.
- **Fix:** Removed the stale terminator and obsolete status message.
- **Verified by:** `bash -n`, ShellCheck, and pinned kubeconform validation of dev, prod, and teardown renders.

### Existing helper scripts are not executable
- **Symptom:** The deploy path failed when directly invoking `scripts/validate-app.sh`.
- **Root cause:** Existing credential and app-validation helpers are tracked without executable bits.
- **Fix:** Keep the data-writing E2E probe separate from idempotent deployment and document its explicit invocation as `bash scripts/validate-app.sh`; the validation helper now performs a server-side dry-run of the dev Kustomize render. The existing probe writes one demo item to persistent data and is not run automatically by deployment.
- **Verified by:** The deployment script passes without runtime password environment inputs by reusing both existing Secret objects; `bash scripts/validate-app.sh` then passed its Kustomize server dry-run and frontend-to-backend-to-data check.

### Local commitlint package fetch unavailable
- **Symptom:** The pinned `npx @commitlint/cli@19.8.1` check could not download the package.
- **Root cause:** DNS resolution for `registry.npmjs.org` returned `EAI_AGAIN` in the local environment.
- **What was tried:** The repository-pinned CLI version was invoked with the branch commit range; it failed before running.
- **Verified by:** All three commit subjects were manually checked against `.commitlintrc.json`; CI remains responsible for running the pinned CLI.

## Verification evidence
- `kubectl kustomize` rendered dev and prod with exactly the same 25 resources as the base; only the requested backend/frontend Deployment replica counts differ. Kubeconform `v0.6.7` accepted 25/25 resources for each render and 13/13 teardown resources.
- The deploy script applies only dev. Prod is rendered and schema-validated but is not deployed to the local Kind cluster.
- Yamllint `1.35.1`, ShellCheck `0.10.0`, Bash parsing, and `git diff --check` passed for changed YAML and scripts.
- The dev bundle deployed in `kind-learn` using existing credential Secret objects, without reading or printing secret values. PostgreSQL, Redis, frontend, and backend reached Ready; the active platform HPA kept the backend at 3 replicas despite the dev manifest's replica count of 1.
- Scoped teardown removed only the MiniShop app/data Services, Deployments, StatefulSets, and NetworkPolicies. It preserved both Secret objects, all five bound PVCs, namespaces, StorageClasses, provisioner, and platform HPA. Redeployment through the dev overlay succeeded using retained credentials and PVCs.
- Pre/post metadata snapshots for all Deployments, HPAs, PVCs, and StorageClasses matched exactly, including legacy `webapp/backend` and `webapp/frontend` Deployments and HPA, metrics-server, and monitoring workloads. Kind's `kindnet` CNI does not enforce NetworkPolicies; this remains a documented environment limitation.
