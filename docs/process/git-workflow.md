# Git workflow

Use one Issue, short-lived branch, and Draft PR for each change. Branch from updated `main` as
`<type>/<issue>-<slug>`, where type is `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`, or `test`.

Use Conventional Commits in the form `type(scope): imperative summary`. Keep commits atomic and
valid; rebase on `main` before opening a PR and never merge `main` into the branch. Do not force
push shared branches. The agent never merges PRs.

T0 work uses a `trivial` label. T1 and T2 work require a devlog entry and the PR template. T2
also requires an ADR, an owner scope sign-off, and reviewer findings before the PR is ready.

For each linked Issue, the DevOps agent works until every acceptance criterion is addressed, all
commits validate, no subtasks remain, and it reports `IMPLEMENTATION COMPLETE`. Only then does
one doc-writer handoff document the completed state. T2 and pilot changes receive one reviewer
handoff after documentation; a blocker remediation receives at most one delta review. Record the
DevOps, doc-writer, and reviewer invocation counts in the PR template.

Before publishing a PR, run the relevant validation, check for secrets, and state commands and
results in the PR body. Handle review feedback in commits, then tidy fixups once the owner says
the content is settled. After validation and all required T1/T2 handoffs, the agent sets the PR
ready for review and requests review from `thanhdu-hcmus` before asking the owner to merge. The
owner reviews and rebase-merges approved PRs.
