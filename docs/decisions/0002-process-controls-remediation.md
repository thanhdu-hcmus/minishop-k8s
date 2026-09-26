---
title: Process-controls remediation decision
requirement: Issue #3 — remediate process-control gaps
status: verified
last_updated: 2026-09-26
---

# Process-Controls Remediation Decision

## Goal
Record the owner-approved T2 decision to correct the merged process scaffold with a focused forward-only pull request instead of rewriting main history.

## Prerequisites
- [Issue #3](https://github.com/thanhdu-hcmus/minishop-k8s/issues/3).
- [Process scaffold baseline](0001-process-scaffold-baseline.md).

## Key Concepts
| Concept | Plain-language explanation |
|---|---|
| Forward-only remediation | Add a corrective pull request while retaining existing public history. |
| Path-scoped check | Run a linter only for changed files in the directories it governs. |

## Architecture / Flow
The independent T2 audit found gaps in the merged scaffold. The owner approved a corrective Draft PR, which must pass CI and review before merge.

~~~mermaid
flowchart LR
  A[Retrospective T2 audit] --> B[Issue #3]
  B --> C[Clean-history Draft PR #7]
  C --> D[CI and independent review]
  D --> E[Owner merge decision]
~~~

## Implementation Walkthrough
1. **Keep history intact**: preserve merged PR #2 and record its gaps retroactively.
   - File(s): docs/devlog/2026-09-25-process-scaffold.md
   - The owner approved forward-only correction.
2. **Remediate controls in one T2 slice**: tighten commitlint and label matching, add scoped manifest/script checks, and complete ownership coverage.
   - File(s): .commitlintrc.json, .github/workflows/ci.yml, .github/CODEOWNERS
   - PR #7 remains Draft pending independent and owner review; PR #6 is superseded without rewriting its branch.
3. **Preserve validation limits**: record that this control-only PR did not exercise target-file linters.
   - File(s): docs/devlog/2026-09-26-process-controls-remediation.md
   - A later PR changing manifests or scripts must exercise those paths.

## Run & Verify
~~~bash
# Review GitHub Actions run 36256218460 on PR #7.
~~~
Expected result: the ci job succeeds. PR #7 run 36256218460 succeeded. PR #6 run 36255708939 remains historical evidence. Kubeconform, shellcheck, and PSScriptAnalyzer were not invoked because no matching target files changed. When PowerShell targets exist, the workflow collects findings for every target before returning failure.

## Common Pitfalls
- **Symptom:** A green control-only PR is treated as proof that every path-scoped linter works. **Cause:** no governed files changed. **Fix:** record the skipped targets and exercise each linter in a later relevant PR.
- **Symptom:** A late audit finding leads to rewriting protected public history. **Cause:** treating correction and history replacement as equivalent. **Fix:** use the approved forward-only remediation unless the owner explicitly authorizes a rewrite.

## Try It Yourself
- In a later Draft PR, change one Kubernetes manifest and one supported script, then confirm the corresponding CI steps run.

## Further Reading
- [GitHub Actions workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [Git workflow](../process/git-workflow.md)

## Related Docs
- Previous: [Process scaffold baseline](0001-process-scaffold-baseline.md)
- Next: [Process-controls remediation record](../devlog/2026-09-26-process-controls-remediation.md)
