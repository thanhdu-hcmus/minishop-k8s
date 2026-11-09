---
title: Tested PostgreSQL and Redis backup and restore
requirement: Issue #40 (part 1 of 4) — tested backup and restore for the data stack
status: implemented
last_updated: 2026-11-10
date: 2026-11-09
issue: "#40"
pr: "not recorded"
tier: T2
reconstructed: false
source: "Recorded during implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# Tested PostgreSQL and Redis Backup and Restore

## Goal
Give the Helm-owned data stack (`data/minishop-postgresql`,
`data/minishop-redis`, release `minishop`) a backup that only reads from the
cluster, a restore that checks its own result, and a recorded drill. Issue #40
is split into four PRs; this is part 1. Seeding (`POST /upload`), password
rotation, and data NetworkPolicies are parts 2-4. The legacy CNPG cluster
`minishop-postgres` and StatefulSet `redis` are out of scope (runbook step 6).

kind-learn was used read-only: the backup runs `pg_dump` and `redis-cli --rdb`
through `kubectl exec`, and nothing was restored, restarted, scaled, or deleted
there. Restores were tested on throwaway Docker containers and a throwaway
kind cluster.

## Environment (observed 2026-11-09)
- PostgreSQL 16.10 (`postgres@sha256:38471f33...`), database and role
  `minishop`, user tables `public.marketitems` and `public.runtime_validation`.
- Redis 7.4.7 (`redis@sha256:976ab0f0...`), AOF on (`appendfsync everysec`),
  default save points, `repl-diskless-sync yes`, `enable-debug-command no`,
  `db0:keys=100,expires=0`. The chart sets neither diskless option; both are
  Redis 7 defaults. Read again during the review fixes: `repl-diskless-load
  disabled`. `rdb_last_cow_size` was 847,872 bytes in the first inspection and
  917,504 bytes in the review-fix run (about 0.9 MB against the 256Mi limit).
- Docker 27.2.0 in WSL2; kind v0.30.0; ShellCheck v0.10.0 from
  `koalaman/shellcheck:v0.10.0`.

## Changes
- **`feat(scripts)` backup:** `scripts/data-lib.sh` holds the shared helpers.
  They run commands in a kube Pod or a Docker container, read pinned image
  digests from `charts/minishop/values.yaml`, count rows and digest them per
  table, count keys and digest the key set per database, and guard the backup
  location. `scripts/backup-data.sh` writes `<root>/<UTC stamp>/` with
  `postgresql.dump`, `redis.rdb`, `manifest.txt`, and `SHA256SUMS`, and has
  `--keep N` pruning. `.gitignore` ignores `*.dump` and `*.rdb` anywhere, and
  any `backups/`, `minishop-backups/`, `.partial-*/` or `<UTC stamp>/`
  directory at any depth (broadened in the review fixes).
- **`feat(scripts)` restore:** `scripts/restore-data.sh` checks the set's
  checksums and restores into a named kube context or into Docker containers.
  It refuses kind-learn without `--allow-kind-learn`, then checks counts and
  digests against the manifest. `--only postgresql|redis` restores one
  component.
- **`test(scripts)`:** `scripts/test-data-restore.sh` runs a self-test on
  throwaway containers. With `--from <set>` it is a restore drill.
- **`docs(decisions)`:** `docs/decisions/0013-data-backup-restore.md`, status
  proposed. It covers the method, the storage location, the kind-learn guard,
  no CronJob, and the manual cadence.
- **Review fixes (one batched pass, no Blockers):** see "Review findings"
  under Problems. The four scripts are also committed as 100644, like the
  rest of `scripts/`, folded into the commits that add them.

## Decisions
- No CronJob. In-cluster storage dies with `kind delete cluster`, and storage
  that survives needs a cluster-wide change or a new dependency. Manual cadence
  instead: before risky changes, weekly with `--keep 7`, and a drill each
  month. Rationale in ADR 0013.
- Redis restore loads the RDB by replicating from a temporary in-container
  server. It needs no Pod restart, no deleted AOF, and no `DEBUG` command
  (`enable-debug-command no`).
- No `pg_dumpall` or globals, so the backup holds no role password hashes.
- Verification uses the chart's pinned images on the host (`--network none`,
  read-only mount, caller's uid), so nothing is written into the source Pods.
- Counts alone cannot show that the contents match. The manifest also records
  an md5 of each table's ordered rows and a sha256 of each database's sorted
  key names. These are digests, so no data is printed. Redis value integrity
  comes from the RDB CRC64 (`redis-check-rdb`) and a sha256 check after the
  copy into the container.

