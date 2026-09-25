# Git workflow

Use one Issue, short-lived branch, and Draft PR for each change. Branch from updated `main` as
`<type>/<issue>-<slug>`, where type is `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`, or `test`.

Use Conventional Commits in the form `type(scope): imperative summary`. Keep commits atomic and
valid; rebase on `main` before opening a PR and never merge `main` into the branch. Do not force
push shared branches. The agent never merges PRs.

T0 work uses a `trivial` label. T1 and T2 work require a devlog entry and the PR template. T2
also requires an ADR, an owner scope sign-off, and reviewer findings before the PR is ready.

Before publishing a PR, run the relevant validation, check for secrets, and state commands and
results in the PR body. Handle review feedback in commits, then tidy fixups once the owner says
the content is settled. The owner reviews and rebase-merges approved PRs.
