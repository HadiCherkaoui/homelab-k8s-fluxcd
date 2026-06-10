# GitLab → RustFS S3 Migration Implementation Plan

> **STATUS: IMPLEMENTED & VERIFIED 2026-06-10.** GitLab is live on RustFS. Deviations found during execution: the registry bucket is `registry` (not `gitlab-registry`), and `runner-cache`/`gitlab-pages` buckets also exist; `global.minio.enabled: false` is **required** (leaving MinIO enabled keeps the chart auto-wiring to it); push must happen *before* quiescing webservice (GitLab is its own git remote); the runner cache was repointed via `gitlab-runner.runners.config` inline TOML (chart 0.88.0), not the simple `s3*` keys. Old MinIO PVC retained (PV `Retain`) as a rollback anchor pending deletion after soak. Full notes in project memory `gitlab-rustfs-object-storage-migration`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move GitLab's object storage (registry + all rails buckets + backups) off the chart's bundled MinIO onto a dedicated, cluster-internal RustFS S3, with a registry canary gate and a fully reversible cutover.

**Architecture:** Deploy RustFS (single-node, internal-only) in the `gitlab` namespace on ZFS. Prove the container-registry S3 path against it with a throwaway `registry:2` canary *before* touching GitLab. Then mirror data MinIO→RustFS, flip the HelmRelease to external object storage (three separate secrets: rails Fog connection, registry Distribution driver, toolbox s3cmd), and cut over inside a maintenance window. Old MinIO PVC is retained as rollback until verification passes.

**Tech Stack:** Flux v2 (GitOps), Kustomize, GitLab Helm chart 9.11.3, RustFS `1.0.0-beta.8`, `mc` (MinIO client) for data copy, lockbox (`lbx`) for all secret values, OpenEBS ZFS (`tank`).

---

## Execution model (read first)

This is an **infrastructure/GitOps** plan, not an app-code plan, so two adaptations:

- **"Tests" = validation gates.** There is no unit-test harness for YAML. Each task's verification is a real gate: `kustomize build`, `kubectl apply --dry-run`, `flux reconcile` status, the canary smoke test, or the post-cutover checklist. Treat a failed gate exactly like a failed test — stop and fix before proceeding.
- **Two kinds of step:**
  - **[GIT]** — create/modify files, `kustomize build`, commit/push. Doable from the repo checkout (agent or operator).
  - **[CLUSTER]** — `lbx` / `kubectl` / `flux` / `mc` / `docker`. Must run against the live cluster by the operator (Hadi), e.g. via `! <cmd>` in-session. The agent cannot reach the cluster; do **not** fabricate cluster output — paste the real output back.

**Secret-hygiene invariants (enforced at every step):**
1. Credential **values** never enter Git. Only secret **names** are referenced in manifests. All values live in lockbox.
2. Temp files holding secret blobs are written under `/dev/shm` only, and `shred -u`'d immediately after `lbx set`.
3. Every `[GIT]` commit is gated by `pre-commit` (gitleaks + detect-private-key). Never use `--no-verify`.
4. Never paste `kubectl get secret -o yaml` output into a file or commit. Never `echo` a secret into the repo tree.
5. The same fresh `$ACCESS_KEY`/`$SECRET_KEY` (generated in Task 2) is reused across all four lockbox entries; it is distinct from anything touched by the 2026-06-08 leak.

---

## Prerequisites (gate before Task 1)

- [ ] **CE→EE flip already shipped + verified.** The `apps/gitlab/helmrelease.yaml` edition/usagePing edit is a *separate* change. Commit, push, reconcile, and confirm GitLab is healthy on EE **before** starting this migration. Do not bundle them.
- [ ] **Fresh GitLab backup taken**, including the `gitlab-rails-secret`. Confirm the backup tarball exists and the rails secret is saved off-cluster.
- [ ] Operator has working `kubectl`, `flux`, `lbx`, `mc`, and `docker` (or `podman`) CLIs.

---

## Task 1: Preflight — size the volume & enumerate buckets

