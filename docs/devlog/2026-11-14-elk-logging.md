---
title: ECK-managed ELK logging stack
requirement: Issue #59 — centralize logs with an ECK-managed ELK stack
status: implemented
last_updated: 2026-11-14
date: 2026-11-14
issue: "#59"
pr: "not recorded"
tier: T2
reconstructed: false
source: "Recorded during implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# ECK-Managed ELK Logging Stack

## Goal
Issue #59: collect every container log in kind-learn with Filebeat, store it
in a one-node Elasticsearch with Kibana, all managed by ECK, next to the
existing Prometheus and Grafana stack. The PR changes nothing in kind-learn;
installing ECK CRDs, cluster-wide RBAC and the workloads is the owner's step
after merge.

## Baseline (read-only, 2026-11-14)
- WSL: 15869 MiB total, 11950 MiB available, 20 CPUs, 943 GB disk free.
- kind-learn: Kubernetes v1.30.13 on 4 nodes; `kubectl top nodes` 444m /
  1263Mi (control plane), 191m / 1008Mi, 218m / 928Mi, 101m / 557Mi
  (workers). Node requests are 3-8% of memory.
- Default StorageClass `standard` (rancher.io/local-path,
  WaitForFirstConsumer). No Elastic CRDs. `vm.max_map_count` 262144 on all
  four nodes (read with `docker exec ... sysctl -n`).
- API endpoint `172.18.0.3:6443` (Service `10.96.0.1:443`); kind network
  `172.18.0.0/16`; CoreDNS Pods `k8s-app=kube-dns` in kube-system.
- Backend log line on disk (containerd CRI format, under /var/log/pods,
  linked from /var/log/containers): `<time> stdout F {"level":30,"time":...,
  "pid":22,"hostname":"...","name":"kuma-backend","msg":"get on /items"}`.
  Backend container name `backend`, labels
  `app.kubernetes.io/component=minishop-backend`, `name=minishop`,
  `part-of=minishop`.

## Problems and fixes
- **ECK 3.5.0 does not support kind-learn's Kubernetes.** The latest ECK
  release (v3.5.0, 2026-08-04, from `gh api repos/elastic/cloud-on-k8s/releases`)
  was the planned pin. Its README at the tag lists Kubernetes 1.32-1.36 (the
  OperatorHub CSV template 1.31-1.36); kind-learn runs v1.30.13. Reading the
  README at each tag: v3.4.x and v3.3.x support 1.31+, v3.2.0 supports
  1.30-1.34 (verified 2026-11-14 via gh api README at each tag).
  Fix: pin **ECK 3.2.0**, the newest release that supports 1.30,
  and record the bump path (new kind node image first) in ADR 0017.
  Upgrading kind or the node image is out of scope.
- **Stack version for ECK 3.2.0.** ECK 3.2.0's samples and e2e default use
  stack 9.2.0, but 9.2 had its last patch on 2026-04-08 (9.2.8) and 9.3 on
  2026-07-21 (9.3.8). Still patched: 9.5.x, 9.4.x and 8.19.x (release dates
  verified 2026-11-14 via GitHub releases). 8.x maintenance ends 2027-01-15
  and 9.x 2027-10-15 (from elastic.co/support/eol; EOL dates as reported, not
  re-checked in this record). ECK 3.2.0 supports "7.17+, 8+, 9+" (README at
  the tag). Chosen: **9.4.9** (2026-11-02), the oldest patched 9.x minor;
  ECK 3.5.0's own samples use the same minor (9.4.3), so a later ECK bump
  keeps the stack.
  The throwaway-cluster test is the evidence that 3.2.0 manages 9.4.9.
- **CRD file differs from the git tag.** `config/crds/v1/all-crds.yaml` at
  v3.5.0 and v3.2.0 has a different SHA-256 from the download-host
  `crds.yaml`. The diff (v3.5.0) is only Helm-render formatting (line
  wrapping) and added `helm.sh/resource-policy` and `app.kubernetes.io/*`
  labels. The download-host files are what Elastic's install docs use, so
  their checksums are pinned.
