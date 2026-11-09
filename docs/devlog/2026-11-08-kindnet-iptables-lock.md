---
title: kindnet resource limits starve iptables listings and hold the xtables lock
requirement: Issue #50 — stop hung kindnetd iptables listings holding the lock
status: implemented
last_updated: 2026-11-08
date: 2026-11-08
issue: "#50"
pr: "not recorded"
tier: T2
reconstructed: false
source: "Recorded during implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# kindnet Resource Limits Starve iptables Listings

## Goal
Find why kindnetd's `iptables -t nat -S --wait` runs for minutes on kind-learn
while it holds `/run/xtables.lock`, and give a fix that survives Docker
restarts. kind-learn was accessed read-only: nothing was applied, killed,
deleted, or restarted on it. Fixes were tested on a throwaway cluster `xt50`.

## Environment (observed 2026-11-08)
- kind v0.30.0 (go1.24.6), Docker 27.2.0 (cgroup v2, cgroupfs driver, 20
  CPUs, 15.5 GiB), WSL2 kernel `6.18.54.1-microsoft-standard-WSL2`.
- Node image `kindest/node:v1.30.13@sha256:397209b3...` (from kind v0.29.0),
  containerd 2.1.1, Debian 12, `iptables v1.8.9 (legacy)`.
- kindnet DaemonSet: image `docker.io/kindest/kindnetd:v20250512-df8de77b`,
  requests and limits of 100m CPU and 50Mi memory (Guaranteed QoS). kube-proxy
  `v1.30.13` in `iptables` mode.
- Kernel config (`/proc/config.gz`): `CONFIG_NF_TABLES=y`, `CONFIG_NFT_NAT=y`,
  `CONFIG_NFT_COMPAT=m`, `CONFIG_NETFILTER_XTABLES=y`,
  `CONFIG_NETFILTER_XTABLES_LEGACY=y`, `CONFIG_IP_NF_IPTABLES_LEGACY=m`,
  `CONFIG_CFS_BANDWIDTH=y`. Both the legacy and nftables back ends are present.

## Root cause
The kindnet container's limits, not the iptables back end.

1. The kindnetd binary is 80,200,687 bytes of file-backed code. Once its page
   cache is charged to the kindnet container, it does not fit beside the
   heap (about 13 MB) under the 50Mi memory limit.
2. The kernel then reclaims and refaults the binary's pages without end. On
   learn-worker3, about two hours after the Docker start, the kindnet cgroup
   showed `memory.current` 52,027,392 of `memory.max` 52,428,800, `file`
   38,375,424, `anon` 12,148,736, `workingset_refault_file` 78,221,419,
   `pgscan_direct` 143,949,195, and `memory.events max` 44,563. There was no
   OOM kill.
3. Reclaim runs as system time inside the 100m CPU quota. `cpu.stat` showed
   `system_usec` 690,514,963 against `user_usec` 2,745,713, and 69,174 of
   69,431 periods throttled. `cpu.pressure` was `some avg10=76.56`.
   learn-worker2 and learn-control-plane matched.
4. Every child of kindnetd runs in the same cgroup. `/proc/<pid>/cgroup` of the
   listing named kindnetd's container scope. The listing on learn-worker2
   (age 618 s) had `schedstat` 1.52 s on CPU and 612.7 s waiting on the run
   queue. Its kernel stack was in `filemap_fault` → `folio_wait_bit_common`
   (state D), or `exc_page_fault` → `irqentry_exit_to_user_mode` →
   `task_work_run` (state R, `/proc/<pid>/syscall` = `running`). So it was not
   spinning in user space (`utime` 0). It was faulting its own code back in
   and being throttled.
5. kindnetd's other iptables children crawl the same way. A later read-only
   pass found `iptables -t nat -C POSTROUTING ... -j KIND-MASQ-AGENT ...
   --wait` in state R on learn-worker. The listing keeps `/run/xtables.lock`
   (fd 3) for its whole life.
   `/proc/locks` on learn-worker2 showed nine waiters queued behind it.
   kube-proxy gave up after 5 s (`Another app is currently holding the xtables
   lock. Stopped waiting after 5s.`, 88 times in two hours on learn-worker2), so
   Service rules went stale on that node.

