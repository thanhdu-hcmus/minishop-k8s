---
title: Git-owned Ingress, exact frontend selectors, and legacy retirement plan
requirement: Issue #38 — retire the legacy stack and own the Ingress in Git
status: verified
last_updated: 2026-11-08
date: 2026-11-08
issue: "#38"
pr: "not recorded"
tier: T2
reconstructed: false
source: "Recorded during implementation"
metrics: { wall_time: "not recorded", usage: "not recorded", review_rounds: "not recorded", ci_failures: "not recorded" }
---

# Git-Owned Ingress, Exact Frontend Selectors, and Legacy Retirement Plan

## Goal
Package an Ingress for `minishop.local` that routes to `minishop-frontend`, make
the frontend Service select only MiniShop Pods, give a fresh kind cluster a
pinned, Git-owned ingress-nginx install path, and write the ordered runbook that
retires the legacy objects. The cluster was accessed read-only: nothing was
applied, deleted, scaled, or upgraded.

## Live state observed (read-only, 2026-11-08)
- `webapp`: legacy Deployments `frontend` (0/0) and `backend` (0/3, Pods
  `Unknown`); legacy Services `frontend`, `backend`, and
  `frontend-loadbalancer-demo` (LoadBalancer `172.18.255.200` from MetalLB pool
  `minishop-pool`); CronJob `postgres-report` (every 5 minutes, counts
  `marketItems` in CNPG `kumademo`); completed Job `db-migration`; HPAs
  `backend` and `minishop-backend`; ConfigMaps `minishop-runtime` and
  `minishop-postgres-schema` and Secret `postgres-app-creds`, used only by the
  legacy workloads.
- Legacy Ingress `minishop-frontend` (class `nginx`, host `minishop.local`,
  path `/` Prefix, Service `frontend:8080`) has no Helm labels or annotations.
- Legacy frontend Pod template labels are `component=frontend,name=minishop`
  only, without `part-of`. The Helm frontend Pods add `part-of=minishop`.
- `data`: legacy StatefulSet `redis` (`--appendonly yes`, PVC `data-redis-0`)
  and CNPG Cluster `minishop-postgres` (2 instances, database and owner
  `kumademo`, no `spec.backup`, no Backup or ScheduledBackup objects, status
  `Instance Status Extraction Error: HTTP communication issue` just after the
  Docker restart). All five PVs use reclaim policy `Delete`.
- ingress-nginx controller `v1.12.4` (digest-pinned) runs on the control plane
  with hostPorts 80/443, nodeSelector `ingress-ready=true`, and the kind
  provider arguments. The control-plane node carries `ingress-ready=true`, but
  `cluster/kind-config.yaml` does not set it. The GitHub API showed
  `kubernetes/ingress-nginx` archived (checked during implementation and again
  by the reviewer on 2026-11-08). Its last releases are `controller-v1.15.1`,
  `v1.14.5`, and `v1.13.9` (2026-03-19). The v1.12 line ended at v1.12.8
  (2025-11-04), four patch releases after the running v1.12.4.
- MetalLB `v0.14.9` with one `IPAddressPool` and one `L2Advertisement`, both
  `minishop-pool`. Only `frontend-loadbalancer-demo` is type LoadBalancer.

## Changes
- **Exact frontend selection** (`fix(webapp)`): the `minishop-frontend`
  Service selector, the `minishop-frontend` NetworkPolicy podSelector, and the
  backend policy's frontend peer add `app.kubernetes.io/part-of=minishop`, in
  the chart and in `manifests/20-webapp/`. The Deployment selector is
  unchanged. The `validate-app.sh` comment now names only the Deployment
  selector as overlapping.
- **ingress-nginx install path** (`feat(cluster)`): `cluster/kind-config.yaml`
  labels the control plane `ingress-ready=true`. New
  `scripts/deploy-ingress-nginx.sh` downloads the kind provider manifest for
  `controller-v1.12.4`, checks SHA-256
  `458724636702c34320774f011e642b4a80212e2f79f98f14763fa06a3169cd93`, applies
  it, waits for the controller rollout, then waits up to 180 s for the
  admission webhook CA bundle.
- **Ingress** (`feat(chart)`): `charts/minishop/templates/ingress.yaml` and
  `manifests/20-webapp/ingress.yaml` (added to the Kustomize base and dev
  teardown) define Ingress `webapp/minishop` and NetworkPolicy
  `minishop-frontend-from-ingress`. Chart values `ingress.enabled` (true),
  `ingress.className` (`nginx`), and `ingress.host` (`minishop.local`) are
  required by the schema. `require_no_conflicting_ingress` in `scripts/lib.sh`
  runs in `deploy-helm.sh` and `deploy-kustomize-dev.sh`. `validate-helm.sh`
  checks that the schema rejects host `Not_A_Host` and that
  `ingress.enabled=false` renders neither object.
