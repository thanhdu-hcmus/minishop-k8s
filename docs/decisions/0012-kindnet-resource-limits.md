---
title: kindnet resource limits
requirement: Issue #50 — stop hung kindnetd iptables listings holding the lock
status: proposed
last_updated: 2026-11-08
---

# kindnet Resource Limits

## Goal
Record the T2 decision on how to stop the kind-provided `kindnet` agent from
starving itself, and the `iptables` listings it runs, under its container
limits. Status is proposed; the owner accepts it on merge.

## Prerequisites
- [Issue #50](https://github.com/thanhdu-hcmus/minishop-k8s/issues/50).
- `cluster/kind-config.yaml` pins `kindest/node:v1.30.13` (built by kind
  v0.29.0), whose CNI manifest runs `docker.io/kindest/kindnetd:v20250512-df8de77b`
  with requests and limits of 100m CPU and 50Mi memory and no
  `priorityClassName`. kind's CNI install step reads that manifest from
  `/kind/manifests/default-cni.yaml` in the node image; the copy in
  `learn-control-plane` holds those limits.

## Decision
- **Root cause is the container limits, not legacy iptables.** The kindnetd
  binary is 80 MB of file-backed code. When its page cache is charged to the
  kindnet container, the 50Mi memory limit forces direct reclaim and refault of
  that code without end, and the 100m CPU limit throttles the reclaim. Child
  processes share the cgroup, so kindnetd's iptables children (`-S`, `-C`) take
  seconds to tens of minutes while they hold `/run/xtables.lock`. Upstream kind
  found the same thrash
  ([kind#4215](https://github.com/kubernetes-sigs/kind/issues/4215), closed
  2026-07-22T14:29:49Z). PR #4220 removed the memory limit (merged
  2026-07-22T14:29:48Z) and PR #4223 the CPU limit (merged
  2026-07-22T21:49:53Z). Both change only `pkg/build/nodeimage/const_cni.go`,
  and both fall in `v0.32.0...v0.33.0`. v0.33.0 was published on 2026-08-26
  with kindnetd `v20260820-69b56db7`. Checked with `gh` on 2026-11-08.
- **Patch the DaemonSet, from Git.** `scripts/tune-kindnet-resources.sh` sets
  requests to 100m CPU and 128Mi memory, a 256Mi memory limit, no CPU limit,
  and `priorityClassName: system-node-critical`. It checks by default and
  changes the cluster only with `--apply`. It leaves alone a DaemonSet that
  already has no limits. `scripts/create-cluster.sh` applies it to every
  cluster it creates. Against an existing cluster it only runs the check, and a
  failed check only warns.
- **kind-learn changes only with owner approval.** The owner runs
  `bash scripts/tune-kindnet-resources.sh --apply` once. kind applies the CNI
  manifest only at cluster creation, so the patch survives Docker restarts.

## Rationale
- The measured working set after a cold page cache is about 70 MB (59 MB of
  binary page cache and 11 MB of heap), above the 50Mi limit. A 128Mi request
  reserves that for scheduling.
- A memory limit still bounds a leak in a node-critical agent; 256Mi is twice
  the request.
- A CPU limit on the node's network agent turns any burst into CFS throttling,
  which delayed every kindnet sync here. The request keeps its fair share.
  Upstream made the same choice.
- Without limits equal to requests, the Pod moves from Guaranteed to Burstable
  QoS. Today kindnet has no priority class (Pod priority 0), and kindnetd's
  `oom_score_adj` is -997 only because the Pod is Guaranteed. As a Burstable
  Pod with priority 0 it got an `oom_score_adj` of 992 on the throwaway
  cluster, so a VM-level OOM would pick the node's network agent almost
  first. The patch therefore also sets `system-node-critical` (value
  2000001000). That class is allowed in `kube-system`, and upstream kind has
  set it since v0.30.0. Kubelet gives critical Pods -997 whatever their QoS
  class; the throwaway cluster showed -997 for the Burstable kindnet Pod.

## Alternatives Considered
- **nftables mode for kube-proxy.** It would stop kube-proxy from waiting on
  the xtables lock, but kindnetd and the portmap CNI plugin would still crawl
  inside the same throttled cgroup, so sandbox setup and teardown would still
  fail. It needs a new cluster, and on Kubernetes 1.30 nftables mode is alpha.
- **A newer kind and node image (v0.33.0 or later).** This is the upstream fix,
  but it also changes the Kubernetes minor version and needs a new cluster with
  backups first. It stays an owner decision.
- **Ending hung listings with a helper script.** A new hung listing appeared
  within about three minutes, so this treats the symptom only. Killing a
  listing also makes kindnetd panic and restart (seen on learn-worker2 at about
  16:07Z), and the thrash returned in the new container. Not built; a last
  resort only.
- **Disabling the default CNI and installing kindnet from a Git manifest.**
  This adds a manifest to maintain for one field change. Rejected.

## Consequences
- The patch rolls kindnet one node at a time. Existing Pod networking keeps
  working while kindnetd restarts.
- `create-cluster.sh` now writes to `kube-system` right after it creates a
  cluster. That is a cluster-wide change under AGENTS.md "ask first before
  cluster-wide changes". Merging this ADR is the owner's approval for it. It
  applies only to a cluster the script has just created; kind-learn and any
  other existing cluster get only the read-only check.
- A node image built by kind v0.33.0 or later ships kindnet without limits but
  keeps requests of 100m CPU and 50Mi memory. Patching that manifest would add
  back a memory limit that upstream removed, so the script skips any kindnet
  DaemonSet that has no limits. It still warns when the image differs from the
  one measured.

## Verification
On a throwaway kind cluster with the same node image, a cold kindnetd page
cache reproduced the thrash. After the patch, refaults stopped and kindnet's
listing took 0.22 s. With the priority class, kindnet Pods ran at priority
2000001000 and kindnetd's `oom_score_adj` stayed -997. Without it, the new
resources alone gave 992. Details are in the implementation record.

## Related Docs
- [kindnet iptables lock record](../devlog/2026-11-08-kindnet-iptables-lock.md)
- [Issue #50](https://github.com/thanhdu-hcmus/minishop-k8s/issues/50)
