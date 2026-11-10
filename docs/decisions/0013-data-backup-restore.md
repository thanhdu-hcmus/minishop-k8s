---
title: Data backup and restore
requirement: Issue #40 (part 1) — tested PostgreSQL and Redis backup and restore
status: proposed
last_updated: 2026-11-10
---

# Data Backup and Restore

## Goal
Record the T2 decision on how the Helm-owned data stack is backed up and
restored, where backups live, how a restore is kept away from the live
cluster, and why there is no scheduled in-cluster backup. Status is proposed;
the owner accepts it on merge.

## Prerequisites
- [Issue #40](https://github.com/thanhdu-hcmus/minishop-k8s/issues/40), part 1
  of 4. Seeding, password rotation, and data NetworkPolicies are later parts.
- [Runtime data foundation](0004-runtime-data-foundation.md) and
  [Helm packaging](0009-helm-packaging.md): StatefulSets
  `data/minishop-postgresql` (PostgreSQL 16.10) and `data/minishop-redis`
  (Redis 7.4.7, AOF on), owned by Helm release `minishop`, with credentials in
  Secret `data/minishop-data-credentials`.
- Out of scope: the legacy CNPG cluster `minishop-postgres` and StatefulSet
  `redis`, which [runbook](../legacy-retirement-runbook.md) step 6 backs up.

## Decision
1. **Logical backups, taken through `kubectl exec`.**
   `scripts/backup-data.sh` runs `pg_dump -Fc` of the application database and
   `redis-cli --rdb -` inside the running Pods and streams both to the host.
   `--rdb` uses a replication sync. With `repl-diskless-sync yes`, the Redis 7
   default (observed live, not set by the chart), Redis streams the snapshot
   and writes no file on the server; with `no` it would first save an RDB to
   `/data`. The client tools read credentials from the container environment;
   no password passes through the host shell.
2. **Backups live outside the cluster and the repository.** The default root
   is `~/minishop-backups` in WSL (override with `--backup-dir` or
   `MINISHOP_BACKUP_DIR`). The script refuses a root inside the repository, one
   it does not own, or one that is not mode 700 (which also rejects Windows
   drives under `/mnt`). Files are written with umask 077. As a second line of
   defence, `.gitignore` ignores any `backups/`, `minishop-backups/`,
   `.partial-*/` or `<UTC stamp>/` directory at any depth, with everything in
   it (`manifest.txt`, `SHA256SUMS`, `redis-cli.log`), and `*.dump` and
   `*.rdb` anywhere.
3. **A backup set is verified before it exists.** Each run builds
   `<root>/.partial-<stamp>-<pid>/` and renames it to `<root>/<UTC stamp>/`
   only after these checks pass; any failure deletes the partial set:
   - `pg_restore --list`, then a full read (`pg_restore -f /dev/null`, which
     `--list` alone does not do: it reads only the table of contents, so a
     truncated dump passes it), and `redis-check-rdb`, all from the chart's
     pinned image digests, run locally with no network and a read-only mount;
   - one TABLE DATA entry per user table;
   - the RDB ends exactly where `redis-check-rdb` reports `RDB looks OK`;
   - row counts, per-table row digests, key counts and key-set digests are equal
     before and after the dump, and the RDB's key count equals the live count.
   The set holds `postgresql.dump`, `redis.rdb`, `manifest.txt` (counts,
   digests, versions, images; no data or credentials), and `SHA256SUMS`.
   `--keep N` prunes older complete sets after a successful run, never the new
   one. A run whose stamp does not sort after the newest existing set (a clock
   that stepped back) fails before it writes.
4. **Restore needs a named target and never defaults to kind-learn.**
   `scripts/restore-data.sh --from <set>` needs `--context NAME` or
   `--docker --pg-container ... --redis-container ...`. Unless
   `--allow-kind-learn` is passed, it refuses a target when:
   - the context is named `kind-learn`, or its cluster entry is `kind-learn`;
   - the context's API server URL equals the `server:` of cluster `kind-learn`
     in the repository's `.kube/config` (kind keeps the published API port
     across restarts);
   - or, after those kubeconfig-only checks and before any write, the target
     answers `get node learn-control-plane`.
   That flag is for an owner decision to roll the live data back, and nothing
   else.
5. **Restore method.**
   - PostgreSQL: `pg_restore --clean --if-exists --no-owner --no-privileges
     --single-transaction --exit-on-error`, as the target's application user,
     with `lock_timeout=30s`. A failure rolls back.
   - Redis: the RDB is copied into the Redis container and checked against its
     sha256. A temporary `redis-server` on `127.0.0.1:16379` (`--restore-port`
     changes it), with a one-time password, serves it. The port probe sends no
     credentials and treats the port as free only on "Connection refused"; a
     temporary server that cannot listen fails the restore at once. The target
     runs `REPLICAOF` against it, then `REPLICAOF NO ONE`, retried until
     `INFO replication` shows `role:master` (bounded by `--sync-timeout`), and
     waits for the AOF rewrite. This loads the snapshot with no Pod restart and
     no change to the StatefulSet. If the target never becomes master again,
     the script says so loudly on stderr.
   - Afterwards, row counts, row digests, key counts and key-set digests must
     match the manifest exactly. If keys have a TTL, each database may hold
     fewer keys than the backup but never more, and the digest of its keys
     without a TTL must match exactly.