- **Secret reads.** Repository scripts read Secrets with jsonpath and stderr
  discarded. For this stack no script reads a Secret at all: the
  Elasticsearch Pod mounts `logging-es-elastic-user`, and
  `scripts/logging-lib.sh` runs curl inside that container with the password
  piped from the file into `curl --config`, so it never reaches a command
  line or the operator's shell.
- **Lint.** First ShellCheck run: SC2034 for `LOGGING_KUBECONFIG` set in the
  option loops (CI runs shellcheck without `-x`, so the sourced use is
  invisible), SC2100 on the unquoted `kind-learn` value, SC2016 for
  in-container commands. yamllint: digest-pinned image lines over 80
  characters. Fixed with scoped directives, quoting, and
  `yamllint disable-line rule:line-length` on the image lines (as in
  `.github/workflows/ci.yml`).
- **Test line never searchable (test runs 1 and 2).** `test-logging.sh`
  deployed ECK and the stack (all green, ILM policy applied, data stream
  `filebeat-9.4.9` linked to `minishop-logs`), then `validate-logging.sh`
  failed: `test line ... is not searchable after 180s` (run 1, 406 s, cluster
  deleted). Run 2 kept the cluster: 2434 documents from kube-system,
  elastic-system, logging and local-path-storage, none from `webapp`, and
  none from the Elasticsearch or Kibana Pods. Two causes:
  - The stand-in backend's log file was 190 bytes. Filebeat logged
    `ingestion from some files will be delayed, files need to be at least
    1024 in size`: fingerprint file identity waits for 1024 bytes. Any
    quiet container is held back the same way. Fix:
    `prospector.scanner.fingerprint.length: 64`, the minimum; the first 64
    bytes of a CRI line include its nanosecond timestamp.
  - ECK annotates the Elasticsearch and Kibana Pods with
    `co.elastic.logs/module: elasticsearch|kibana`. The hints builder then
    makes module configs from `default_config`: `more than one namespace
    configured accessing 'parsers.0'` (Elasticsearch) and `filestream input
    with ID ... already exists` (Kibana, one ID for two filesets), so
    neither Pod's logs were read. Filebeat 9.4.9's `logs.go` uses a module
    only when the hint is not empty, so both podTemplates now set
    `co.elastic.logs/module: ""`.
  - `validate-logging.sh` now prints the total and per-Pod document counts
    on a timeout, and `test-logging.sh` checks that the Elasticsearch and
    Kibana Pods' logs arrive.
- **Run 3: Kibana status check.** Everything up to the port-forward check
  passed, then `expected 401, got 200`: Kibana 9.4 answers `/api/status`
  without credentials (redacted). The harness now expects 200 with
  `"level":"available"` from `/api/status` and 401 from `/api/data_views`.
- **Run 4: harness race.** `kube-network-policies started in 2 of 3
  kindnet Pods` 49 s in: one kindnet Pod was Ready before it logged the
  controller start. The check now retries for 60 s.
- **Run 5: usage parser.** All stack checks passed, then the usage step
  failed with `JSONDecodeError`: the kubelet summary API returns
  pretty-printed JSON, not one object per line. Each node's summary is now
  saved and parsed as a whole file.
