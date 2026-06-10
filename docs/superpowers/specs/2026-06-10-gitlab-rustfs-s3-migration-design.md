# GitLab Object Storage Migration: bundled MinIO → RustFS

- **Date:** 2026-06-10
- **Status:** ✅ IMPLEMENTED & VERIFIED 2026-06-10 — GitLab live on RustFS. Key deviations: registry bucket is `registry` (not `gitlab-registry`); `global.minio.enabled: false` was required for external storage to take effect; runner cache repointed via `gitlab-runner.runners.config` TOML. See the implementation plan's status banner + project memory.
- **Scope:** GitLab-scoped object storage only (not a shared homelab S3 — that can come later)
- **Related:** CE→EE edition flip (separate change, ship first); SOPS key leak incident 2026-06-08 (informs internal-only posture)

## 1. Context & Goal

GitLab's Helm release (`apps/gitlab/helmrelease.yaml`, chart `gitlab` 9.11.3) currently uses the chart's **bundled MinIO** for all object storage. GitLab itself documents the bundled MinIO as not for production. Goal: move GitLab onto a dedicated, self-owned S3 service — **RustFS** (Rust-native, S3-compatible) — with a safe, reversible cutover.

## 2. Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Engine | **RustFS** | Rust-first stack alignment; MinIO-compatible API. Beta — de-risked via canary + rollback. |
| Scope | **GitLab-only** | YAGNI; can be promoted to a shared homelab S3 later without redoing the cutover. |
| Risk scope | **All-on-RustFS, validate-first** | Registry + rails buckets both on RustFS, but only after a standalone registry canary passes; old MinIO kept as rollback until verified. |
| Exposure | **Cluster-internal only** | No IngressRoute for RustFS. Aligns with incident response (reduce external surface). GitLab reaches it over cluster DNS. |

## 3. Current State (mapped)

- `global.minio.enabled` is on by chart default; the release only overrides `minio.persistence` (`tank`, 50Gi).
- **No `object_store` / connection config anywhere in Git** — the chart auto-wires every consumer (registry, LFS, artifacts, uploads, packages, MR diffs, Terraform state, CI secure files, dependency proxy, backups, tmp) to the in-cluster MinIO via auto-generated secrets. `secrets/gitlab/` is empty.
- Storage backend: OpenEBS ZFS (`zfs.csi.openebs.io`), storage classes `fast` / `tank`.
- Ingress: `minio.cherkaoui.ch` → bundled MinIO console/API (dropped post-cutover); `registry.cherkaoui.ch` → registry (writes to MinIO today).

## 4. Risk Assessment: RustFS maturity

| Signal | Finding (researched 2026-06-10) |
|---|---|
| Release | `1.0.0-beta.8`; **GA targeted July 2026**; all releases flagged pre-release |
| Independent eval | Milvus (June 2026): *"not production-ready today"*; **~330% read-latency regression vs MinIO**; functionally a working MinIO drop-in (Put/Get/multipart/SigV4 OK) |
| Registry compat | **Undocumented / untested** for CNCF Distribution S3 driver. Primitives (multipart, SigV4) are supported, so it *should* work — unverified |
| Mode | Single-node single-disk is the supported mode; distributed mode "Under Testing" |

**Mitigations baked into this design:** (a) registry canary before any GitLab change; (b) old MinIO PVC retained as rollback until verification passes; (c) internal-only exposure; (d) accept the latency regression as tolerable for a homelab. If the canary fails, fall back to Garage (re-evaluate) or the hybrid (registry stays on MinIO).

## 5. Target Architecture

### 5.1 Placement & files

RustFS lives in the `gitlab` namespace as new `apps/gitlab/` resources:

- `deploy-rustfs.yaml` — Deployment, `strategy: Recreate` (single replica; Recreate avoids two pods mounting the RWO volume during rollout). StatefulSet is an acceptable alternative.
- `svc-rustfs.yaml` — ClusterIP, port 9000 (S3). **No IngressRoute.**
- `pvc-rustfs.yaml` — RWO on `tank`, size from preflight (default **60Gi**, headroom over the 50Gi source).
- Added to `apps/gitlab/kustomization.yaml` (PVC before Deployment per repo ordering).

### 5.2 RustFS deployment specifics (researched, not assumed)

| Item | Value |
|---|---|
| Image | `rustfs/rustfs:1.0.0-beta.8` (pin; not `latest`) |
| S3 port | `9000` |
| Console | disabled (`RUSTFS_CONSOLE_ENABLE=false`) — internal, unused, reduces surface |
| Data dir | mount PVC at `/data`; set `RUSTFS_VOLUMES=/data/rustfs0` |
| Credentials | `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` (from `rustfs-credentials` secret via `envFrom`) |
| securityContext | `runAsUser: 10001`, `runAsGroup: 10001`, `fsGroup: 10001` |
| Single-volume contingency | If RustFS refuses to start on the single ZFS volume (disk-independence check), set `RUSTFS_UNSAFE_BYPASS_DISK_CHECK=true` (safe on a single trusted ZFS dataset) |