6. **No scheduled in-cluster CronJob for now.** Backups are manual, on this
   cadence:
   - before any risky change: a cluster rebuild or kind upgrade (the #50
     follow-up), a Helm upgrade that touches the data templates, password
     rotation (#40 part 3), a seeding change (#40 part 2), legacy retirement
     steps, or a restore;
   - otherwise weekly while the cluster is in use, with `--keep 7`;
   - a restore drill (`scripts/test-data-restore.sh --from <set>`) once a
     month, and the self-test (`scripts/test-data-restore.sh`) after any change
     to the scripts.

## Rationale
- At this size (31 KB dump, 43 KB RDB) a logical backup takes about 10 s and
  restores in about 10 s. It is also portable across clusters, which is what a
  kind rebuild needs.
- A CronJob only helps if its output outlives the cluster. kind-learn's only
  storage is node-local (`standard` and `local-path` inside the node
  containers), and `kind delete cluster` removes it. Storage that survives
  needs either a hostPath `extraMounts` in `cluster/kind-config.yaml` (a
  cluster re-creation and a cluster-wide change) or an object store such as
  MinIO (a new dependency). Both are owner decisions.
- The cluster runs on a workstation, not around the clock, so a schedule
  would miss runs. A Job that connects over the network would also need a
  NetworkPolicy allowance into `data` (part 4), and its own copy of the
  credentials through `secretKeyRef`.
- Replicating from a temporary server is how Redis itself loads a data set
  into a running instance. The alternatives need a restart and deleting
  `appendonlydir` (AOF takes precedence over `dump.rdb` at start), or
  `DEBUG RELOAD`, which `enable-debug-command no` blocks.

## Alternatives Considered
- **`pg_dumpall` or `--globals-only`.** It would put role password hashes in
  the backup. Roles come from the Secret and the image's first start instead.
  Rejected.
- **WAL archiving or PITR (pgBackRest, CNPG backups).** These add an operator
  or a new tool and an archive target, which is too much for 100 rows. Revisit
  if the data or the RPO needs grow.
- **Volume snapshots.** The kind local-path provisioner has no CSI snapshot
  support.
- **Copying `/data/appendonlydir` or `dump.rdb` with `kubectl cp`.** The AOF
  files can change while they are copied, and a current `dump.rdb` needs a
  `BGSAVE` first, which writes on the server. `--rdb` gives a point-in-time
  snapshot with no server-side file.
- **An in-cluster CronJob writing to a PVC.** It would be lost with the
  cluster, which is the failure a backup is for.

## Consequences
- Backups are plain, unencrypted files protected only by file mode, with one
  copy on the same machine. Losing the WSL disk loses them. Encryption (for
  example `age`) and an off-machine copy are known gaps and need owner
  decisions.
- RPO is the time since the last manual backup. RTO for this data is about
  10 s of restore, plus a cluster and chart deploy if the cluster is gone.
- A restore needs the target's Secrets and StatefulSets first. The backup
  holds no roles or passwords, so the target keeps its own role password, and
  restoring after a rotation (part 3) does not undo the rotation.
- `SHA256SUMS` sits next to the files it covers, so it catches corruption and
  accidental change, not deliberate tampering: anyone who can write the set
  can rewrite the sums. Protection against tampering would need a signature or
  a copy of the sums kept elsewhere.
- A PostgreSQL restore leaves tables that exist only in the target, and warns
  about them. If such a table has a foreign key to a table in the backup,
  `--clean` cannot drop the referenced table, so the restore fails and rolls
  back (shown by the self-test); drop or detach the extra table first.
- During a Redis restore the target is briefly a read-only replica, so
  backend writes fail for a few seconds. With `repl-diskless-load disabled`
  (the default, as live), the target clears its data once the snapshot has
  arrived, just before it loads it, so a failure while loading leaves Redis
  empty until the restore is run again. A leftover
  `/data/.minishop-restore` (after the script is killed) blocks the next
  restore until it is removed.
- The backup forks Redis for the transfer (copy-on-write). `rdb_last_cow_size`
  read 847,872 and 917,504 bytes on 2026-11-09 (implementation record,
  Environment), well within the 256Mi limit. `pg_dump` takes ACCESS SHARE
  locks only.
- The backup fails, rather than recording mismatched counts, if PostgreSQL rows
  or the Redis key set change while it runs. A busy key space with TTLs would
  need a different consistency check.

## Verification
Recorded in the implementation record. A Docker self-test covers the round
trip, AOF persistence, and the guards. A backup from kind-learn was restored
into throwaway Docker containers and into a throwaway kind cluster. Counts and
digests matched, including after the throwaway Pods were recreated, and
kind-learn's node containers and data Pods were unchanged.

## Related Docs
- [Data backup and restore record](../devlog/2026-11-09-data-backup-restore.md)
- [Issue #40](https://github.com/thanhdu-hcmus/minishop-k8s/issues/40)