- **Run 6: Kibana memory.** Full pass (485 s), but Kibana's working set was
  913 MiB against its 1Gi limit (ECK's default). Raised to 1536Mi request and
  limit; the 700 MB Node.js heap cap is unchanged.
- **Elasticsearch yellow at first.** Runs 2, 3 and 6 saw `yellow` when
  validation started and `green` a minute later (`_cat/indices?health=yellow`
  empty at that point). Filebeat's indices have 0 replicas; deploy and
  validate accept green or yellow, as the Issue allows.

## Features implemented
- `scripts/logging-lib.sh`: ECK 3.2.0 pins (manifest SHA-256s, operator
  digest), resource names, the target options (`--context`, `--kubeconfig`,
  defaults kind-learn and `./.kube/config`), and `logging_es_api`, which runs
  curl inside the Elasticsearch container with the password piped from the
  mounted Secret file.
- `scripts/deploy-eck.sh`: download, checksum check, operator image digest
  pin (exactly one image line expected), server-side apply of the CRDs, apply
  of the operator, rollout wait, running-image check. Not run on kind-learn.
- `manifests/40-logging/`: namespace (`pod-security.kubernetes.io/enforce:
  privileged` for Filebeat), five NetworkPolicies, Elasticsearch, Kibana,
  Filebeat Beat, Filebeat ServiceAccount and ClusterRole/Binding
  `logging-filebeat`, and `ilm-policy.json`.
- `scripts/validate-logging-manifests.sh`: offline kubeconform (strict) with
  schemas built from the checksum-verified CRDs, plus version, digest,
  resource and retention checks.
- `scripts/deploy-logging.sh`, `scripts/validate-logging.sh`,
  `scripts/teardown-logging.sh` (needs `--yes`; `--remove-eck` refuses while
  Elastic resources exist outside `logging`).
- `scripts/test-logging.sh`: the throwaway-cluster test (memory guard 6 GiB).

## Verification
- `bash scripts/validate-logging-manifests.sh`: 12 resources in 6 files
  valid, 0 skipped (17 ECK schemas built); policy checks pass. Mutations each
  caught: `nodeSets` renamed, an unknown Kibana field, a Kibana memory limit
  removed, Filebeat version drift, an image without digest, ILM delete at
  30d, a NetworkPolicy field typo, `setup.ilm.overwrite: true`.
- ShellCheck v0.10.0 (Docker) clean on all seven scripts, both without `-x`
  (as CI) and with `-x`; `bash -n` clean; yamllint 1.35.1 clean on
  `manifests/40-logging`; no CRLF.
- `scripts/validate-kustomize.sh` (27, 27 and 15 resources) and
  `scripts/validate-helm.sh` (17 and 19 resources) still pass.
- kind-learn, server dry-run only: the ten CRDs (server-side apply, dry
  run), the operator's Namespace, three ClusterRoles, ClusterRoleBinding and
  ValidatingWebhookConfiguration, `logging-filebeat` ClusterRole and binding,
  and the `logging` Namespace were accepted; afterwards no Elastic CRD and no
  `logging` or `elastic-system` namespace existed. Namespaced objects could
  not be dry-run because their namespaces do not exist there.
- `bash scripts/test-logging.sh`, final run (run 7), 497 s, `All logging tests
  passed.`, kind v0.30.0, node `kindest/node:v1.30.13`, kindnet
  `v20250512-df8de77b`, control plane and two workers, 11722 MiB available
  before and 11806 MiB after (cluster deleted):
  - deploy-eck.sh: 10 CRDs, operator at the pinned digest.
  - deploy-logging.sh: Elasticsearch green, ILM policy applied, Kibana and
    Filebeat green (3 Pods, control plane included).
  - validate-logging.sh: the test line written to the stand-in backend's
    stdout was searchable after 64 s (22-64 s over runs 3, 5, 6, 7) with
    `log.level=info`, `pino.name`, `pino.level=30`, message replaced by the
    pino msg, namespace, Pod and label metadata, in
    `.ds-filebeat-9.4.9-2026.11.14-000001` managed by `minishop-logs`.
  - Elasticsearch (790 documents) and Kibana (286) Pod logs collected.
  - Every logging container, ECK's init containers included, has CPU and
    memory requests and limits. Filebeat runs UID 0 with all capabilities
    dropped, no privilege escalation, read-only root file system,
    RuntimeDefault seccomp. ECK sets non-root, read-only root and dropped
    capabilities on Elasticsearch and Kibana; Kibana's
    `elastic-internal-init` init container has no security context (ECK
    default).
  - NetworkPolicy (Pod IPs, 3 s TCP connect): OPEN Kibana to Elasticsearch
    9200, Filebeat to Elasticsearch 9200, Filebeat to the API server
    (`172.18.0.8:6443`); TIMEOUT for a plain `webapp` Pod to Elasticsearch
    9200 and 9300 and to Kibana 5601, the backend stand-in to Elasticsearch
    9200, Filebeat to Kibana 5601, Elasticsearch, Kibana and Filebeat to a
    `webapp` listener, and Elasticsearch to the API server. Control: the
    plain Pod reaches its own listener. No operator-to-Elasticsearch
    timeouts in its log.
  - Through `kubectl port-forward service/logging-kb-http`: `/api/status`
    200 with overall `available`, `/api/data_views` 401 without credentials.
  - Filebeat ServiceAccount: may list pods, may not get secrets or create
    pods; 0 `forbidden`, `permission denied` or `read-only file system` log
    lines.
  - Re-running deploy-logging.sh and validate-logging.sh after deleting a
    Filebeat Pod passed.
  - teardown-logging.sh without `--yes` changed nothing; with `--yes
    --remove-eck` it removed `logging`, `elastic-system`, the Filebeat and
    operator RBAC, the webhook, the CRDs and the PersistentVolume; the
    `webapp` Pods kept their UIDs and stayed Ready.
  - None of the 14 captured outputs contains the elastic password (checked
    plain and base64; the password was read once inside the Elasticsearch
    container into a private file for this check only).

## Memory and CPU budget
Measured in the test cluster (kubelet summary API, 30 s after validation,
run 7): Elasticsearch 1608 MiB / 103m, Kibana 946 MiB / 87m, Filebeat 49-76
MiB / 3-6m per Pod, ECK operator 37 MiB / 11m; total 2770 MiB / 212m CPU
with three Filebeat Pods. On kind-learn (four nodes) that is about 2.8-2.9
GiB, against 11.9 GiB available in WSL before install (about 9 GiB left).
Requests added: 1000m CPU (Elasticsearch 500m, Kibana 200m, Filebeat 4 x
50m, operator 100m) and about 4.2Gi memory (Elasticsearch 2Gi, Kibana
1.5Gi, Filebeat 4 x 128Mi, operator 150Mi); limits about 5.7Gi. The owner
measures the real numbers on kind-learn after the deploy with `kubectl top`.

## Not deployed; owner steps
kind-learn is unchanged. With the owner's approval, after merge, from the
repository root:
1. `free -m` in WSL; continue only with about 6 GiB available.
2. `bash scripts/deploy-eck.sh` (cluster-wide CRDs, operator RBAC, webhook).
3. `bash scripts/deploy-logging.sh` (namespace, policies, Elasticsearch,
   ILM, Kibana, Filebeat RBAC and DaemonSet).
4. `bash scripts/validate-logging.sh`.
5. `KUBECONFIG=./.kube/config kubectl --context kind-learn top pods -n
   logging` and `-n elastic-system`, `kubectl top nodes`, `free -m`; record
   them.
6. Kibana: port-forward `service/logging-kb-http` 5601, log in as `elastic`,
   create a `filebeat-*` data view.
Rollback: `bash scripts/teardown-logging.sh --yes` (add `--remove-eck` to
remove ECK). MiniShop is not touched either way.

## Review fixes (one pass: 0 Blockers, 4 Should-fix, nits)
Backup of the pre-review branch: `backup/59-pre-review` at `07059cf`. The
branch moved to a Windows-git worktree; commits from here on were made with
Windows git (`core.autocrlf=false`, LF checked with `git ls-files --eol`).
- **S1, teardown guard.** `--remove-eck` checked foreign Elastic resources
  only when exactly ten ECK CRDs were Established, so a partial install
  skipped the guard and the CRD delete would remove every Elastic resource
  in the cluster. `teardown-logging.sh` now lists every `*.k8s.elastic.co`
  CRD and each one's resources directly, refuses while any resource is
  outside `logging`, and stops before changing anything if a listing fails;
  the dry run uses the same listing. New `scripts/test-teardown-logging.sh`
  (stubbed kubectl, curl and sha256sum): 8/8 cases pass. Run against the
  pre-review script from the backup branch, all 8 fail; with nine CRDs and a
  resource in `data` it issued 5 delete calls.
- **S2, operator scope.** `deploy-eck.sh` sets `namespaces: [logging]` in
  the operator's `eck.yaml` (exact-match edit next to the digest rewrite, in
  `logging_patch_operator`) and checks the applied ConfigMap and the
  operator's `Operator configured to manage multiple namespaces` log line.
  Key confirmed at the v3.2.0 tag: `namespaces` in
  `docs/reference/eck-configuration-flags.md` ("Namespaces in which this
  operator should manage resources"), `NamespacesFlag = "namespaces"` in
  `pkg/controller/common/operator/flags.go`, the chart's
  `namespaces: [{{ join "," . }}]`, and `cmd/manager/main.go` adding the
  operator namespace and limiting the cache to these namespaces. RBAC is
  unchanged; ADR 0017 now names the ClusterRole's reach (all Secrets,
  including `minishop-data-credentials`, `minishop-app-credentials` and the
  `monitoring` Secrets, from a names-only listing; every
  `validatingwebhookconfiguration`) and keeps the namespaced Helm install as
  an owner option.