### 5.3 Networking & security

- GitLab → RustFS over `http://rustfs.gitlab.svc.cluster.local:9000`, **path-style**, plaintext (in-cluster). TLS terminates at Traefik for the *registry* host only; RustFS itself is never exposed.
- **Fresh, strong credentials** generated for this deploy — not reused from any material touched by the 2026-06-08 leak.
- No plaintext secrets in Git (see §7.4).

## 6. Bucket Map

Keep bucket names **identical to the bundled MinIO** so object keys map 1:1 and the copy is a straight per-bucket mirror. Expected default set (⚠ **confirm authoritatively from the preflight `mc ls`, §12** — names are the source of truth, especially the tmp bucket):

`gitlab-registry` · `gitlab-artifacts` · `git-lfs` · `gitlab-uploads` · `gitlab-packages` · `gitlab-mr-diffs` · `gitlab-terraform-state` · `gitlab-ci-secure-files` · `gitlab-dependency-proxy` · `gitlab-backups` · `tmp` (chart default may be `gitlab-tmp` — confirm)

RustFS does not auto-create buckets; create each with `mc mb` during the runbook.

## 7. GitLab Rewiring

### 7.1 Three secrets — three different formats

The registry and the backup toolbox do **not** share the rails connection secret. Exact keys verified against the chart's example files.

**Secret 1 — `gitlab-rails-storage`, key `connection`** (Fog/CarrierWave YAML; covers artifacts/LFS/uploads/packages/diffs/terraform/secure-files/dependency-proxy):

```yaml
provider: AWS
region: us-east-1
aws_access_key_id: <ACCESS_KEY>
aws_secret_access_key: <SECRET_KEY>
endpoint: "http://rustfs.gitlab.svc.cluster.local:9000"
path_style: true
enable_signature_v4_streaming: false   # safer for non-AWS S3-compatible backends
```

**Secret 2 — `registry-storage`, key `config`** (Docker Distribution `s3` driver YAML):

```yaml
s3:
  bucket: gitlab-registry
  accesskey: <ACCESS_KEY>
  secretkey: <SECRET_KEY>
  region: us-east-1
  regionendpoint: "http://rustfs.gitlab.svc.cluster.local:9000"
  pathstyle: true
  v4auth: true
redirect:
  disable: true        # clients must stream THROUGH the registry, not be redirected to the internal S3 URL — confirm placement during canary
```

**Secret 3 — `gitlab-s3cfg`, key `config`** (s3cmd INI for the backup toolbox):

```ini
[default]
access_key = <ACCESS_KEY>
secret_key = <SECRET_KEY>
bucket_location = us-east-1
host_base = rustfs.gitlab.svc.cluster.local:9000
host_bucket = rustfs.gitlab.svc.cluster.local:9000
use_https = False
signature_v2 = False
multipart_chunk_size_mb = 128
```

### 7.2 HelmRelease values changes

```yaml
global:
  minio:
    enabled: false
  registry:
    bucket: gitlab-registry
  appConfig:
    object_store:
      enabled: true
      proxy_download: true            # REQUIRED: endpoint is cluster-internal; GitLab must proxy, not hand clients an unreachable presigned URL
      connection:
        secret: gitlab-rails-storage
        key: connection
    artifacts: { bucket: gitlab-artifacts }
    lfs: { bucket: git-lfs }
    uploads: { bucket: gitlab-uploads }
    packages: { bucket: gitlab-packages }
    externalDiffs: { bucket: gitlab-mr-diffs }        # enable only if MR external diffs are used
    terraformState: { bucket: gitlab-terraform-state }
    ciSecureFiles: { bucket: gitlab-ci-secure-files }
    dependencyProxy: { bucket: gitlab-dependency-proxy }  # enable only if dependency proxy is used
    backups:
      bucket: gitlab-backups
      tmpBucket: tmp                  # match the source bucket name from preflight
registry:
  storage:
    secret: registry-storage
    key: config
gitlab:
  toolbox:
    backups:
      objectStorage:
        backend: s3
        config:
          secret: gitlab-s3cfg
          key: config
```

### 7.3 Correctness gotchas (because the endpoint is cluster-internal)

1. **`proxy_download: true`** (rails) — otherwise browsers receive a presigned URL pointing at `rustfs.gitlab.svc`, which they can't reach.
2. **Registry redirect disabled** — same reason for docker clients; they must stream through the registry pod, which can reach the internal S3.
3. **Use the legacy `s3` driver**, not `s3_v2`, to minimize variables for the canary. (GitLab 19 will force `s3_v2` — tracked as a follow-up.)
4. **`enable_signature_v4_streaming: false`** — avoids a streaming-signature edge case some S3-compatible backends mishandle.

### 7.4 Secret management — lockbox

All three GitLab secrets plus `rustfs-credentials` are `type: Opaque`, so per the repo's lockbox-first default they are provisioned via `lbx`, **not** SOPS (SOPS stays for bootstrap/typed secrets only):