**Files:** none (discovery only). Produces two facts used by later tasks: **PVC size** and the **authoritative bucket list** (esp. the real `tmp` bucket name).

- [ ] **Step 1 [CLUSTER]: Read bundled-MinIO usage + bucket names**

```bash
kubectl -n gitlab get pvc | grep -i minio
kubectl -n gitlab exec deploy/gitlab-minio -- sh -c \
  'mc alias set l http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; \
   echo "== buckets =="; mc ls l; \
   echo "== total usage =="; mc du l'
```

Expected: a list of buckets (`gitlab-registry`, `gitlab-artifacts`, `git-lfs`, `gitlab-uploads`, `gitlab-packages`, `gitlab-mr-diffs`, `gitlab-terraform-state`, `gitlab-ci-secure-files`, `gitlab-dependency-proxy`, `gitlab-backups`, and a tmp bucket — note whether it is `tmp` or `gitlab-tmp`) plus a total size.

- [ ] **Step 2: Record the two facts in this plan**

Set `PVC_SIZE` = round(used × 1.5, min 20Gi) and write the exact bucket list into Task 6's `mc mb` loop and Task 8's mirror loop. If used ≈ a few GiB, `60Gi` is the default and is safe (volume is expandable).

- [ ] **Step 3: Discover the bundled-MinIO secret (name + keys) for the mirror**

```bash
kubectl -n gitlab get secret | grep -i minio
kubectl -n gitlab get secret gitlab-minio-secret -o jsonpath='{.data}' | tr ',' '\n' | sed 's/:.*//'
```

Expected: a secret (commonly `gitlab-minio-secret`) with keys `accesskey` / `secretkey`. Record the exact name + key names for Task 8. **Do not print the values.**

---

## Task 2: Generate credentials & provision RustFS root secret (lockbox)

**Files:** none in Git. Creates lockbox entry `rustfs-credentials` → mirrored to `Secret/rustfs-credentials` in `gitlab`.

- [ ] **Step 1 [CLUSTER]: Generate fresh credentials into shell vars (never a repo file)**

```bash
export ACCESS_KEY="rustfs-$(openssl rand -hex 8)"
export SECRET_KEY="$(openssl rand -hex 24)"
```

- [ ] **Step 2 [CLUSTER]: Provision the RustFS root credentials via lockbox**

```bash
lbx set -n gitlab rustfs-credentials \
  RUSTFS_ACCESS_KEY="$ACCESS_KEY" \
  RUSTFS_SECRET_KEY="$SECRET_KEY"
```

- [ ] **Step 3 [CLUSTER]: Verify the mirrored Secret appeared (name + keys only)**

```bash
kubectl -n gitlab get secret rustfs-credentials \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}{"\n"}'
kubectl -n gitlab get secret rustfs-credentials -o jsonpath='{.data}' | tr ',' '\n' | sed 's/:.*//'
```

Expected (after ~60s sync): `lockbox-k8s-controller`, and keys `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY`. If missing: `kubectl -n lockbox-system rollout restart deploy/lockbox-k8s-controller`.

Keep `$ACCESS_KEY` / `$SECRET_KEY` exported in this shell for Tasks 3, 6, 7, 8.

---

## Task 3: RustFS manifests (PVC + Deployment + Service)

**Files:**
- Create: `apps/gitlab/pvc-rustfs.yaml`
- Create: `apps/gitlab/deploy-rustfs.yaml`
- Create: `apps/gitlab/svc-rustfs.yaml`
- Modify: `apps/gitlab/kustomization.yaml`

- [ ] **Step 1 [GIT]: Create the PVC** (`PVC_SIZE` from Task 1; default below)

```yaml
# apps/gitlab/pvc-rustfs.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rustfs-data
  namespace: gitlab
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: tank
  resources:
    requests:
      storage: 60Gi
```

- [ ] **Step 2 [GIT]: Create the Deployment** (internal-only; creds via `envFrom`, never literals)