- **S3, Filebeat API egress.** The 6443 rule now has `ipBlock`
  `172.18.0.0/16` (`docker network inspect kind`, read-only). The same value
  is `LOGGING_API_CIDR`; `deploy-logging.sh` and `validate-logging.sh` fail if
  the API endpoint is outside it (kind-learn's `172.18.0.3` is inside, checked
  read-only).
- **S4, upstream facts.** Re-checked and marked "verified 2026-11-14"; ECK
  3.2.0's stack range corrected to "7.17+, 8+, 9+" and ECK 3.5.0's sample
  version to 9.4.3. EOL dates stay marked as not re-checked.
- **Nits.** N1 folded the doc-writer's fact-marking commit into the docs
  commit; N2 made the troubleshooting group a sub-heading; N3 rewrote the
  6443 entry as a real symptom; N4 prints `--kubeconfig` and `--context` in
  the Kibana hint; N5 states in ADR 0017 that every namespace's output is
  stored and searchable; N7 adds `warn` and `audit` at `baseline` on the
  `logging` namespace.
- **Validator.** `validate-logging-manifests.sh` now also checks the patched
  `operator.yaml` (11 resources, strict) and asserts namespaces exactly
  `[logging]` and the Filebeat 6443 rule exactly TCP to the CIDR. A first
  version compared the patched value with its own constant, so widening the
  constant was missed; it now compares with the logging namespace. Seeded
  mutations caught: ipBlock removed, widened to `0.0.0.0/0`, namespaces
  widened, library CIDR changed, an extra port 443 on the rule.