## Problems

### `redis-cli --rdb -` keeps the end-of-stream marker on stdout
- **Symptom:** A prototype snapshot was 251 bytes, but redis-cli reported
  `Transfer finished with success after 211 bytes`, and `redis-check-rdb`
  finished at offset 211.
- **Cause:** With diskless replication the server ends the stream with a
  40-byte EOF marker. redis-cli removes it with `ftruncate`, which it skips
  when the output is `-` (a pipe).
- **Fix:** `backup-data.sh` reads the payload length from redis-cli's status
  line, truncates the file to it when the file is exactly 40 bytes longer, and
  fails on any other size. It then requires `redis-check-rdb` to report
  `RDB looks OK` at an offset equal to the file size.

### The temporary Redis server's key check counted only db0
- **Symptom:** The first self-test failed with `the temporary server did not
  load the expected 102 keys`; the synthetic data had 100 keys in db0 and 2 in
  db1.
- **Cause:** The in-container check used `DBSIZE`, which counts only the
  selected database.
- **Fix:** Sum `keys=` over every `dbN` line of `INFO keyspace`.
- **Verified by:** The self-test passed on the next run.

### The first kind-learn set had no digests
- **Symptom:** The first kind-learn backup (`20261109T165601Z`) and its Docker
  drill passed, but the manifest held only counts. Counts do not show that the
  contents match.
- **Fix:** Added the row and key-set digests to the backup and restore, then
  took a new backup. `--keep 1` pruned the older set.

### Review findings (one batched pass)
The reviewer found no Blockers. The five Should-fix items and nine Nits were
fixed together; each fix below has a self-test case unless noted.
- **`pg_restore --list` passed a truncated dump.** It reads only the table of
  contents. The backup now also runs `pg_restore -f /dev/null`, which reads
  every data block. Test: a `pg_dump` wrapper that drops the last 200 bytes;
  the backup fails with `pg_restore could not read the whole dump`.
- **The kind-learn guard matched names only.** It now also refuses a context
  whose API server URL equals the `server:` of cluster `kind-learn` in the
  repository's `.kube/config`, and, after those kubeconfig-only checks and
  before any write, a target that answers `get node learn-control-plane`.
  Tests: a renamed context with the same URL (fake live kubeconfig through
  `MINISHOP_LIVE_KUBECONFIG`, unreachable ports), and a stub `kubectl` whose
  target has the node.
- **`--keep` could prune the new set after a clock step back.** The prune loop
  skips the new stamp. The backup refuses, before it writes and again before
  the rename, a stamp that does not sort after the newest set. Test: a
  `29991231T235959Z` set makes the backup fail, and the older set survives.
- **A failed `REPLICAOF NO ONE` in cleanup could leave Redis a read-only
  replica.** Promotion is retried until `INFO replication` shows
  `role:master`, bounded by `--sync-timeout`. If it never does, stderr says
  `!!! The target Redis is still a replica ... Run REPLICAOF NO ONE`. Not
  exercised by a failing case: every restore runs the success path, and a
  failed restore was checked to leave the target master.
- **The free-port probe sent the target password and counted NOAUTH as
  free.** It now runs with `REDISCLI_AUTH` unset and treats the port as free
  only on `Connection refused`. A temporary server that cannot listen fails at
  once (`Failed listening` in its log, or no live pid after 2 s).
  `--restore-port` moves it. Tests: a password-protected server on 16379 stops
  the restore and records `acl_access_denied_auth:0`; `--restore-port 16380`
  succeeds; a wrapper that binds `192.0.2.1` fails in under 30 s.
- **Nits:**
  - the partial set is `.partial-<stamp>-<pid>`, the trap is set after its
    `mkdir`, and the rename uses `mv -T`;
  - the key-set digest uses `sort -u`, because SCAN may repeat a key;
  - the dump comment says the before/after check misses only a change
    reverted during the dump;
  - cleanup reads the temporary server's pid, sends `SHUTDOWN NOSAVE`, kills
    the pid if it is still alive, and waits for the port to close before
    removing the directory;
  - with keys that have a TTL, each database may hold fewer keys than the
    backup, never more, and a new manifest digest
    (`redis_persistent_keyset_sha256`) of the keys without a TTL must match.
    Test: a `session:1` key with `EX 3600`;
  - documentation: the diskless-load cause, the diskless-sync condition, the
    `.gitignore` list, the limits of `SHA256SUMS`, and the foreign-key
    rollback (test: a target-only table referencing `marketitems` makes the
    restore fail and leaves 100 rows);
  - file modes are 100644.