- **Runbook** (`docs(runbook)`): `docs/legacy-retirement-runbook.md`.
- **ADR** (`docs(decisions)`): `docs/decisions/0011-ingress-ownership-and-legacy-retirement.md`,
  status proposed.

## Decisions
- Chart Ingress name `minishop`, not `minishop-frontend`, so Helm never meets
  the unmanaged legacy object. Annotating the legacy Ingress for Helm adoption
  was rejected.
- Leave the immutable Deployment selector; the Service selector fix and the
  legacy Deployment's removal end the overlap without a recreate.
- Pin ingress-nginx to v1.12.4, the running version, instead of v1.12.8 or
  the final upstream v1.15.1, so the Git path describes the live cluster
  without changing it. The bump or replacement is a follow-up.
- Download plus checksum, following the metrics-server pattern in
  `deploy-platform.sh`, instead of vendoring the 677-line manifest.
- MetalLB stays out of Git; removal is recommended and left to the owner.
- Data retention is deferred to Issue #42.

## Problems

### Pre-existing yamllint line-length errors in the frontend manifest
- **Symptom:** yamllint 1.35.1 reported `manifests/20-webapp/frontend.yaml`
  lines 2, 3, and 48 (98, 90, and 108 > 80 characters).
- **Cause:** The image-provenance comments and the digest-pinned image
  reference predate this Issue; `origin/main` fails the same way. The lines this
  branch changes pass.
- **Fix:** None on this branch, to keep the diff to the selector. Follow-up:
  wrap them with `yamllint disable/enable rule:line-length` as `backend.yaml`
  does. `cluster/kind-config.yaml` has the same pre-existing errors on its four
  digest-pinned node image lines (104 > 80); the lines this branch adds pass.

### ingress-nginx admission rejects a second Ingress for minishop.local
- **Symptom:** `kubectl apply --dry-run=server -f
  manifests/20-webapp/ingress.yaml` returned `admission webhook
  "validate.nginx.ingress.kubernetes.io" denied the request: host
  "minishop.local" and path "/" is already defined in ingress
  webapp/minishop-frontend`. The NetworkPolicy in the same file was admitted.
- **Cause:** The ingress-nginx validating webhook (`failurePolicy: Fail`,
  CREATE and UPDATE on Ingresses) rejects an Ingress whose host and path
  overlap an existing one. The legacy Ingress claims `minishop.local` and `/`.
- **Tried:** The same Ingress with host `minishop-dryrun.local` was admitted,
  which isolates the cause to the host and path overlap.
- **Fix:** The two Ingresses cannot coexist, so the cutover deletes the legacy
  Ingress before the Helm upgrade that creates `webapp/minishop`. A new
  `require_no_conflicting_ingress` preflight in `scripts/lib.sh`, called by
  `deploy-helm.sh` and `deploy-kustomize-dev.sh`, stops before anything is
  applied while another Ingress claims the host. Without it, `helm upgrade`
  would fail part-way and leave a failed revision.
- **Verified by:** Server dry-runs above; preflight checked against the live
  cluster (see Verification).

### The Ingress preflight did not fail closed inside a condition
- **Symptom:** A test that stubbed `kubectl_for_minishop` to fail and ran
  `( require_no_conflicting_ingress ) || ...` reported success.
- **Cause:** Bash ignores `set -e` in a function called from an `||` or `if`
  context, so the failed `conflicts=$(...)` assignment did not stop it.
- **Fix:** Return 1 explicitly with `Could not list Ingresses to check for a
  host conflict.` when the listing pipeline fails. Also removed a trailing
  space from the conflict message.
- **Verified by:** Re-run: the live check fails on
  `webapp/minishop-frontend`; stubbed listings pass with only
  `webapp/minishop`, fail on a multi-host Ingress claiming the host, and fail
  closed on a kubectl error.

### Runbook checks assumed a dead legacy backend and in-pod sha256sum
- **Symptom:** Running the runbook's read-only checks against the live cluster
  showed the legacy `backend` Deployment at 3/3 Ready (it was 0/3 `Unknown`
  earlier in the session). The consumer check `grep -o
  'http://[a-z-]*:3001'` missed the legacy frontend's
  `http://backend.webapp.svc.cluster.local:3001`, and the legacy Redis image
  has no `sha256sum`.