- **Re-verification.** ShellCheck v0.10.0 clean on all eight logging scripts;
  `bash -n`, yamllint, LF clean; `validate-kustomize.sh` and
  `validate-helm.sh` pass. `test-logging.sh` run 8 on the final scripts and
  manifests: 507 s, `All logging tests passed.`, 11668 MiB available before
  and 11822 MiB after, cluster deleted; deploy-eck.sh's new namespace checks
  passed; test line searchable after 70 s; API endpoint inside the ipBlock;
  every policy path as before; usage 2906 MiB / 277m CPU (Kibana 1052 MiB of
  1536Mi).

## Decisions
- [ADR 0017: ECK-managed logging stack](../decisions/0017-eck-logging-stack.md)
  (proposed).

## Known gaps
- One Elasticsearch node, no replica, no backup: losing the volume or the
  `Elasticsearch` resource loses the logs.
- local-path does not enforce the 10Gi request; ILM is the bound.
- The ECK operator keeps cluster-wide RBAC (Secrets, workloads and webhook
  configurations everywhere); `namespaces: [logging]` narrows only what it
  watches and caches. A namespace-scoped install is the alternative in
  ADR 0017.
- Filebeat stores every namespace's container output, including `data` and
  `kube-system`, for about 4 days.
- The Filebeat API ipBlock is tied to the kind Docker network subnet.
- ECK 3.2.0 is three minors behind; it is pinned to match Kubernetes 1.30.
- Filebeat's registry stays on each node after teardown.
- The CI kubeconform step skips the ECK resources (`-ignore-missing-schemas`);
  `validate-logging-manifests.sh` is not wired into CI (a CI change needs the
  owner).
- `test-logging.sh` uses a stand-in backend Pod, not the full chart.

## Follow-ups
- Owner: approve and run the deploy steps; record `kubectl top` results.
- Owner: accept ADR 0017; decide on the namespace-scoped ECK install.
- Bump ECK to the current release after kind-learn moves to Kubernetes 1.31+.
- Optionally run `validate-logging-manifests.sh` in CI.