```yaml
# apps/gitlab/deploy-rustfs.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustfs
  namespace: gitlab
  labels:
    app.kubernetes.io/name: rustfs
    app.kubernetes.io/part-of: gitlab
spec:
  replicas: 1
  strategy:
    type: Recreate            # single RWO volume — never run two pods at once
  selector:
    matchLabels:
      app.kubernetes.io/name: rustfs
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rustfs
        app.kubernetes.io/part-of: gitlab
    spec:
      securityContext:
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001          # makes the ZFS volume writable by the rustfs user
      containers:
        - name: rustfs
          image: rustfs/rustfs:1.0.0-beta.8
          env:
            - name: RUSTFS_VOLUMES
              value: /data/rustfs0
            - name: RUSTFS_ADDRESS
              value: ":9000"
            - name: RUSTFS_CONSOLE_ENABLE
              value: "false"      # internal, unused — reduce surface
          envFrom:
            - secretRef:
                name: rustfs-credentials   # RUSTFS_ACCESS_KEY / RUSTFS_SECRET_KEY
          ports:
            - name: s3
              containerPort: 9000
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            tcpSocket: { port: 9000 }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket: { port: 9000 }
            initialDelaySeconds: 20
            periodSeconds: 20
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 1Gi }
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustfs-data
```

- [ ] **Step 3 [GIT]: Create the Service** (ClusterIP — NO IngressRoute)

```yaml
# apps/gitlab/svc-rustfs.yaml
apiVersion: v1
kind: Service
metadata:
  name: rustfs
  namespace: gitlab
  labels:
    app.kubernetes.io/name: rustfs
    app.kubernetes.io/part-of: gitlab
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: rustfs
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
```

This yields the in-cluster endpoint `http://rustfs.gitlab.svc.cluster.local:9000`.

- [ ] **Step 4 [GIT]: Wire into the kustomization** (PVC before workload)

Edit `apps/gitlab/kustomization.yaml` — insert the three lines after `namespace.yaml`:

```yaml
resources:
  - namespace.yaml
  - pvc-rustfs.yaml
  - deploy-rustfs.yaml
  - svc-rustfs.yaml
  - helmrelease.yaml
  - ingressroute-gitlab.yaml
  - ingressroute-registry.yaml
  - ingressroute-minio.yaml
  - ingressroutetcp-ssh.yaml
```

- [ ] **Step 5 [GIT]: Validate the build (gate)**

```bash
kustomize build apps/gitlab >/dev/null && echo OK
```

