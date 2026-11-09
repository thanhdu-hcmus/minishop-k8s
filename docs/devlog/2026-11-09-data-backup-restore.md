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
  `db0:keys=100,expires=0`.
- Docker 27.2.0 in WSL2; kind v0.30.0; ShellCheck v0.10.0 from
  `koalaman/shellcheck:v0.10.0`.

## Changes
- **`feat(scripts)` backup:** `scripts/data-lib.sh` holds the shared helpers.
  They run commands in a kube Pod or a Docker container, read pinned image
  digests from `charts/minishop/values.yaml`, count rows and digest them per
  table, count keys and digest the key set per database, and guard the backup
  location. `scripts/backup-data.sh` writes `<root>/<UTC stamp>/` with
  `postgresql.dump`, `redis.rdb`, `manifest.txt`, and `SHA256SUMS`, and has
  `--keep N` pruning. `.gitignore` ignores `*.dump`, `*.rdb`, `/backups/`,
  `/minishop-backups/`, and `.partial-*/`.
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
    and refused a tampered set;
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

## Documentation
For doc-writer, not done here:
- An operator guide section on backing up, restoring, running the drill, the
  cadence, and the backup location, permissions, and `--keep`.
- Troubleshooting entries:
  - "rows changed during pg_dump" and "keyspace changed during the snapshot"
    (retry when quiet);
  - a leftover `/data/.minishop-restore` or a busy port 16379 after a killed
    restore;
  - "must be mode 700" on `/mnt` drives;
  - the guard message for kind-learn.
- `docs/README.md` index entries for ADR 0013 and this record.
- The legacy runbook step 6 and the #50 follow-up ("needs the #40 backups
  first") can point to `backup-data.sh`.

## Follow-up
- Owner: accept or change ADR 0013 (no CronJob, the manual cadence, plain
  files under `~/minishop-backups`). Encryption and an off-machine copy are
  open gaps.
- Owner: run `bash scripts/backup-data.sh --keep 7` before the kind rebuild
  in the #50 follow-up and before #40 parts 2 and 3.
- Issue #40 parts 2-4 (seeding, rotation, data NetworkPolicies) remain open.
  Part 4 must allow nothing new for backups, because they use `kubectl exec`,
  not the network.
- Observed while testing, not changed: Helm warned that `./.kube/config` is
  group- and world-readable. It sits on a Windows drive (`/mnt/d`), where
  chmod cannot restrict it.