### Port 1 did not fail to bind in Docker
- **Symptom:** The first fast-fail test used `--restore-port 1`, expecting a
  non-root bind to fail; the restore succeeded instead.
- **Cause:** Docker sets `net.ipv4.ip_unprivileged_port_start=0` in the
  container, so uid 999 may bind port 1.
- **Fix:** The test puts a `redis-server` wrapper first on the image's PATH
  (`/usr/local/sbin`) that appends `--bind 192.0.2.1`, an address the
  container does not have. The last `--bind` wins, so only the temporary
  server fails.

### The port tests used a pruned set
- **Symptom:** `Error: .../20261109T172511Z is not a directory`.
- **Cause:** The earlier `--keep 2` case had pruned the first set.
- **Fix:** The port tests use the newest set.

## Verification
- **Lint:** `bash -n` and ShellCheck v0.10.0 (container, with and without
  `-x`) are clean on all four scripts, which use LF line endings. Nothing under
  `charts/` or `manifests/` changed, so the chart and manifest validators were
  not needed.
- **Self-test** (`bash scripts/test-data-restore.sh`, 44 s): 100 + 2 synthetic
  rows and 100 + 2 keys (db0 and db1) were restored over stale data. Checked:
  - counts, digests, and `sum(price)` matched, and the stale keys were gone;
  - the restored keys survived a Redis restart (AOF), and a second restore
    over the restored data passed;
  - a forged row digest was detected;
  - restore refused kind-learn, refused a context aliasing the kind-learn
    cluster (fake kubeconfig, unreachable server), refused a missing target,
    and refused a tampered set. `SHA256SUMS` sits beside the files, so it
    catches corruption and accidental edits, not deliberate tampering by
    someone who can rewrite the sums too;
  - backup refused a directory inside the repository;
  - backup failed closed with Redis stopped, and when redis-cli failed after
    the dump was written, leaving no partial set;
  - `--keep 2` pruned the oldest set;
  - directories were 700 and files 600.
- **Drill, kind-learn backup** (`bash scripts/backup-data.sh --keep 1`, set
  `20261109T165932Z`, 9 s in the script, 10.3 s wall):
  - `postgresql.dump`: 31,079 bytes, sha256
    `d35bfa26067fd301a70adece5a7ffd17aec5a2ccf813553570b3b83ba3f9c3c4`;
    `pg_restore --list` OK, 6 entries, 2 TABLE DATA.
  - `redis.rdb`: 43,523 bytes, sha256
    `3351e3f44839c0bc286533d3cbb083edc630194dd3775361ee486881e2f99216`;
    `redis-check-rdb` OK, 100 keys, 0 with expiry.
  - `manifest.txt`: 845 bytes, sha256
    `c9028e54aa554e2f60cb3d72be646a4e13f0069fac87212d8456609623413586`.
  - Rows `public.marketitems=100` (md5 `945d6e161bfe3f369dc02393fdc8b8bc`)
    and `public.runtime_validation=0`. Keys `db0=100` (key-set sha256
    `2bd3009d...7ab7445d56`).
- **Drill, Docker target** (`bash scripts/test-data-restore.sh --from
  ~/minishop-backups/20261109T165932Z`, restore 7 s, 10.0 s wall): checksums
  OK. 100 marketitems rows and 100 keys, with digests equal to the manifest.
  The keys were still there after a Redis restart.
- **Drill, kube target** (throwaway kind cluster `i40`):
  - Setup: the pinned node image, one node, created in 42.8 s, separate
    kubeconfig under `/tmp/i40`. The only host port was the API server on
    127.0.0.1. Only the chart's `postgresql.yaml` and `redis.yaml` were
    applied, with a random-password Secret.
  - `bash scripts/restore-data.sh --from ... --kubeconfig /tmp/i40/kubeconfig
    --context kind-i40` took 9 s (10.0 s wall); counts and digests matched.
  - After both Pods were deleted and came back, `backup-data.sh --context
    kind-i40` produced a manifest whose rows, md5s, keys, key-set digests, and
    versions were identical to the kind-learn set. This shows the restore
    persists (PVC and AOF) and covers the backup's kube path with a non-default
    context.
  - The cluster was then deleted.
