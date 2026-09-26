---
title: Agent workflow governance
requirement: Issue #13 — tighten agent roles and PR invocation logging
status: verified
last_updated: 2026-09-27
date: 2026-09-27
issue: "#13"
pr: "#14 (draft)"
tier: T1
reconstructed: false
source: ""
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: 0, ci_failures: 0 }
---

# Agent Workflow Governance

## Goal
Make MiniShop agent responsibilities and the required Issue-to-PR handoff sequence explicit, while
recording agent invocation counts in every pull request.

## Implementation Walkthrough
1. **Tighten role boundaries**: define focused DevOps, documentation, and read-only reviewer
   responsibilities.
   - File(s): `.codex/agents/devops.toml`, `.codex/agents/doc-writer.toml`,
     `.codex/agents/reviewer.toml`
2. **Gate handoffs on completion**: require the DevOps agent to report
   `IMPLEMENTATION COMPLETE` before the single documentation handoff, and require a reviewer
   only for T2 or pilot work.
   - File(s): `AGENTS.md`
3. **Record invocation counts**: add DevOps, doc-writer, and reviewer run fields to the pull
   request template.
   - File(s): `.github/pull_request_template.md`

## Decisions
No ADR was created or linked for this T1 repository-workflow change.

## Problems encountered
### Pull-request-template whitespace
- **Symptom:** `git diff --check` found trailing whitespace on the new DevOps and doc-writer
  invocation placeholder lines.
- **Root cause:** The placeholder lines were added with trailing spaces.
- **Fix:** Remove the trailing spaces before publishing the governance commit.
- **Verified by:** `git diff --check` passed for commit
  `8e9fa0f8ef022f258c4c96b5fc444f9adcc95850`.
- **Promoted to troubleshooting/AGENTS.md?** no/yes; agent guidance now requires validation
  before a PR is marked ready.

### Local Git ref write denial
- **Symptom:** Creating the Issue #13 branch locally failed because the Git ref filesystem was
  read-only.
- **Root cause:** Not recorded.
- **Fix:** The owner explicitly authorized the GitHub MCP fallback, which created the remote
  branch and its governance commit.
- **Verified by:** Draft PR #14 points to commit
  `8e9fa0f8ef022f258c4c96b5fc444f9adcc95850`.
- **Promoted to troubleshooting/AGENTS.md?** yes/troubleshooting; no/AGENTS.md.

## Verification evidence
- `git diff --check` passed.
- Python `tomllib` parsed all three agent TOML definitions.
- The updated pull-request-template invocation fields were inspected.
- No runtime, RBAC, cluster, or CI behavior changed.

## Follow-ups
- Validate and document the undocumented AGM-05 checklist trigger with the repository owner.
- Owner review is required before PR #14 is marked ready or merged.

## Related Docs
- [Git workflow](../process/git-workflow.md)
- [Issue #13](https://github.com/thanhdu-hcmus/minishop-k8s/issues/13)
- [PR #14](https://github.com/thanhdu-hcmus/minishop-k8s/pull/14)
