---
title: PostgreSQL and Redis password rotation
requirement: Issue #40 (part 3 of 4) — rotate the data passwords with the role and both Secrets together
status: implemented
last_updated: 2026-11-10
date: 2026-11-10
issue: "#40"
pr: "not recorded"
tier: T2
reconstructed: false
source: "Recorded during implementation"
metrics: { wall_time: "self-test 304 s and 494 s", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# PostgreSQL and Redis Password Rotation

## Goal
Part 3 of Issue #40: a script that rotates the data-stack password, changing
the PostgreSQL role and every Secret that holds the password together, then
restarting the readers and verifying the result. Parts 1 (backup/restore,
#54) and 2 (seed Job, #55/#56) are merged; part 4 (data NetworkPolicy) comes
later. Owner decision: authentication failures during the rotation are
acceptable, from ALTER ROLE until the backend rollout completes (measured ~39 s
in the self-test); no dual or alternating roles.

kind-learn is used read-only for discovery (object and key names). Rotation
is tested only on a throwaway kind cluster.

## Environment (observed on kind-learn, read-only, 2026-11-10)
- The application role is `minishop` (`rolsuper=t`, `rolcanlogin=t`), the only
  non-system role. The backend connects as `POSTGRES_USER=minishop` over TCP
  through Service `minishop-postgresql`.
- `pg_hba.conf`: `local` and `host 127.0.0.1/32` and `::1/128` are `trust`;
  `host all all all scram-sha-256`. `password_encryption=scram-sha-256`,
  `log_statement=none`, `log_min_duration_statement=-1`.
- Secrets holding the passwords (key names and sizes via `kubectl describe`):
  `data/minishop-data-credentials` and `webapp/minishop-app-credentials`, each
  with `postgres-password` and `redis-password` (48 bytes each). Neither has
  labels; both were created by `kubectl apply` from
  `scripts/create-{data,app}-credentials.sh`.
- Readers, found from pod templates: StatefulSet `minishop-postgresql`
  (`postgres-password`), StatefulSet `minishop-redis` (`redis-password`),
  Deployment `minishop-backend` (both keys, 3 replicas, HPA min 3). The legacy
  StatefulSet `data/redis` and Deployment `minishop-frontend` read neither.
- `webapp/postgres-app-creds` (key `password`) and `data/postgres-creds` belong
  to the legacy CNPG cluster `minishop-postgres` (database `kumademo`), a
  different server and role. No running workload references
  `postgres-app-creds`. Rotation does not touch either.

## Decisions
- **Helm does not own the Secrets.** The chart only references them by name
  (`credentials.dataSecretName`, `credentials.appSecretName`) through
  `secretKeyRef`; no template creates them, and there is no `lookup`, no
  `helm.sh/resource-policy`, and no password value. `deploy-helm.sh` only
  checks that they exist (`require_runtime_prerequisites`). A `helm upgrade`
  therefore keeps a rotated value, and there is no Helm bug to fix. The only
  thing that would revert a rotation is re-running
  `create-{data,app}-credentials.sh` (directly, from `deploy-data.sh`, or from
  `deploy-kustomize-dev.sh` with the password variables set) with old
  values. The script says so when it finishes.
- **PostgreSQL** is rotated with `ALTER ROLE` over the trusted local socket,
  so it needs no current password and still works when the Secrets are
  inconsistent. Session `log_statement`, `log_min_error_statement` and
  `log_min_duration_statement` are turned off first, so the server log never
  receives the statement. The PostgreSQL Pod is not restarted. Its
  `POSTGRES_PASSWORD` is read only by initdb on an empty volume, and its
  readiness probe uses the trusted socket.
- **Redis is included.** Redis takes `requirepass` from `$REDIS_PASSWORD` at
  start, and its probes and the backup scripts read the same environment
  variable. Rotation is therefore a Secret patch plus a rolling restart of the
  StatefulSet. AOF keeps the data, and the script checks that the key set
  without a TTL is unchanged. `CONFIG SET requirepass` was rejected because it
  would leave the container environment, the probes and `data-lib.sh` on the
  old value until a restart anyway. Redis restarts before the backend: new
  backend Pods only become ready once Redis accepts the new password.
- **Order:** ALTER ROLE, data Secret, app Secret, restart Redis, restart other
  readers, verify. Every step that was started is undone in reverse on
  failure. If the rollback also fails, the work directory, holding the
  old and new passwords, is kept, and `--recover DIR --to old|new` converges
  everything on one of them. Every step of that is idempotent.
- **Passwords** are 32 random bytes as 64 hex characters, which are safe in an
  SQL literal and in a Redis argument. They go only through stdin into psql,
  redis-cli and `kubectl patch --patch-file /dev/stdin`. Secret stderr is
  discarded, and other error output is redacted (runs of 20 or more token
  characters).

## Problems

### Discovery printed Secret values from kind-learn
- **Symptom:** a read-only discovery command listed the Secrets in `data` with
  a go-template that indexed `.metadata.labels`. Secrets without labels made
  the template fail, and kubectl's error message printed the full raw object
  list, including the `data` values of `data/minishop-data-credentials`,
  `data/postgres-creds`, and the CNPG `minishop-postgres-*` CA, server, and
  replication keys.
- **Cause:** on a template error, kubectl prints "Printing more information
  for debugging the template" followed by the whole object it was given.
  For a Secret, that object includes the base64 values. jsonpath errors do the
  same.
- **Fix:** Secrets are now listed only with `kubectl describe secret`, which
  shows key names and byte sizes but no values. The rotation script never
  shows stderr from a Secret read; it reports a fixed message instead.
- **Owner action:** the printed values are in this agent session's
  transcript. Rotate `minishop-data-credentials` with the new script once it
  is merged. `postgres-creds` and the CNPG certificates go away with the
  legacy CNPG cluster (runbook step 6); rotate them earlier only if the
  transcript is shared.

### The redactor hid the name of the failed Secret
- **Symptom:** in the first self-test run, the injected-failure message read
  `patch secret <redacted>`. Rollback and recovery worked, but the operator
  could not see which Secret had failed.
- **Cause:** the redaction pattern included `-` and `_`, so
  `minishop-app-credentials` (24 characters) counted as one token.
- **Fix:** the pattern now matches only base64 and hex characters
  (`[A-Za-z0-9+/=]{20,}`). A hyphen ends a run, so Kubernetes names survive.
  The self-test now asserts that the error names the Secret, and it still
  greps every output for the passwords.
- **Also tidied:** the restarted workloads print as `ns/kind/name`, and the
  printed `--recover` command no longer has a double space before `--to`.

### Review fixes (one batched pass, no blockers)
- **Unescaped old value in ALTER ROLE:** a rollback pastes the old password
  into an SQL literal. The pre-flight now refuses unless each old value is
  16 or more characters of `[A-Za-z0-9+/=]` ("rotate manually"). The redactor
  threshold dropped from 20 to 16 to match, so any accepted value is redacted.
- **`bash -x` would print `b64=<value>`:** the script now runs `set +x`, and
  Secret values are streamed from kubectl through `base64 -d` into a mode 600
  file or `sha256sum`, so no shell variable holds one.
- **`--recover` ignored `keys=` in `rotation.info`:** it now takes the
  components from that file and refuses a conflicting `--only`.
- **No concurrency guard:** `--apply` takes `flock -n` on
  `<state-dir>/.lock`, and each forward patch carries the `resourceVersion`
  read before the values in the pre-flight. A concurrent change fails with
  409 Conflict and triggers the rollback. The self-test covers both: a held
  lock, and a wrapper that annotates the Secret just before the patch.
- **The "few seconds" claim was wrong:** the window runs from ALTER ROLE
  until the backend rollout completes, because old backend Pods cannot open
  new connections and go NotReady once Redis restarts. The script now
  measures it and prints `client window:`. The self-test also runs a prober
  Pod next to the frontend, which requests `/items` and `/items/0/reviews`
  through the backend Service every 250 ms. Result: 38.8 s; `/items` 0 of 137
  failed (pooled PostgreSQL connections survive ALTER ROLE);
  `/items/0/reviews` 60 of 137 failed (each request opens a new Redis
  connection). ADR 0015, the operator guide and this record were corrected.
- **Nits:**
  - The closing warning names `deploy-data.sh` and `deploy-kustomize-dev.sh`.
  - An existing `--state-dir` is no longer chmodded; it must already be
    private.
  - The `--recover` hint carries `--timeout` and `--state-dir`.
  - The reader and Job scans include projected volumes and `initContainers`
    env and envFrom, and CronJobs that read the Secrets are listed.
  - Forward patches null the `last-applied-configuration` annotation, which
    held a copy of the old values.
  - `fail_recover` ignores INT, TERM and HUP.
  - The tests add `--recover --to new` and `--only redis`.

## Verification
- `bash -n` and ShellCheck v0.10.0 (`koalaman/shellcheck:v0.10.0`, `-x`)
  are clean on both scripts. No CRLF.
- `bash scripts/test-data-rotation.sh` ran on throwaway kind cluster
  `minishop-rotation-test`, which has its own kubeconfig in a `mktemp`
  directory and the node image pinned in `cluster/kind-config.yaml`. Both
  runs passed every check: the first in 304 s, and the second, on the final
  code after the fixes above, in 494 s, with the cluster deleted on exit.
  kind-learn was not written to: only `get`, `describe` and read-only `exec`
  queries were used for discovery.
- Checks covered: refusal without `--context` or with an unknown context;
  refusal without a recent backup and when the Secrets disagree; a dry run
  that leaves Secret resourceVersions, the role's verifier and every Pod UID
  unchanged; a failure after ALTER ROLE and the first Secret patch that rolls
  back automatically; a full rotation, after which the old passwords are
  rejected, Redis keys are kept, backend Pods are replaced, and `/ready`,
  `/items` and reviews return 200; a failed rollback, followed by
  `--recover --to old`; `--only postgresql`; and no password, plain or
  base64, and no 64-character hex run, in any output.
- After the review fixes, a third run passed every check in 505 s, and the
  cluster was deleted afterwards. It added:
  - refusals for a quoted old value, a non-private existing state directory
    (left at mode 755), a held lock, and a conflicting `--recover --only`;
  - a 409 rollback ("the object has been modified");
  - `--recover --to new`;
  - `--only redis` (role verifier unchanged, Redis Pod replaced);
  - the removal of the last-applied annotation.

  Client windows printed by the script across that run's five rotations:
  - full rotation: 38.8 s;
  - `--only postgresql`: 32.2 s;
  - `--only redis`: 32.2 s, measured from the Redis restart;
  - `--recover --to old`: 33.9 s;
  - `--recover --to new`: 33.7 s.

  The prober results for the full rotation are under Review fixes above.
- Not yet run against kind-learn; the owner runs it after the merge (below).

## Features implemented
- `scripts/rotate-data-credentials.sh` (fdf3c5e): dry run by default,
  `--apply`, `--only postgresql|redis`, automatic rollback, and
  `--recover DIR --to old|new`.
- `scripts/test-data-rotation.sh` (7d3f224): self-test on a throwaway kind
  cluster.
- Decision: [ADR 0015](../decisions/0015-data-credential-rotation.md)
  (proposed). Operator steps:
  [operator guide](../minishop-operator-guide.md#rotate-data-passwords).
  Failure modes: [troubleshooting](../troubleshooting.md).

## Owner steps after merge
Run in WSL on an up-to-date `main`:
1. `bash scripts/backup-data.sh`
2. `bash scripts/rotate-data-credentials.sh --context kind-learn` (dry run);
   review the plan.
3. The same command with `--apply`. Expect failures from ALTER ROLE until
   the backend rollout completes (measured ~39 s in the self-test with 2
   replicas; kind-learn runs 3, and the script prints the actual
   `client window:`).
4. `bash scripts/validate-app.sh`
5. On `ROLLBACK INCOMPLETE`, run the printed `--recover` command.
6. Update or discard any stored `MINISHOP_*_PASSWORD` values.

## Follow-ups
- Rotate `minishop-data-credentials` on kind-learn (closes out the discovery
  incident above).
- Retire or rotate `data/postgres-creds`, `webapp/postgres-app-creds`, and the
  CNPG certificates at runbook step 6, sooner if the transcript is shared.
- Issue #40 part 4: data NetworkPolicy.
- Possible: add the new Redis password beside the old one
  (`ACL SETUSER default >new` over stdin), roll the backend, then restart
  Redis, to remove the Redis part of the window (ADR 0015). Not implemented.
- PR number: not recorded at the time of writing.