Why it starts after a Docker restart: the page cache is charged to the cgroup
that first reads a page. On a new cluster the binary's pages are already
cached from image unpacking, so kindnet's cgroup held only 81,920 bytes of
file cache and nothing thrashed. After a Docker Desktop restart the cache is
cold, so kindnetd reads its own binary into its own cgroup. It is not only a
Docker restart effect, though. When kindnetd restarted on learn-worker2 at
about 16:07Z (see the kindnet panic under Problems), the new container
thrashed again.

Upstream kind found the same thrash on slow disks
([kind#4215](https://github.com/kubernetes-sigs/kind/issues/4215)). Checked
with `gh` on 2026-11-08:
- kind#4215 closed 2026-07-22T14:29:49Z.
- PR #4220 (memory limit) merged 2026-07-22T14:29:48Z. PR #4223 (CPU limit)
  merged 2026-07-22T21:49:53Z. Both change only
  `pkg/build/nodeimage/const_cni.go`.
- Both commits are in `compare v0.32.0...v0.33.0`. v0.33.0 was published on
  2026-08-26 with kindnetd `v20260820-69b56db7`, and still requests 100m CPU
  and 50Mi memory. v0.29.0 through v0.32.0 set both limits.
- v0.30.0 added `priorityClassName: system-node-critical`. v0.29.0, which
  built the pinned node image, has none.

kind bakes the CNI manifest into the node image:
`/kind/manifests/default-cni.yaml` in learn-control-plane holds the 100m/50Mi
limits, and kind's `installcni` action reads that file. So upgrading the kind
binary alone does not change it.

### Who issues the queued `iptables -t filter -S INPUT 1 --wait`
They run in `containerd.service`. The newest ones had parent
`/opt/cni/bin/portmap`, the CNI plugin that containerd calls on
RunPodSandbox and StopPodSandbox. Older ones had been reparented to the node's
`/sbin/init` after their portmap parent ended. This matches the sandbox
failures and the Pod stuck Terminating on learn-worker2. They waited in
`locks_lock_inode_wait` behind kindnetd's listing.

### Ruled out
- **Table size or a libiptc loop.** `iptables-save -t nat` returns 288 lines
  at once on every node. On `xt50`, the same `iptables -t nat -S --wait` took
  0.10 s from the node's `init.scope` and 5.95 s inside the thrashing kindnet
  container, with the same binary and table.
- **A missing nftables back end.** `iptables-nft -t nat -S` works in the node
  (`iptables v1.8.9 (nf_tables)`). kindnetd already programs `table inet
  kindnet-network-policies` and logs `Syncing nftables rules`.
- **strace and perf.** Neither exists in the node image, so they were not run.

## Diagnosis commands
Read-only on any kind node (here `learn-worker2`):

```bash
# Long-running iptables processes, their state, CPU ticks and owning cgroup
docker exec learn-worker2 sh -c 'for p in /proc/[0-9]*; do
  c=$(tr "\0" " " <$p/cmdline 2>/dev/null); case "$c" in *iptables*) ;; *) continue;; esac
  echo "${p#/proc/} $(cut -d" " -f3,14,15 $p/stat) $(cat $p/wchan) $(grep -o "[^/]*$" $p/cgroup) :: $c"
done'
# Lock holder and waiters (first column after the lock number is the PID)
docker exec learn-worker2 cat /proc/locks
# Kernel stack and run-queue wait of one PID
docker exec learn-worker2 sh -c 'cat /proc/<pid>/stack /proc/<pid>/schedstat'
# Memory and CPU pressure of the kindnet container
docker exec learn-worker2 sh -c 'kp=$(pgrep -xo kindnetd);
  d=/sys/fs/cgroup$(sed -n "s/^0:://p" /proc/$kp/cgroup);
  cat $d/memory.max $d/memory.current $d/cpu.stat;
  grep -E "^(anon|file|workingset_refault_file|pgscan_direct) " $d/memory.stat'
# kube-proxy giving up on the lock
kubectl --context kind-learn -n kube-system logs <kube-proxy-pod> --since=1h | grep -c 'xtables lock'
```

Signature: `memory.current` at `memory.max`, `workingset_refault_file`
rising by thousands per second, `nr_throttled` close to `nr_periods`.

## Changes
- **`fix(cluster)`**: new `scripts/tune-kindnet-resources.sh`. With no
  argument it checks and runs a server dry-run of the patch. With `--apply` it
  patches the kindnet DaemonSet and waits up to 180 s for the rollout. The new
  resources are requests of 100m CPU and 128Mi memory, a 256Mi memory limit,
  and no CPU limit, plus `priorityClassName: system-node-critical`. It refuses
  unless `kube-system/kindnet` has exactly one container, `kindnet-cni`,
  running a `docker.io/kindest/kindnetd:` image, and says it "Could not read
  DaemonSet" on a missing object or an API error. It warns if the image is not
  the measured `v20250512-df8de77b`. It skips a DaemonSet that has no limits
  (the kind v0.33.0+ manifest), so it never adds back a limit upstream removed.
  The JSON patch carries a `test` op on the container name. It does nothing if
  the resources and priority class are already set. On a rollout timeout it
  prints the inspect and `rollout undo` commands with
  `KUBECONFIG=<path>`. `scripts/create-cluster.sh` applies it after it creates
  a cluster. For an existing cluster it only runs the check, and a failed check
  prints a warning instead of failing the script. It also gained
  `# shellcheck disable=SC1091`, like the other scripts.
- **`docs(decisions)`**: `docs/decisions/0012-kindnet-resource-limits.md`,
  status proposed.

## Decisions
- Patch the resources rather than move to nftables mode. The thrash slows
  every process in the kindnet cgroup, including the portmap and sandbox paths,
  whatever the back end is.
- Keep a memory limit (256Mi, twice the request) to bound a leak, and drop the
  CPU limit, as upstream did. The Pod becomes Burstable, so the patch also
  sets `system-node-critical`. kindnet has no priority class today (Pod
  priority 0), and kindnetd's `oom_score_adj` of -997 comes only from
  Guaranteed QoS (read on all four kind-learn nodes). Without the class, a
  Burstable Pod with priority 0 would be an early OOM victim.
- No helper that kills hung listings. A new one hung within about three
  minutes, and killing a listing makes kindnetd panic and restart (see
  Problems). It is a last resort, not a fix.
- `create-cluster.sh` fixes new clusters. kind-learn waits for the owner.

## Problems

### Issue evidence said the listing spun in user space
- **Symptom:** `/proc/<pid>/syscall` read `running` and the state was R.
- **Cause:** `running` only means the task was not blocked in a syscall. Its
  `utime` was 0 and its `stime` was low, `schedstat` showed 612 s waiting on
  the run queue, and the stack was in page-fault handling.
- **Fix:** Diagnosed from the cgroup's `cpu.stat` and `memory.stat` instead.

### The thrash did not reproduce on a new cluster
- **Symptom:** On a new `xt50`, kindnet sat at 11 MB with 81,920 bytes of file
  cache and no refaults.
- **Cause:** The binary's pages were already cached and charged to another
  cgroup when the image was unpacked.
- **Tried:** Simulated a cold cache, as after a Docker Desktop restart. On
  `xt50-worker` only: `crictl stop` the kindnet container, then
  `dd if=<snapshot>/bin/kindnetd iflag=nocache count=0` to drop that file's
  page cache, then let kubelet restart the container.
- **Result:** Reproduced. Over 30 s: `memory.current` 52,072,448 of
  52,428,800, `file` 40,153,088, refaults +401,103, `pgscan_direct` +887,852,
  CPU 3,015 ms (the whole quota), 301 of 301 periods throttled. kindnet's
  `iptables -t nat -S` took 5.95 s against 0.10 s outside the cgroup. A second
  run with the limits restored gave +579,926 refaults in 60 s, 600 of 602
  periods throttled, and 7.29 s against 0.12 s.

### Client test Pods failed with `agnhost` arguments
- **Symptom:** The first routing test reported 0 of 20 connects. The client
  Pods were in `Error`.
- **Cause:** `kubectl run ... -- /agnhost pause` passed `/agnhost` as an
  argument to the image entrypoint `/agnhost`.
- **Fix:** `kubectl run --command -- /agnhost pause`. The DNAT check in that
  run was still valid.

### The routing failure did not reproduce on the two-node cluster
- **Symptom:** With the original limits and a cold cache, the rollout test
  still passed on both nodes, and kube-proxy logged no lock errors.
- **Cause:** On the idle two-node `xt50`, a thrashing listing took 6-7 s. On
  kind-learn, with more rules, Pods, and NetworkPolicies, it takes 4-30
  minutes, far beyond kube-proxy's 5 s wait. The slowdown reproduced; the
  outage needs kind-learn's load.
- **Fix:** None. Recorded as a test limit.

### kindnet panicked when a hung listing was killed
- **Symptom:** kindnet Pod `kindnet-6trpd` on learn-worker2 restarted at
  2026-11-08T16:07:07Z (restart 6). Its previous container ended with
  `panic: Can't synchronize rules after 3 attempts: failed to list chains:
  running [/usr/sbin/iptables -t nat -S --wait]: exit status -1`.
- **Cause:** At about 16:07Z, to clear the lock before the #38 cutover, the
  owner ran (per the owner's session record; the log shows only that the
  listing died from a signal) a guarded helper that killed kindnetd-owned `iptables -t nat -S`
  listings. kindnetd treats a killed listing as a failed sync and panics after
  three attempts.
- **Result:** The new container thrashed again. Its listing on learn-worker2
  was 618 s old and still running when it was sampled at 16:18Z, so the cause
  is not only a Docker restart.
- **Fix:** Recorded. Killing listings is a last resort that restarts kindnet;
  the resource and priority patch is the fix.

### The first patch dropped kindnet's OOM protection (review blocker)
- **Symptom:** The first version of the ADR and this record said kindnet
  "keeps `system-node-critical` priority". The reviewer found that the live
  DaemonSet and the v0.29.0 manifest have no `priorityClassName`.
- **Cause:** kindnet Pods run at priority 0. kindnetd's `oom_score_adj` of
  -997 came only from Guaranteed QoS, which the patch removes. As a Burstable,
  non-critical Pod it would have had a high `oom_score_adj`.
- **Fix:** The patch also adds `priorityClassName: system-node-critical`, the
  idempotence check covers it, and the check output shows it.
- **Verified by:** See the priority results under Verification.

### ShellCheck SC1091 on the new source line
- **Symptom:** ShellCheck v0.10.0 without `-x` reported SC1091 (info) on
  both scripts. CI runs it that way, and info findings fail it.
- **Fix:** Used the repository's existing `# shellcheck disable=SC1091`
  pattern. `create-cluster.sh` lacked it before and failed the same way.

## Verification
- Throwaway cluster `xt50` (control plane and one worker, the same pinned node
  image, no port mappings, separate kubeconfig under `/tmp/i50`):
  - Cold cache with the original limits: thrash and slow listing, as above.
  - After `tune-kindnet-resources.sh --apply` and a cold cache again: over
    30 s, `memory.current` 69,799,936 (`file` 58,728,448), refaults +0,
    `pgscan_direct` +0, CPU 20 ms, 0 throttled periods. kindnet's listing took
    0.22 s.
  - The patch survived `docker restart xt50-control-plane xt50-worker`. After a
    cold cache: 70,082,560 bytes, 0 refaults, listing 0.35 s.
  - Rollout test: `rollout restart` of a two-replica `agnhost` Deployment behind
    a Service, with one client Pod pinned to each node. On both nodes the DNAT
    targets matched the new EndpointSlice addresses, 20 of 20 connects
    succeeded, and kube-proxy logged 0 lock errors. This held with the tuned
    limits before and after the node restart. It also held with the original
    limits (see Problems).
  - `create-cluster.sh` from a test copy with `CLUSTER_NAME=xt50` created the
    cluster and applied the patch. A second run took the existing-cluster path
    and reported `already tuned`. `rollout undo` restored the original limits,
    and the script then checked and applied again.
  - Guard tests with a stubbed `kubectl_for_minishop`: a missing DaemonSet, a
    second container, and a non-kindnetd image exit 1 without patching. A newer
    kindnetd tag warns. Bad arguments exit 2.
- Review fixes, on a new `xt50` built by a test copy of `create-cluster.sh`:
  - After the create path, the DaemonSet had the new resources and
    `system-node-critical`. Both kindnet Pods ran at priority 2000001000 with
    QoS Burstable, and kindnetd's `oom_score_adj` was -997 on both nodes.
  - A second `--apply` reported `already tuned` and changed nothing.
  - `rollout undo` restored 100m/50Mi limits, no priority class, priority 0,
    and Guaranteed QoS (`oom_score_adj` -997). Check mode then dry-ran the
    patch, and `--apply` restored priority 2000001000.
  - With the priority class removed and the new resources kept (the first
    patch's result), kindnetd's `oom_score_adj` was 992 on both nodes. That
    confirms the blocker. `--apply` on that state restored the priority class
    and priority 2000001000.
  - `create-cluster.sh` on the existing-cluster path, with the tune script
    replaced by a stub that exits 1, printed `Warning: kindnet check failed;
    see docs/troubleshooting.md#kindnet-xtables-lock` and exited 0. With the
    real script it reported `already tuned`.
  - Stubbed guard tests also cover a DaemonSet with no limits (the v0.33.0
    manifest): `--apply` skips it, with a warning if the priority class is
    missing. Tuned resources without the priority class are patched.
- kind-learn, read-only: `bash scripts/tune-kindnet-resources.sh` (check mode)
  reported the 100m/50Mi limits and `priorityClassName=<none>`. The server
  dry-run returned the desired resources and
  `priorityClassName=system-node-critical`. Nothing was persisted. A
  read-only pass found priority 0 and Guaranteed QoS on all four kindnet Pods,
  and `oom_score_adj` -997 for every kindnetd.
- Lint: `bash -n` and ShellCheck v0.10.0 (with and without `-x`) are clean on
  both scripts. LF line endings and `git diff --check` pass.
- `xt50` was deleted after each round. kind-learn's four node containers kept
  their IDs and start times during the first round (`2026-11-08T14:23:54Z`,
  restart count 0) and the review round. Docker Desktop was restarted
  separately on 2026-11-09, so the second baseline is `2026-11-09T15:49:55Z`.

## Documentation
- [Troubleshooting](../troubleshooting.md#kindnet-xtables-lock): symptom,
  signature, diagnosis commands, and fix command.
- [Operator guide](../minishop-operator-guide.md#local-prerequisites): new
  clusters are tuned by `create-cluster.sh`; existing clusters need one owner-
  approved `--apply`.
- `docs/README.md` index entries 34 (ADR 0012) and 35 (this record).
- The Issue #38 record's unexplained post-restart `/items` timeout now points
  here as a possible, unconfirmed cause.
- Partly verified: listings that were 618 s and 649 s old and still running
  were measured on kind-learn in this work. The 30-minute upper bound comes from
  the Issue #50 findings.

## Follow-up
- Owner: run `bash scripts/tune-kindnet-resources.sh --apply` on kind-learn.
  It rolls kindnet one node at a time.
- Acceptance criterion 3 (a rollout that changes endpoints keeps Service
  routing correct on every node) stays open until this check passes on
  kind-learn after the owner's `--apply`:
  1. `KUBECONFIG=./.kube/config kubectl --context kind-learn -n webapp rollout
     restart deployment minishop-backend`, then `rollout status` it.
  2. Wait until no `minishop-backend` Pod is Terminating, then list the ready
     addresses with `KUBECONFIG=./.kube/config kubectl --context kind-learn -n
     webapp get endpointslices -l kubernetes.io/service-name=minishop-backend -o
     jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{"\n"}{end}'`.
     kube-proxy programs only ready endpoints, so not-ready or terminating ones
     must not be compared.
  3. On each node, `docker exec <node> iptables-save -t nat | grep
     'webapp/minishop-backend' | grep -o 'to-destination [0-9.:]*'` must list
     exactly those addresses.
  4. On each node, kube-proxy must log 0 `xtables lock` lines since the
     restart (`KUBECONFIG=./.kube/config kubectl --context kind-learn -n
     kube-system logs <kube-proxy-pod> --since-time=<restart time> | grep -c
     'xtables lock'`).
- Owner: decide on a later cluster rebuild with kind v0.33.0 or later and a
  matching node image, which ships kindnet without limits. It changes the
  Kubernetes minor version and needs the #40 backups first.
- Not fixed here: the Pod stuck Terminating and the failed sandboxes on
  learn-worker2 should clear once the lock is free. Check after the patch.