```bash
lbx set -n gitlab rustfs-credentials  RUSTFS_ACCESS_KEY=<KEY> RUSTFS_SECRET_KEY=<SECRET>
# multi-line blobs: feed from files rather than inline, e.g.
lbx set -n gitlab gitlab-rails-storage connection="$(cat rails.yaml)"
lbx set -n gitlab registry-storage     config="$(cat registry.yaml)"
lbx set -n gitlab gitlab-s3cfg         config="$(cat s3cfg.ini)"
```

The same `<ACCESS_KEY>`/`<SECRET_KEY>` must appear in all four (write the temp files to `/dev/shm`, never into the repo, and shred them after). Controller mirrors on next sync (~60s); confirm `lbx`'s exact value-from-file syntax against your CLI version.

## 8. Validate-First: Registry Canary (before any GitLab change)

1. Deploy RustFS; `lbx set rustfs-credentials`; create buckets with `mc mb`.
2. Run a **throwaway `registry:2` (CNCF Distribution) pod** configured with the RustFS `s3` driver (same secret 2 content) against the `gitlab-registry` bucket.
3. `docker login` → `docker push` a small image → `docker pull` it back → fetch the manifest. Confirm objects land under `docker/registry/v2/...` in RustFS.
4. **Gate:** only proceed to cutover if this passes. If it fails (redirect, multipart, or signature issue), stop — no GitLab downtime spent — and fall back.

## 9. Migration & Cutover Runbook

> Prereq: CE→EE flip already shipped and verified (separate commit). Fresh GitLab backup + `gitlab-rails-secret` in hand.

1. **Deploy RustFS** via Flux (commit+push `apps/gitlab/` additions; `flux reconcile`). `lbx set` the four secrets.
2. Create all buckets on RustFS (`mc mb`).
3. **Registry canary (§8). Gate.**
4. **Bulk copy while live:** `mc mirror` each bundled-MinIO bucket → RustFS (captures ~99%).
5. **Maintenance window:** scale down writers — `webservice`, `sidekiq`, `registry` (and pause backup CronJob).
6. **Final delta sync:** `mc mirror` again per bucket.
7. **Flip config:** apply §7.1–§7.2 (secrets already in lockbox; values via HelmRelease). Commit+push, `flux reconcile helmrelease gitlab`.
8. **Scale back up** (autoscaling minReplicas restores pods).
9. **Verify (§11).**
10. **Only after green:** remove `minio` overrides + `ingressroute-minio.yaml`, then reclaim the old MinIO PVC.

## 10. Rollback

At any point **before step 10**, revert the HelmRelease commit → Flux restores bundled MinIO. The old MinIO PVC is untouched until verification passes, so no data is at risk. The canary (§8) means registry incompatibility is caught with zero GitLab downtime.

## 11. Verification Checklist

- [ ] `docker pull` of an existing image from `registry.cherkaoui.ch`
- [ ] `docker push` a new tag; confirm objects in RustFS `gitlab-registry`
- [ ] CI artifact download from a past job
- [ ] `git lfs` clone/fetch of an LFS object
- [ ] Upload renders (avatar / attachment)
- [ ] Package pull (if packages used)
- [ ] `backup-utility` run lands a tarball in `gitlab-backups`
- [ ] No `502` / object-storage errors in webservice + registry logs

## 12. Preflight (size the PVC & confirm bucket names)

```bash
kubectl -n gitlab get pvc | grep minio
kubectl -n gitlab exec deploy/gitlab-minio -- sh -c \
  'mc alias set l http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD >/dev/null 2>&1; \
   mc ls --recursive --summarize l | tail -5; mc ls l'
```

Use actual used size to set the RustFS PVC; use `mc ls l` output as the **authoritative** bucket-name list.

## 13. Out of Scope / Follow-ups

- **CE→EE edition flip** + Service Ping disable — separate change, already staged in the working tree; ship and verify **first**.
- Migrate registry driver `s3` → `s3_v2` before GitLab 19 (s3 removed there).
- Promote RustFS to a shared homelab S3 (own namespace, multi-tenant, ingress) — future.
- RustFS GA tracking (July 2026) — bump off beta when stable.

## 14. Open Items

- Exact chart mechanism/placement for disabling registry redirect (validated by the canary regardless).
- Actual `tmp` bucket name (`tmp` vs `gitlab-tmp`) — from preflight.
- PVC size — from preflight.

## Sources

- RustFS: docs.rustfs.com (installation/docker, single-node, s3-compatibility, mc), github.com/rustfs/rustfs, Docker Hub `rustfs/rustfs`, Milvus RustFS evaluation (June 2026).
- GitLab: docs.gitlab.com/charts/advanced/external-object-storage, /charts/charts/globals (consolidated object storage), /charts/charts/registry, /charts/backup-restore, and the chart `examples/objectstorage/{rails,registry}.s3.yaml`.