Expected: `OK`. (If `kustomize` isn't installed locally, run `kubectl kustomize apps/gitlab >/dev/null && echo OK`.)

- [ ] **Step 6 [GIT]: Commit + push** (pre-commit gitleaks gates automatically)

```bash
git add apps/gitlab/pvc-rustfs.yaml apps/gitlab/deploy-rustfs.yaml apps/gitlab/svc-rustfs.yaml apps/gitlab/kustomization.yaml
git commit -m "feat(gitlab): deploy internal RustFS S3 (pre-migration, unused)"
git push
```

Expected: pre-commit passes (no secrets); push accepted by the server-side guard. These manifests are inert until GitLab is pointed at them, so shipping now is safe.

---

## Task 4: Reconcile & verify RustFS is healthy

- [ ] **Step 1 [CLUSTER]: Reconcile**

```bash
flux reconcile kustomization apps --with-source
```

- [ ] **Step 2 [CLUSTER]: Verify pod + PVC (gate)**

```bash
kubectl -n gitlab get pvc rustfs-data
kubectl -n gitlab rollout status deploy/rustfs --timeout=120s
kubectl -n gitlab logs deploy/rustfs --tail=30
```

Expected: PVC `Bound`; rollout `successfully rolled out`; logs show RustFS listening on `:9000`.
**If the pod crashes on the disk-independence check**, add `RUSTFS_UNSAFE_BYPASS_DISK_CHECK=true` to the env (safe on a single trusted ZFS dataset), re-commit, reconcile.
**If the volume is read-only / permission denied**, add an initContainer that `chown -R 10001:10001 /data` (busybox), re-commit, reconcile.

---

## Task 5: Registry canary — prove the S3 driver against RustFS (HARD GATE)

**Files:** none committed (throwaway). This is the make-or-break test for the untested registry-on-RustFS path. It also resolves the redirect-disable open item via `REGISTRY_STORAGE_REDIRECT_DISABLE`.

- [ ] **Step 1 [CLUSTER]: Create a throwaway canary bucket** (don't pollute `gitlab-registry`)

```bash
kubectl -n gitlab exec deploy/rustfs -- true   # ensure pod ready
kubectl -n gitlab run mc --rm -it --restart=Never --image=minio/mc:latest --env=AK="$ACCESS_KEY" --env=SK="$SECRET_KEY" -- \
  sh -c 'mc alias set r http://rustfs.gitlab.svc.cluster.local:9000 "$AK" "$SK" && mc mb -p r/canary && mc ls r'
```

Expected: `Bucket created successfully r/canary`.

- [ ] **Step 2 [CLUSTER]: Launch a throwaway `registry:2` pointed at RustFS**

```bash
kubectl -n gitlab apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: registry-canary, namespace: gitlab, labels: { app: registry-canary } }
spec:
  replicas: 1
  selector: { matchLabels: { app: registry-canary } }
  template:
    metadata: { labels: { app: registry-canary } }
    spec:
      containers:
        - name: registry
          image: registry:2
          env:
            - { name: REGISTRY_STORAGE, value: s3 }
            - { name: REGISTRY_STORAGE_S3_REGION, value: us-east-1 }
            - { name: REGISTRY_STORAGE_S3_REGIONENDPOINT, value: "http://rustfs.gitlab.svc.cluster.local:9000" }
            - { name: REGISTRY_STORAGE_S3_BUCKET, value: canary }
            - { name: REGISTRY_STORAGE_S3_PATHSTYLE, value: "true" }
            - { name: REGISTRY_STORAGE_S3_V4AUTH, value: "true" }
            - { name: REGISTRY_STORAGE_REDIRECT_DISABLE, value: "true" }
            - { name: REGISTRY_STORAGE_S3_ACCESSKEY, valueFrom: { secretKeyRef: { name: rustfs-credentials, key: RUSTFS_ACCESS_KEY } } }
            - { name: REGISTRY_STORAGE_S3_SECRETKEY, valueFrom: { secretKeyRef: { name: rustfs-credentials, key: RUSTFS_SECRET_KEY } } }
          ports: [ { containerPort: 5000 } ]
YAML
kubectl -n gitlab rollout status deploy/registry-canary --timeout=90s
kubectl -n gitlab logs deploy/registry-canary --tail=20
```

Expected: rollout succeeds; logs show `listening on [::]:5000` with no S3 auth errors.

- [ ] **Step 3 [CLUSTER]: Push + pull a real image through it**

```bash
kubectl -n gitlab port-forward deploy/registry-canary 5000:5000 >/tmp/pf.log 2>&1 &
PF=$!; sleep 3
docker pull alpine:3.20
docker tag alpine:3.20 localhost:5000/canary/alpine:test
docker push localhost:5000/canary/alpine:test
docker rmi localhost:5000/canary/alpine:test alpine:3.20
docker pull localhost:5000/canary/alpine:test
kill $PF
```

Expected: `push` completes all layers (exercises multipart + v4auth); `pull` re-fetches successfully (exercises redirect-disable — clients stream through the registry, not the internal S3 URL). `localhost:5000` is HTTP-exempt in Docker, so no insecure-registry config is needed.

- [ ] **Step 4 [CLUSTER]: Confirm objects landed in RustFS**

```bash
kubectl -n gitlab run mc --rm -it --restart=Never --image=minio/mc:latest --env=AK="$ACCESS_KEY" --env=SK="$SECRET_KEY" -- \
  sh -c 'mc alias set r http://rustfs.gitlab.svc.cluster.local:9000 "$AK" "$SK" && mc ls --recursive r/canary | head'
```

Expected: keys under `docker/registry/v2/...`.

- [ ] **Step 5 — GATE: decide**

- **PASS** → registry-on-RustFS works. Note `redirect: disable: true` belongs in the real registry storage secret (Task 7). Proceed.
- **FAIL** (auth, multipart, or redirect error) → **STOP.** No GitLab downtime spent. Fall back per the spec (Garage re-eval, or hybrid keeping the registry on MinIO). Capture the registry logs for diagnosis.

- [ ] **Step 6 [CLUSTER]: Tear down the canary**

```bash
kubectl -n gitlab delete deploy/registry-canary
kubectl -n gitlab run mc --rm -it --restart=Never --image=minio/mc:latest --env=AK="$ACCESS_KEY" --env=SK="$SECRET_KEY" -- \
  sh -c 'mc alias set r http://rustfs.gitlab.svc.cluster.local:9000 "$AK" "$SK" && mc rb --force r/canary'
```

---

## Task 6: Create the real buckets on RustFS

- [ ] **Step 1 [CLUSTER]: Create every bucket from Task 1's authoritative list**

```bash
kubectl -n gitlab run mc --rm -it --restart=Never --image=minio/mc:latest --env=AK="$ACCESS_KEY" --env=SK="$SECRET_KEY" -- sh -c '
  mc alias set r http://rustfs.gitlab.svc.cluster.local:9000 "$AK" "$SK"
  for b in gitlab-registry gitlab-artifacts git-lfs gitlab-uploads gitlab-packages \
           gitlab-mr-diffs gitlab-terraform-state gitlab-ci-secure-files \
           gitlab-dependency-proxy gitlab-backups tmp; do
    mc mb -p "r/$b"
  done
  mc ls r'
```

Expected: each `Bucket created successfully`. **Replace the bucket list with Task 1's exact output** (especially `tmp` vs `gitlab-tmp`).

---

## Task 7: Provision the three GitLab S3 secrets (lockbox)

**Files:** temp blobs under `/dev/shm` only (shredded). Lockbox entries: `gitlab-rails-storage`, `registry-storage`, `gitlab-s3cfg`.

- [ ] **Step 1 [CLUSTER]: Rails Fog connection** (`/dev/shm`, then lockbox, then shred)

```bash
cat > /dev/shm/rails.yaml <<EOF
provider: AWS
region: us-east-1
aws_access_key_id: $ACCESS_KEY
aws_secret_access_key: $SECRET_KEY
endpoint: "http://rustfs.gitlab.svc.cluster.local:9000"
path_style: true
enable_signature_v4_streaming: false
EOF
lbx set -n gitlab gitlab-rails-storage connection="$(cat /dev/shm/rails.yaml)"
shred -u /dev/shm/rails.yaml
```

- [ ] **Step 2 [CLUSTER]: Registry Distribution driver** (includes the redirect-disable proven in Task 5)

```bash
cat > /dev/shm/registry.yaml <<EOF
s3:
  bucket: gitlab-registry
  accesskey: $ACCESS_KEY
  secretkey: $SECRET_KEY
  region: us-east-1
  regionendpoint: "http://rustfs.gitlab.svc.cluster.local:9000"
  pathstyle: true
  v4auth: true
redirect:
  disable: true
EOF
lbx set -n gitlab registry-storage config="$(cat /dev/shm/registry.yaml)"
shred -u /dev/shm/registry.yaml
```

- [ ] **Step 3 [CLUSTER]: Toolbox s3cmd config**

```bash
cat > /dev/shm/s3cfg.ini <<EOF
[default]
access_key = $ACCESS_KEY
secret_key = $SECRET_KEY
bucket_location = us-east-1
host_base = rustfs.gitlab.svc.cluster.local:9000
host_bucket = rustfs.gitlab.svc.cluster.local:9000
use_https = False
signature_v2 = False
multipart_chunk_size_mb = 128
EOF
lbx set -n gitlab gitlab-s3cfg config="$(cat /dev/shm/s3cfg.ini)"
shred -u /dev/shm/s3cfg.ini
```

- [ ] **Step 4 [CLUSTER]: Verify all three mirrored (names/keys only — gate)**

```bash
for s in gitlab-rails-storage registry-storage gitlab-s3cfg; do
  echo "== $s =="; kubectl -n gitlab get secret "$s" -o jsonpath='{.data}' | tr ',' '\n' | sed 's/:.*//'
done
```

Expected: `gitlab-rails-storage`→`connection`, `registry-storage`→`config`, `gitlab-s3cfg`→`config`. **Never print values.**

- [ ] **Step 5: Confirm `/dev/shm` is clean**

```bash
ls -la /dev/shm/ | grep -E 'rails|registry|s3cfg' || echo "clean"
```

Expected: `clean`.

---

## Task 8: Bulk data mirror (GitLab still live)

- [ ] **Step 1 [CLUSTER]: Mirror every bucket MinIO→RustFS via an in-cluster Job** (creds from secrets, never the shell)

```bash
kubectl -n gitlab apply -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata: { name: s3-mirror, namespace: gitlab }
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: minio/mc:latest
          env:
            - { name: SRC_AK, valueFrom: { secretKeyRef: { name: gitlab-minio-secret, key: accesskey } } }
            - { name: SRC_SK, valueFrom: { secretKeyRef: { name: gitlab-minio-secret, key: secretkey } } }
            - { name: DST_AK, valueFrom: { secretKeyRef: { name: rustfs-credentials, key: RUSTFS_ACCESS_KEY } } }
            - { name: DST_SK, valueFrom: { secretKeyRef: { name: rustfs-credentials, key: RUSTFS_SECRET_KEY } } }
          command: ["sh","-c"]
          args:
            - |
              set -e
              mc alias set src http://gitlab-minio-svc.gitlab.svc.cluster.local:9000 "$SRC_AK" "$SRC_SK"
              mc alias set dst http://rustfs.gitlab.svc.cluster.local:9000 "$DST_AK" "$DST_SK"
              for b in gitlab-registry gitlab-artifacts git-lfs gitlab-uploads gitlab-packages \
                       gitlab-mr-diffs gitlab-terraform-state gitlab-ci-secure-files \
                       gitlab-dependency-proxy gitlab-backups tmp; do
                echo "== mirror $b =="; mc mirror --overwrite "src/$b" "dst/$b" || true
              done
              echo DONE
YAML
kubectl -n gitlab wait --for=condition=complete job/s3-mirror --timeout=3600s
kubectl -n gitlab logs job/s3-mirror --tail=40
```

Expected: per-bucket mirror output ending `DONE`. Adjust the bucket list + the source secret name/keys to Task 1/Task 3 findings. Confirm the MinIO service name with `kubectl -n gitlab get svc | grep minio` (commonly `gitlab-minio-svc`).

- [ ] **Step 2 [CLUSTER]: Spot-check counts match**

```bash
kubectl -n gitlab delete job/s3-mirror
```

Leave a note of source vs dest object counts for the registry bucket (largest) before proceeding.

---

## Task 9: Cutover (maintenance window)

- [ ] **Step 1 [CLUSTER]: Suspend Flux so it won't fight the quiesce**

```bash
flux suspend helmrelease gitlab -n gitlab
```

- [ ] **Step 2 [CLUSTER]: Quiesce writers** (discover names first; delete HPAs so they don't re-scale)

```bash
kubectl -n gitlab get deploy,hpa,cronjob | grep -E 'webservice|sidekiq|registry|backup'
# delete the HPAs for webservice/sidekiq (and registry if present), then scale to 0:
kubectl -n gitlab delete hpa -l app=webservice -l app=sidekiq 2>/dev/null || true
kubectl -n gitlab scale deploy -l 'app in (webservice,sidekiq,registry)' --replicas=0
# pause the backup cronjob:
kubectl -n gitlab patch cronjob -l app=toolbox -p '{"spec":{"suspend":true}}' 2>/dev/null || true
kubectl -n gitlab get pods | grep -E 'webservice|sidekiq|registry'
```

Expected: those pods terminating/gone. Gitaly and Postgres stay up (no S3 dependency). HPAs are re-created from the chart on resume (Step 5).

- [ ] **Step 3 [CLUSTER]: Final delta mirror** (re-run Task 8's Job, then delete it)

Re-apply the `s3-mirror` Job, `wait --for=condition=complete`, check logs, delete. With writers stopped this captures the last objects.

- [ ] **Step 4 [GIT]: Flip the HelmRelease to external object storage**

Modify `apps/gitlab/helmrelease.yaml`:

(a) Under `spec.values.global` add:

```yaml
      minio:
        enabled: false
      registry:
        bucket: gitlab-registry
```

(b) Under `spec.values.global.appConfig` (sibling of `omniauth`/`usagePing`) add:

```yaml
        object_store:
          enabled: true
          proxy_download: true
          connection:
            secret: gitlab-rails-storage
            key: connection
        artifacts: { bucket: gitlab-artifacts }
        lfs: { bucket: git-lfs }
        uploads: { bucket: gitlab-uploads }
        packages: { bucket: gitlab-packages }
        terraformState: { bucket: gitlab-terraform-state }
        ciSecureFiles: { bucket: gitlab-ci-secure-files }
        backups:
          bucket: gitlab-backups
          tmpBucket: tmp
```

(c) Under `spec.values` top level (sibling of `gitlab:`) add:

```yaml
    registry:
      storage:
        secret: registry-storage
        key: config
```

(d) Under `spec.values.gitlab` add:

```yaml
      toolbox:
        backups:
          objectStorage:
            backend: s3
            config:
              secret: gitlab-s3cfg
              key: config
```

- [ ] **Step 5 [GIT]: Validate + commit + push**

```bash
kustomize build apps/gitlab >/dev/null && echo OK
git add apps/gitlab/helmrelease.yaml
git commit -m "feat(gitlab): cut object storage over to internal RustFS S3"
git push
```

Expected: `OK`; pre-commit passes (still no secret values — only names).

- [ ] **Step 6 [CLUSTER]: Resume Flux & apply**

```bash
flux resume helmrelease gitlab -n gitlab
flux reconcile helmrelease gitlab -n gitlab --with-source
kubectl -n gitlab rollout status deploy -l 'app in (webservice,registry)' --timeout=600s
```

Expected: helm upgrade re-renders without bundled MinIO, recreates HPAs, and brings webservice/sidekiq/registry back up pointed at RustFS. Tolerate a transient `502` while it boots.

---

## Task 10: Verify the cutover (gate before any cleanup)

- [ ] **Step 1 [CLUSTER]: Functional checks**

```bash
docker pull registry.cherkaoui.ch/<some/existing/image>:<tag>     # existing layers served from RustFS
# push a throwaway tag to confirm writes:
docker tag alpine:3.20 registry.cherkaoui.ch/<your-namespace>/canary:test && docker push registry.cherkaoui.ch/<your-namespace>/canary:test
```

- [ ] **Step 2 [CLUSTER]: Rails object storage checks**

- Download a CI artifact from a past job (web UI or API).
- `git lfs fetch` an LFS object from a repo that uses LFS.
- Confirm an existing upload/avatar renders.

- [ ] **Step 3 [CLUSTER]: Backup check**

```bash
kubectl -n gitlab exec deploy/gitlab-toolbox -- backup-utility --skip db,repositories 2>&1 | tail -20
```

Expected: completes and writes a tarball into the `gitlab-backups` bucket on RustFS.

- [ ] **Step 4 [CLUSTER]: Log scan**

```bash
kubectl -n gitlab logs deploy/gitlab-webservice-default -c webservice --tail=100 | grep -iE 'objectstorage|s3|minio|error' || echo clean
kubectl -n gitlab logs deploy/gitlab-registry --tail=100 | grep -iE 'error|s3' || echo clean
```

Expected: no object-storage errors. **This is the rollback gate** — if anything fails, go to Rollback.

---

## Task 11: Cleanup (only after Task 10 is fully green)

- [ ] **Step 1 [GIT]: Remove bundled-MinIO remnants**

- Delete `apps/gitlab/ingressroute-minio.yaml`.
- Remove its line from `apps/gitlab/kustomization.yaml`.
- Remove the now-inert top-level `minio:` persistence block from `helmrelease.yaml` (`global.minio.enabled: false` already disables the subchart).

```bash
git rm apps/gitlab/ingressroute-minio.yaml
# edit kustomization.yaml + helmrelease.yaml
kustomize build apps/gitlab >/dev/null && echo OK
git add -A apps/gitlab/
git commit -m "chore(gitlab): retire bundled MinIO ingress + values post-migration"
git push
flux reconcile helmrelease gitlab -n gitlab --with-source
```

- [ ] **Step 2 [CLUSTER]: Reclaim the old MinIO PVC** (after a safety retention, e.g. 1 week)

```bash
kubectl -n gitlab get pvc | grep -i minio        # confirm which PVC
kubectl -n gitlab delete pvc <gitlab-minio-pvc>   # frees the ZFS dataset
```

Keep until you're certain; this is the last rollback anchor.

- [ ] **Step 3: Close out**

Update the spec's §13 follow-ups (track `s3` → `s3_v2` driver before GitLab 19; RustFS GA bump in July 2026).

---

## Rollback (any time before Task 11)

1. `flux suspend helmrelease gitlab -n gitlab` (if not already).
2. `git revert <cutover-commit-sha>` → push.
3. `flux resume helmrelease gitlab -n gitlab && flux reconcile helmrelease gitlab -n gitlab --with-source`.
4. Flux restores bundled MinIO; the old MinIO PVC was never deleted, so all data is intact.
5. The RustFS Deployment can stay (inert) for a later retry, or be removed.

The registry canary (Task 5) ensures the highest-risk failure mode is caught **before** Task 9, with zero GitLab downtime.

---

## Self-review (against the spec)

**Spec coverage:** RustFS deploy (§5 → Tasks 3–4); internal-only/no-ingress (§5.3 → Task 3); bucket map + preflight-as-truth (§6 → Tasks 1, 6); three-secret rewiring with exact keys (§7.1 → Task 7); HelmRelease values incl. `proxy_download` + registry redirect (§7.2–7.3 → Tasks 5, 9); lockbox + `/dev/shm` + shred (§7.4 → Tasks 2, 7); validate-first canary (§8 → Task 5, hard gate); migration/cutover runbook with suspend-based quiesce (§9 → Tasks 8–9); rollback (§10 → Rollback section); verification checklist (§11 → Task 10); preflight (§12 → Task 1); follow-ups (§13 → Task 11). All covered.

**Open items resolved:** registry redirect mechanism → `REGISTRY_STORAGE_REDIRECT_DISABLE` proven in Task 5, `redirect: disable: true` in Task 7's secret; `tmp` bucket name → Task 1 authoritative; PVC size → Task 1 (expandable `tank` as backstop).

**Placeholder scan:** The only `$ACCESS_KEY`/`$SECRET_KEY` tokens are runtime shell vars generated in Task 2 (Step 1) — deliberately externalized to lockbox, never written to Git. `<some/existing/image>` / `<your-namespace>` in Task 10 are operator-specific runtime values, not plan gaps. No `TODO`/`TBD`.

**Consistency:** Endpoint `http://rustfs.gitlab.svc.cluster.local:9000`, service name `rustfs`, secret names (`rustfs-credentials`, `gitlab-rails-storage`, `registry-storage`, `gitlab-s3cfg`), and bucket names are identical across Tasks 3, 5, 7, 8, 9. Quiesce (Task 9) and resume (Task 9 Step 6) are symmetric (HPAs deleted → recreated by chart).