- **Cause:** The legacy Pods recovered after the Docker restart, so readiness
  is not a usable precondition; the character class excluded dots; the
  `kvn0218/kuma-redis` image ships `redis-check-rdb` but not `sha256sum`.
- **Fix:** Step 4 now checks that nothing calls the legacy backend (legacy
  frontend gone, only `http://minishop-backend:3001` in workload args) with
  `[a-z0-9.-]*`. Step 6 compares the copied RDB byte-for-byte with `cmp`.
- **Verified by:** The corrected grep lists both URLs today, as the runbook
  notes; `redis-check-rdb` and `pg_restore` exist in the Pods; all 16 step 1
  exports succeeded into a scratch directory with no Secret among them.

### Item requests timed out once after the Docker restart
- **Symptom:** `curl -H 'Host: minishop.local' http://127.0.0.1/items` timed
  out after 10 s while `/` returned 200.
- **Cause:** Not isolated; it coincided with cluster recovery after the Docker
  Desktop restart (Pods had restarted about two minutes earlier).
- **Fix:** None needed. About 20 minutes later the same request returned 200
  in 0.03 s.

### Helm's server dry-run does not call admission webhooks
- **Symptom:** `helm upgrade --dry-run=server` with the Ingress enabled
  succeeded (revision 4 `pending-upgrade`, nothing persisted) although the
  webhook rejects that Ingress.
- **Cause:** Helm's dry-run checks rendering, schema, and resource ownership,
  but does not send dry-run writes to the API server, so admission and
  immutable-field validation do not run.
- **Fix:** Also ran `kubectl diff --server-side --force-conflicts
  --field-manager=helm` on the `helm template` output. That sends server-side
  dry-run patches, which run admission and immutability checks.
- **Verified by:** With the Ingress enabled the diff returns the webhook
  denial; with it disabled the only changes are the three `part-of` selector
  lines and `replicas: 3 -> 1` on `minishop-backend`. The replicas line is a
  real change, not a diff artifact (corrected in review, see below).

### The step 2 upgrade drops the backend to one replica
- **Symptom:** The first version of this record called `replicas: 3 -> 1` a
  diff artifact and said Helm patches only fields that changed between release
  manifests. The reviewer flagged this as wrong.
- **Cause:** Helm 3 builds a three-way merge patch from the previous release
  manifest, the live object, and the new manifest. Fields the new manifest
  sets that differ from the live object are patched too. `values-dev.yaml`
  sets `replicas.backend: 1`, so the upgrade sets the HPA-held live value of 3
  to 1 until HPA `minishop-backend` restores its minimum of 3.
- **Earlier occurrence:** The owner's 2026-11-07 upgrade to revision 3 used
  the same values. Read-only evidence is consistent with the same dip:
  revision 3 is dated 15:39:34Z, the HPA `status.lastScaleTime` is 8 s later
  at 15:39:42Z, and the three current backend Pods were created at 15:39:35Z,
  15:39:42Z, and 15:40:02Z. Events from that time have expired, so the dip is
  inferred, and how many Pods stayed Ready during it was not recorded.
- **Fix:** Runbook step 2 now says to expect the dip. Changing the values or
  chart to avoid it is out of scope for this Issue.

### Review findings fixed in one pass
The T2 review found no blockers. These follow-ups were fixed together:
- `require_no_conflicting_ingress` still relied on the caller's `pipefail`
  to notice a kubectl failure inside the pipeline. It now captures the
  listing on its own with `|| { ...; return 1; }` and runs awk on the variable.
- `deploy-ingress-nginx.sh` now prints the owner-approved
  `kubectl label node learn-control-plane ingress-ready=true` command when no
  node carries the label, because `create-cluster.sh` never relabels an
  existing node. Its version comment now says v1.12.4 is kept to match the
  live controller and is four patch releases behind v1.12.8.
- Runbook step 2 runs `deploy-helm.sh` as a check before deleting anything.
  It must stop with the preflight message. Every check before the preflight is
  read-only: `command -v`, a readable kubeconfig, `kubectl config
  get-contexts`, `cluster-info`, and gets of the namespaces, Secrets,
  ServiceAccount, and HPA. Step 2 also states the backend dip and that the
  curl cannot prove the NetworkPolicy, which `kindnet` does not enforce.
  Step 3 warns against `--cascade=orphan`. Step 8 downloads the MetalLB
  manifest, checks SHA-256
  `951065e85692aa106f1bb5d5a487d9306154923a794ab1d82122881cbaf588e4`, and
  deletes or re-applies the local file.
- The troubleshooting selector entry now says only the Deployment selector
  lacks `part-of`.
