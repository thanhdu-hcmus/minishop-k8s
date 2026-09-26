---
title: PR review handoff policy
requirement: Issue #11 — require ready-for-review and owner review request
status: verified
last_updated: 2026-09-27
date: 2026-09-27
issue: "#11"
pr: "#12 (draft)"
tier: T1
reconstructed: false
source: ""
metrics: { wall_time: "N/A", usage: "N/A", review_rounds: 0, ci_failures: 0 }
---

# PR Review Handoff Policy

## Goal
Make the final MiniShop pull-request handoff explicit: an agent must not ask the owner to merge
until it has marked the validated PR ready for review and requested review from
`thanhdu-hcmus`. The agent never merges.

## Implementation Walkthrough
1. Add the final ready-for-review and owner-review-request sequence to the Git workflow.
   - File(s): `docs/process/git-workflow.md`

## Run & Verify
GitHub Actions run
[`36259646193`](https://github.com/thanhdu-hcmus/minishop-k8s/actions/runs/36259646193)
completed successfully for the initial Draft PR branch. GitHub Actions validates the final head
before it is marked ready for review.

## Related Docs
- [Git workflow](../process/git-workflow.md)
- [Issue #11](https://github.com/thanhdu-hcmus/minishop-k8s/issues/11)
- [PR #12](https://github.com/thanhdu-hcmus/minishop-k8s/pull/12)

## Implemented
- The workflow now requires an agent to set a validated PR ready for review and request review
  from `thanhdu-hcmus` before asking the owner to merge.

## Problems encountered
None.

## Verification evidence
- The change is limited to the workflow and this T1 devlog.
- GitHub Actions run `36259646193` succeeded before this evidence update.

## Follow-ups
- Apply this handoff sequence to every future MiniShop PR.
