---
title: ECK-managed logging stack
requirement: Issue #59 — centralize logs with an ECK-managed ELK stack
status: proposed
last_updated: 2026-11-14
---

# ECK-Managed Logging Stack

## Goal
Record the T2 decision to centralize container logs in Elasticsearch and
Kibana, collected by Filebeat and managed by ECK (Elastic Cloud on
Kubernetes), as a learning exercise next to the existing Prometheus and
Grafana stack. Status is proposed; the owner accepts it on merge and approves
the deploy separately.

## Prerequisites
- [Issue #59](https://github.com/thanhdu-hcmus/minishop-k8s/issues/59).
- kind-learn on Kubernetes v1.30.13 with kindnet enforcing NetworkPolicy
  ([ADR 0016](./0016-data-tier-network-policy.md)), default StorageClass
  `standard` (local-path), `vm.max_map_count` 262144 on every node.
- [ADR 0007](./0007-platform-observability.md): kube-prometheus-stack in
  `monitoring`.

## Decision
- **ELK alongside Grafana, not instead of it.** Prometheus and Grafana keep
  metrics and alerts; Elasticsearch and Kibana hold logs. Nothing in
  `monitoring` changes. Logstash is left out (Filebeat writes straight to
  Elasticsearch); it can be a later learning step.
- **ECK over Helm charts.** Elastic's own operator manages the stack through
  `Elasticsearch`, `Kibana` and `Beat` resources: it generates TLS
  certificates, the `elastic` user and per-client users, wires Kibana and
  Filebeat to Elasticsearch, and runs version-aware rolling changes. The
  `elastic/helm-charts` repository for the stack is archived (last push
  2023-04-24) and its README recommends ECK (verified 2026-11-14 via gh api).
  The operator is installed from Elastic's all-in-one
  manifests (`crds.yaml`, `operator.yaml`), like ingress-nginx
  (`scripts/deploy-ingress-nginx.sh`).
- **Versions.**
  - **ECK 3.2.0**, not the latest 3.5.0: ECK 3.3.0 and later support
    Kubernetes 1.31 or later (1.32 or later from 3.5.0), and kind-learn runs
    1.30.13. 3.2.0 supports 1.30-1.34 (verified 2026-11-14 via gh api README
    at each tag).
  - **Elastic Stack 9.4.9** for Elasticsearch, Kibana and Filebeat: a
    still-patched 9.x minor inside ECK 3.2.0's "7.17+, 8+, 9+" range. 9.2,
    which ECK 3.2.0 was tested with, had its last patch 9.2.8 on 2026-04-08
    and 9.3 its last, 9.3.8, on 2026-07-21; 9.4.9 is from 2026-11-02 (verified
    2026-11-14 via GitHub releases). ECK 3.5.0's samples use the same minor
    (9.4.3), so a later ECK bump keeps it.
  - Bump ECK only together with a kind node image of 1.31 or later.
- **Pinning.** `scripts/logging-lib.sh` pins the SHA-256 of both download-host
  manifests (`crds.yaml` `2ba3cb0d…435384ea`, `operator.yaml`
  `74c5bd9e…fc90809`); `deploy-eck.sh` refuses a mismatch and rewrites the
  operator image to its multi-arch index digest. The stack resources set
  `image:` to `9.4.9@sha256:…` digests next to `version: 9.4.9`.
- **Layout.** Raw manifests in `manifests/40-logging/`, the next layer after
  `30-platform`: `namespace.yaml`, `networkpolicy.yaml`, `elasticsearch.yaml`,
  `kibana.yaml`, `filebeat-rbac.yaml`, `filebeat.yaml`, and `ilm-policy.json`
  (Elasticsearch API body). The stack is not MiniShop's application, so it is
  not in the chart or the Kustomize overlays; `deploy/` holds third-party
  Helm values only.
- **Sizing (one node, no HA).**

  | Component | Replicas | CPU request / limit | Memory request / limit | Storage |
  | --- | --- | --- | --- | --- |
  | Elasticsearch (heap 1g, roles master, data, ingest) | 1 | 500m / 2 | 2Gi / 2Gi | 10Gi PVC |
  | Kibana (Node.js heap 700 MB) | 1 | 200m / 1 | 1536Mi / 1536Mi | none |
  | Filebeat (DaemonSet, control plane included) | 1 per node (4) | 50m / 500m | 128Mi / 300Mi | hostPath registry |
  | ECK operator (upstream `operator.yaml` values, not in this repo) | 1 | 100m / 1 | 150Mi / 1Gi | none |

  On kind-learn the limits add up to about 5.7Gi (Elasticsearch 2Gi, Kibana
  1.5Gi, four Filebeat Pods 1.2Gi, operator 1Gi). Kibana gets 1536Mi, not
  ECK's 1Gi default, because the test measured a 913 MiB working set at
  idle. Machine learning is off (no `ml` role) and the GeoIP downloader is
  off.
- **Retention.** ILM policy `minishop-logs`: roll over daily or at 1gb
  primary shard size, delete 3 days after rollover, so data lives at most
  about 4 days. `deploy-logging.sh` PUTs it through the Elasticsearch API
  after Elasticsearch is healthy and before Filebeat starts; Filebeat
  (`setup.ilm.policy_name: minishop-logs`, `check_exists: true`,
  `overwrite: false`) links its index template to it and never replaces it.
  A PUT with the same body is idempotent. Indices use 0 replicas, so the
  one-node cluster stays green.
- **Collection.** Filebeat autodiscover with hints reads
  `/var/log/containers/*` (links into `/var/log/pods`, containerd format) and
  adds Kubernetes metadata. The fingerprint length is 64 bytes, not 1024,
  so a quiet container's first lines are not held back. ECK's
  `co.elastic.logs/module` hint is blanked on the Elasticsearch and Kibana
  Pods, because the module configs it produces clash with
  `default_config` and their logs were not collected; they are stored as
  plain container logs. For Pods in `webapp` labelled
  `app.kubernetes.io/component=minishop-backend`, `decode_json_fields`
  decodes pino JSON under `pino.*`, `msg` becomes `message`, and the numeric
  `level` becomes ECS `log.level` (30 to `info`).
- **Access and credentials.** Kibana is reached by
  `kubectl -n logging port-forward service/logging-kb-http 5601` only (no
  Ingress). ECK keeps the `elastic` password in Secret
  `logging-es-elastic-user`; the operator reads it in their own terminal.
  Scripts never read a Secret: the Elasticsearch Pod mounts that Secret, and
  `scripts/logging-lib.sh` runs curl inside the container with the password
  piped into `curl --config`.
- **NetworkPolicy.** `default-deny-all` (ingress and egress) in `logging`,
  plus: DNS egress to CoreDNS; Elasticsearch ingress on 9200 from the ECK
  operator (namespace `elastic-system`, `control-plane=elastic-operator`),
  Kibana and Filebeat, and on 9300 from its own nodes; Elasticsearch egress
  on 9300 to its own nodes; Kibana and Filebeat egress to Elasticsearch 9200;
  Filebeat egress to TCP 6443 (API server, by port only because the endpoint
  is a kind node IP that can change). Not allowed, by design: Kibana ingress
  (port-forward is not filtered by NetworkPolicy), the operator to Kibana
  (ECK calls only Elasticsearch, per Elastic's ECK network-policy guide), and
  any internet egress (telemetry and newsfeed are off). The API server
  reaching the operator's webhook is in `elastic-system`, which has no
  policy.
- **Owner-approval boundary.** The PR changes nothing in kind-learn. The
  owner approves, at deploy time:
  - ten cluster-wide ECK CRDs and a `ValidatingWebhookConfiguration`
    (`failurePolicy: Ignore`);
  - the operator's ClusterRole: create, update and delete on Pods, Secrets,
    ConfigMaps, Services, PVCs, Deployments, StatefulSets, DaemonSets and
    PDBs in every namespace, read on nodes and StorageClasses, and the
    webhook configuration. ECK also adds aggregated `elastic-operator-view`
    and `-edit` roles, which extend the built-in view, edit and admin roles
    to Elastic resources;
  - Filebeat's ClusterRole `logging-filebeat`: get, list and watch on Pods,
    Namespaces and Nodes, no Secrets;
  - Filebeat running as root (UID 0, no capabilities, no privilege
    escalation, read-only root file system) with read-only hostPath mounts of
    `/var/log/containers` and `/var/log/pods`, plus ECK's writable hostPath
    `/var/lib/logging/filebeat/filebeat-data` for its registry, and the
    `logging` namespace labelled `pod-security.kubernetes.io/enforce:
    privileged` for that.

## Rationale
ECK is Elastic's supported way to run the stack on Kubernetes and turns TLS,
users and wiring into reconciled state instead of hand-made Secrets. A
one-node cluster with small heaps fits the measured headroom (about 11.9 GiB
available in WSL before install). Matching the operator to the cluster's
supported Kubernetes range avoids running an operator outside its tested
platform. Running API calls inside the Elasticsearch container keeps the
superuser password out of shells, arguments and logs, at the cost of mounting
it in a Pod that already holds every log it could read.

## Consequences
- **Single node, no replica.** Losing the node's local-path volume, or
  deleting the `Elasticsearch` resource (its volume claim is deleted with
  it), loses all stored logs. Logs are a learning convenience here, not a
  record; nothing backs them up.
- **local-path does not enforce the 10Gi request.** The volume is a host
  directory on a disk with about 943 GB free, so Elasticsearch's disk
  watermarks only act near the host's limit. The ILM delete phase is the
  real bound.
- **Cluster-wide operator RBAC.** The all-in-one operator can read and change
  Secrets and workloads in every namespace, including MiniShop's. A narrower
  alternative is ECK's Helm chart with `createClusterScopedResources: false`
  and `managedNamespaces: [logging]` (namespaced Roles only, webhook and node
  label features off, CRDs installed separately). It was not chosen for the
  first install because it departs from Elastic's documented all-in-one path;
  the owner may prefer it.
- **Licensing.** ECK runs under the Elastic Basic license by default (free;
  ECK itself is under the Elastic License 2.0). Basic covers what this uses:
  security, TLS, ILM, Kibana and Filebeat. No trial or Enterprise license is
  started.
- **Kernel dependency.** Elasticsearch uses mmap and needs
  `vm.max_map_count` of at least 262144 on the node; kind nodes inherit it
  from the WSL kernel today. A host without it fails Elasticsearch's
  bootstrap checks.
- **Filebeat registry on nodes.** The hostPath registry survives
  `teardown-logging.sh`; a later deploy resumes from it instead of
  re-reading old files.
- **Raw `manifests/` only.** The stack has no Helm or Kustomize packaging.
- **Kibana data view.** Filebeat does not load Kibana dashboards; the operator
  creates a `filebeat-*` data view once in Kibana.

## Verification
- Offline: `scripts/validate-logging-manifests.sh` validates all 12
  resources against Kubernetes schemas and schemas built from the pinned
  CRDs (none skipped) and checks versions, digests, resources and retention;
  eight seeded mistakes were each caught.
- kind-learn, read-only: server dry-run of the CRDs and every cluster-scoped
  object passed and nothing persisted.
- Throwaway cluster (`scripts/test-logging.sh`, same Kubernetes and kindnet
  as kind-learn, 497 s): deploy, ingestion and decoding of a backend test
  line, ILM linkage, every allowed and denied NetworkPolicy path,
  port-forward access, Filebeat RBAC, a re-deploy after a Filebeat restart,
  and teardown with MiniShop Pods untouched all passed; no output held the
  elastic password. Measured 2770 MiB and 212m CPU for the stack with three
  Filebeat Pods.
- Not yet deployed to kind-learn. Details: the
  [ECK logging record](../devlog/2026-11-14-elk-logging.md).

## Related Docs
- [ECK logging record](../devlog/2026-11-14-elk-logging.md)
- [ADR 0007](./0007-platform-observability.md)
- [ADR 0016](./0016-data-tier-network-policy.md)