- Docs commits were regrouped so each scope matches its files. The pre-review
  history is kept at local branch `backup/38-pre-review` (`0454fb6`).

### Git lost its working directory in the per-commit worktree
- **Symptom:** Validating each commit in a detached worktree under the
  scratchpad (`/mnt/c/...`), `git diff --check` failed with `fatal: Unable to
  read current working directory` after the Docker-based yamllint run, from
  the second commit on.
- **Cause:** Not isolated; it appeared only for git commands run in the
  `/mnt/c` worktree after Docker bind-mounted it. The validators themselves
  had already completed.
- **Fix:** Ran `git diff --check <sha>^ <sha>` and the CRLF scan for every
  commit from the main checkout instead.
- **Verified by:** Every commit reports no whitespace errors and no CRLF;
  `git worktree list` shows only the main checkout.

## Verification
All cluster access was read-only. No apply, delete, scale, or Helm write was
run; the dry-runs below persist nothing.

- Per commit, in a detached worktree: `bash -n` on every script,
  `validate-kustomize.sh` (dev, prod, dev-teardown) and `validate-helm.sh`
  (default, dev, prod) passed for every commit on the branch, before and after
  the review fixes. commitlint 19.8.1 passed on `origin/main..HEAD`.
  Kubeconform v0.6.7 passed
  on the changed `manifests/` and `kustomize/` files, ShellCheck v0.10.0 on the
  changed scripts, and yamllint 1.35.1 on changed YAML except the pre-existing
  line-length errors recorded above. `git diff --check` and a CRLF scan were
  clean for every commit.
- Renders: the chart renders 15 resources per values file (13 before), adding
  Ingress `minishop` and NetworkPolicy `minishop-frontend-from-ingress`;
  Kustomize dev and prod render 27 resources each (25 before) and the dev
  teardown 15 (13 before), including both.
- `helm upgrade minishop charts/minishop -n webapp --dry-run=server --set
  replicas.backend=1 --set replicas.frontend=1` (Helm v3.16.4) succeeded with
  the Ingress enabled and disabled: no ownership or immutable-field error.
- `kubectl diff --server-side --force-conflicts --field-manager=helm` of the
  same render: with the Ingress disabled, only the three `part-of` lines and
  the backend `replicas: 3 -> 1` described above; with it enabled, the webhook
  denial described above.
- `kubectl diff` of the pinned ingress-nginx manifest against the live
  cluster: only the two admission Jobs differ. The MetalLB v0.14.9 native
  manifest differs only in the runtime-injected CRD conversion CA bundle.
- `require_no_conflicting_ingress`: fails on the live legacy Ingress, passes
  and fails correctly on stubbed listings, and fails closed on a kubectl error,
  also with `errexit` and `pipefail` off. Calling the `deploy-helm.sh`
  prerequisite functions in script order against the live cluster passed
  every check and stopped at the preflight message, without reaching Helm.
- Runbook read-only checks exercised against the live cluster as recorded
  above. The current Ingress path returns 200 for `/` and `/items` with
  `Host: minishop.local` on `127.0.0.1`.
- Not run: `deploy-ingress-nginx.sh` (it applies to the cluster), creating a
  fresh kind cluster from the changed config (out of scope; port 80 is held by
  kind-learn), and every runbook step that changes state.

## Documentation
- `docs/minishop-operator-guide.md`: fresh-cluster sequence to
  `http://minishop.local` and the existing-cluster cutover dependency.
- `docs/troubleshooting.md`: preflight refusal and webhook duplicate-host
  denial; the selector entry now reflects the narrowed Service selector.
- `docs/README.md`: index entries for ADR 0011, the runbook, and this record.

## Follow-up
- Owner decisions: approve runbook step 2 (legacy Ingress deletion and chart
  Ingress cutover) and each later step; decide MetalLB removal (step 8);
  decide data retention in Issue #42 before step 7.
- Open an Issue for ingress-nginx (archived upstream): weigh v1.12.8 (same
  minor version) against v1.15.1 (final release) against a maintained Gateway
  API implementation.
- Wrap the pre-existing long lines in `manifests/20-webapp/frontend.yaml` and
  `cluster/kind-config.yaml` for yamllint.
- Accept or amend ADR 0011 (status proposed).
- Known gaps left on purpose: no TLS, a single ingress-nginx controller
  replica, NetworkPolicy enforcement unverified on kindnet.
- Scripts in `scripts/`, including the new `deploy-ingress-nginx.sh`, are
  committed without the executable bit (mode 100644); run them with `bash`.
- The worker labels `workload-type=app|database` on kind-learn are not in
  `cluster/kind-config.yaml` either; nothing in Git uses them today.
