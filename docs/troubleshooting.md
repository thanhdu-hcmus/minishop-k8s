---
title: CI troubleshooting
requirement: DOC-03 — curate instructive process failures
status: verified
last_updated: 2026-09-27
---

# CI Troubleshooting

## Goal
Provide durable symptom-to-fix guidance for the process-scaffold failures that future MiniShop pull requests could repeat.

## Prerequisites
- Access to the pull request’s `ci` check and its failed-step logs.
- [Git workflow](./process/git-workflow.md) for the expected delivery sequence.

## Key Concepts
| Concept | Plain-language explanation |
|---|---|
| Job creation | A workflow syntax failure can stop GitHub Actions before any job exists. |
| Synthetic merge commit | GitHub can create a temporary merge ref for a PR; commitlint should check the actual branch commits instead. |
| Hosted runner | A runner image is not a contract that every convenience tool is installed. |
| Git ref write denial | A filesystem sandbox can block local branch creation even when the repository worktree is writable. |
| Runtime credential guard | A bootstrap script can stop before creating a Secret when a required runtime input is absent. |
| Dynamic ShellCheck source | A dynamically resolved shell helper may need an explicit source directive or scoped suppression. |
| GHCR package access | Package visibility and repository access permissions need verification after first publication. |

## Architecture / Flow
A pull request first loads its workflow, then starts the `ci` job, then runs each validation step.

```mermaid
flowchart LR
  A[Workflow syntax] --> B[CI job starts]
  B --> C[Commit and YAML checks]
  C --> D[Path-scoped checks]
  D --> E[Devlog and secret checks]
```

## Implementation Walkthrough
1. **Record workflow bootstrap failures**: capture the exact failure class before changing CI.
   - File(s): `.github/workflows/ci.yml`
   - A run with no job generally indicates a workflow-loading issue rather than a failed step.
2. **Use portable, pinned checks**: configuration belongs in the repository; runner tools are used only when explicitly available.
   - File(s): `.commitlintrc.json`, `.github/workflows/ci.yml`
   - The remediation pins kubeconform and PSScriptAnalyzer, collects PowerShell findings before failing, and replaces `rg` with `grep -E`.

## Run & Verify
```bash
# Open the failed `ci` run and identify whether a job was created.
# Read the named failed step before changing the workflow.
```
Expected result: the diagnosis identifies the failing layer and the next run advances beyond that layer. The clean-history remediation PR #7 completed successfully in GitHub Actions run `36256218460`; the earlier PR #6 run remains historical troubleshooting evidence.

## Common Pitfalls
- **Symptom:** A workflow run fails before any job begins. **Cause:** workflow YAML or expression syntax is invalid. **Fix:** correct the reported line, then confirm the next run creates `ci`.
- **Symptom:** Commitlint reports `empty-rules`. **Cause:** the CLI has no repository rule configuration. **Fix:** add and version a commitlint configuration, then lint the actual PR commit range.
- **Symptom:** Commitlint rejects a subject containing uppercase letters. **Cause:** repository policy requires a lowercase subject. **Fix:** use lowercase words and acronyms in the Conventional Commit subject.
- **Symptom:** Yamllint reports document-start, truthy-key, or line-length violations. **Cause:** the workflow does not meet the repository’s lint policy. **Fix:** make the YAML conform exactly and rerun the pinned linter.
- **Symptom:** CI cannot find `rg`. **Cause:** ripgrep is not guaranteed on a hosted runner. **Fix:** use `grep -E` for this simple changed-path filter or provision the dependency explicitly.
- **Symptom:** A local Git branch command reports a read-only ref filesystem. **Cause:** not recorded; the command could not write under `.git/refs`. **Fix:** report the exact command and obtain owner authorization before using an approved remote fallback; do not bypass the denial.
- **Symptom:** A local-path PVC remains unbound before a consumer Pod is scheduled. **Cause:** the configured `StorageClass` uses `WaitForFirstConsumer` to select a node before creating node-local storage. **Fix:** create or schedule the consumer Pod, then inspect the PVC and provisioner rollout.
- **Symptom:** A pinned containerized linter image cannot be pulled. **Cause:** the selected image tag does not exist. **Fix:** use an available, explicitly versioned image tag and record it in the validation evidence; do not install a host tool as a substitute.
- **Symptom:** The runtime credential script exits before creating the data Secret. **Cause:** one or both required runtime password inputs are absent. **Fix:** supply both required values through the deployer's runtime environment, then rerun the script; never add those values to tracked files.
- **Symptom:** ShellCheck reports `SC1091` for a helper sourced through a computed path. **Cause:** static analysis cannot resolve that dynamic source path. **Fix:** add a precise source directive when possible, or use a scoped suppression only for the dynamic source after validating the helper locally.
- **Symptom:** A fresh cluster cannot pull the published backend image. **Cause:** Package visibility or repository access permissions do not allow the intended consumers. **Fix:** verify both settings after the first protected-main publication and adjust only when needed; the workflow does not change package access.

## Try It Yourself
- Make a temporary Draft PR with a non-trivial change and no devlog; confirm the `ci` job reaches the devlog gate after earlier checks pass.

## Further Reading
- [GitHub Actions workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [Commitlint getting started](https://commitlint.js.org/guides/getting-started.html)

## Related Docs
- Previous: [Process-controls remediation record](./devlog/2026-09-26-process-controls-remediation.md)
- Next: [Agent workflow governance](./devlog/2026-09-27-agent-workflow-governance.md)