- **kind-learn unchanged:** node containers `4f68bebe0962`, `a6167f9332e0`,
  `dbb7dcb7ce79`, and `f2fbef4e7960` kept StartedAt `2026-11-09T15:49:55Z` and
  0 restarts. `minishop-postgresql-0` (uid `31decfbf...`) and
  `minishop-redis-0` (uid `649d226f...`) kept 4 restarts and start time
  `15:50:07Z`. Both were compared before and after each drill.
- **No data in the repository:** `git ls-files` and the untracked list show
  no `*.dump`, `*.rdb`, or backup directory. The backup root
  `~/minishop-backups` is 700.
- **Review fixes** (2026-11-10 local, 2026-11-09 UTC):
  - Self-test: 24 PASS lines in 74 s. That is the cases above plus a
    truncated dump, the foreign-key rollback, a renamed context with the
    kind-learn URL, a target with node `learn-control-plane`, a clock step
    back, a TTL key, a taken port, a probe that sends no password,
    `--restore-port`, and a bind failure.
  - ShellCheck v0.10.0 (container, with and without `-x`) and `bash -n` are
    clean on every commit. `git diff --check` is clean, and `git check-ignore`
    covers set files at any depth (no tracked file is newly ignored).
  - kind-learn backup into a `mktemp -d` root, set `20261109T173157Z`, 10 s
    in the script and 10.6 s wall. The output showed counts, sizes and
    checksums only:
    - `postgresql.dump` 31,079 bytes,
      `b5d22d46f534400065d18fd434c49c2a96d5f4109a2f31fed702c205ba049f6c`;
      `--list` and the full read OK.
    - `redis.rdb` 43,523 bytes,
      `8608b9b71281addb940cde0ad7b46ec935898a9f9fcd83609ee936dfcab610e9`.
    - `manifest.txt` 945 bytes,
      `9911ee5756b201efb1070f3f96acd35d3e11fb75da38bc96cea3b8652f7a4dc4`.
    - The row md5s and the key-set digest are unchanged from
      `20261109T165932Z`.
  - Drill of that set into throwaway containers: 100 rows and 100 keys,
    digests equal, keys kept after a Redis restart. Restore 6 s, 9.0 s wall.
    The temporary root was then deleted.
  - Kube path re-run on a new throwaway `i40` (created in 42 s; deleted
    afterwards). `get node learn-control-plane` was NotFound, the restore
    passed the guard and matched in 11 s, and `/data` held no leftover
    `.minishop-restore`.
  - kind-learn: the same four node container IDs and StartedAt, and the same
    data Pod uids and restart counts, before and after.

- **Provenance:** the timings, sizes, checksums, container IDs, and Pod
  details above come from devops's runs on 2026-11-09. doc-writer checked the
  described behaviour (guards, messages, restore method, verification steps,
  `.gitignore` entries) against the scripts in this branch, but did not rerun
  any command, so the measured values are not independently verified. The
  ADR's copy-on-write figure is now recorded under Environment.

## Documentation
- [Operator guide](../minishop-operator-guide.md#back-up-and-restore-data):
  "Back up and restore data" covers commands, location and permissions,
  `--keep`, the drill and self-test, the cadence, and the `--allow-kind-learn`
  rule.
- [Troubleshooting](../troubleshooting.md): data changed during the backup, a
  leftover `/data/.minishop-restore` or busy port 16379, a Redis left empty by
  a failed restore, "must be mode 700" on `/mnt`, and the kind-learn guard,
  quoted from the scripts.
- [Docs index](../README.md): ADR 0013 and this record.
- [Legacy retirement runbook](../legacy-retirement-runbook.md) step 6,
  [ADR 0012](../decisions/0012-kindnet-resource-limits.md) Alternatives
  Considered, and the [Issue #50 record](./2026-11-08-kindnet-iptables-lock.md)
  Follow-up now point to `backup-data.sh`.

## Follow-up
- Owner: accept or change ADR 0013 (no CronJob, the manual cadence, plain
  files under `~/minishop-backups`). Encryption and an off-machine copy are
  open gaps. Also by design and not changed: roles and passwords are not in
  the backup, and tables that exist only in the target survive a restore with
  a warning.
- Owner: run `bash scripts/backup-data.sh --keep 7` before the kind rebuild
  in the #50 follow-up and before #40 parts 2 and 3.
- Issue #40 parts 2-4 (seeding, rotation, data NetworkPolicies) remain open.
  Part 4 must allow nothing new for backups, because they use `kubectl exec`,
  not the network.
- Observed while testing, not changed: Helm warned that `./.kube/config` is
  group- and world-readable. It sits on a Windows drive (`/mnt/d`), where
  chmod cannot restrict it.
