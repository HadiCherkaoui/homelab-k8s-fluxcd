# GitLab Advanced Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a single-node Elasticsearch index in the `gitlab` namespace and enable GitLab Advanced Search so all search is served by Elasticsearch.

**Architecture:** Hand-rolled single-node ES `Deployment` (no ECK operator) mirroring the existing `gitlab-valkey`/`rustfs` pattern — Recreate strategy, `fsGroup` 1000, password-from-lockbox env, separate RWO PVC. Plaintext HTTP + basic auth, in-cluster only. JVM heap floats 512Mi→2Gi and is uncommitted to the OS when idle; no k8s resource requests/limits. Advanced Search itself is enabled at runtime against the live instance (settings live in GitLab's DB, not Helm/Flux).

**Tech Stack:** Elasticsearch 9.x, Flux v2, Kustomize, lockbox (`lbx`), GitLab 19.0.2 toolbox (`gitlab-rails`/`gitlab-rake`), `crane`.

**Scope note:** Advanced SAST is NOT in this plan — the user configures it separately (a `.gitlab-ci.yml` variable; no cluster component, no Elasticsearch).

**Two impactful checkpoints requiring explicit user go-ahead:**
- **Task 4 (push)** — triggers Flux to deploy ES to the live cluster.
- **Task 5 (Part B)** — mutates the live GitLab instance (not reversible by git).

---

## Task 0: Preflight — tooling, version pin, secret

**Files:** none (environment + lockbox)

- [ ] **Step 1: Confirm tools + cluster access**

Run:
```bash
for t in kubectl flux kustomize crane lbx; do command -v "$t" >/dev/null && echo "ok $t" || echo "MISSING $t"; done
kubectl -n gitlab get deploy gitlab-toolbox -o name
```
Expected: `ok` for all five; `deployment.apps/gitlab-toolbox` printed. If `gitlab-toolbox` differs, note the real name and substitute it everywhere below.

- [ ] **Step 2: Discover the latest Elasticsearch 9.x tag**

Run:
```bash
crane ls docker.elastic.co/elasticsearch/elasticsearch | grep -E '^9\.[0-9]+\.[0-9]+$' | sort -V | tail -5
```
Expected: a list ending in the newest `9.x.y`. Pick the highest stable (non-`-rc`/`-SNAPSHOT`) tag — call it `<ES_TAG>`.

- [ ] **Step 3: Cross-check the tag is supported by GitLab 19**

Confirm `<ES_TAG>` is within GitLab 19's supported range (docs: <https://docs.gitlab.com/integration/advanced_search/elasticsearch/>). GitLab 19 supports ES 8.x and 9.x (7.x removed in 19.1). If 9.x is not listed as supported for 19.0.2 specifically, fall back to the latest `8.x.y` tag and use it as `<ES_TAG>` (config below is identical for 8 and 9).

- [ ] **Step 4: Provision the lockbox secret**

Run (generates a 32-char random password, sets it, never prints it):
```bash
ES_PW="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
lbx set -n gitlab gitlab-elasticsearch ELASTIC_PASSWORD="$ES_PW"
unset ES_PW
```
Expected: `lbx` confirms the entry is set.

- [ ] **Step 5: Verify the controller mirrored it (wait up to ~90s)**

Run:
```bash
kubectl -n gitlab get secret gitlab-elasticsearch -o jsonpath='{.data.ELASTIC_PASSWORD}' | wc -c
```
Expected: a non-zero number (base64 length). If `NotFound`, wait ~60s and retry; if still missing, `kubectl -n lockbox-system rollout restart deploy/lockbox-k8s-controller` then retry.

---

## Task 1: Create the PVC

**Files:**
- Create: `apps/gitlab/pvc-elasticsearch.yaml`

- [ ] **Step 1: Baseline — confirm it does not exist yet**

Run: `kubectl -n gitlab get pvc elasticsearch-data`
Expected: `Error ... NotFound`.

- [ ] **Step 2: Write the PVC**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: elasticsearch-data
  namespace: gitlab
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: fast
  resources:
    requests:
      storage: 20Gi
```

- [ ] **Step 3: Validate YAML**

Run: `kubectl apply --dry-run=client -f apps/gitlab/pvc-elasticsearch.yaml`
Expected: `persistentvolumeclaim/elasticsearch-data created (dry run)`.

---

## Task 2: Create the Deployment

**Files:**
- Create: `apps/gitlab/deploy-elasticsearch.yaml`

- [ ] **Step 1: Write the Deployment** (replace `<ES_TAG>` with the pin from Task 0)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitlab-elasticsearch
  namespace: gitlab
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/part-of: gitlab
spec:
  replicas: 1
  strategy:
    type: Recreate          # single RWO volume
  selector:
    matchLabels:
      app.kubernetes.io/name: elasticsearch
  template:
    metadata:
      labels:
        app.kubernetes.io/name: elasticsearch
        app.kubernetes.io/part-of: gitlab
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: elasticsearch
          image: docker.elastic.co/elasticsearch/elasticsearch:<ES_TAG>
          env:
            - name: discovery.type
              value: single-node
            - name: cluster.name
              value: gitlab-search
            - name: xpack.security.enabled
              value: "true"
            - name: xpack.security.http.ssl.enabled
              value: "false"
            - name: xpack.security.transport.ssl.enabled
              value: "false"
            - name: node.store.allow_mmap
              value: "false"
            - name: bootstrap.memory_lock
              value: "false"
            - name: ES_JAVA_OPTS
              value: "-Xms512m -Xmx2g -XX:+UseG1GC -XX:G1PeriodicGCInterval=60000 -XX:-G1PeriodicGCInvokesConcurrent"
            - name: ELASTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: gitlab-elasticsearch
                  key: ELASTIC_PASSWORD
          ports:
            - name: http
              containerPort: 9200
          startupProbe:
            tcpSocket:
              port: 9200
            failureThreshold: 30
            periodSeconds: 5
          readinessProbe:
            tcpSocket:
              port: 9200
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 9200
            initialDelaySeconds: 30
            periodSeconds: 20
          volumeMounts:
            - name: data
              mountPath: /usr/share/elasticsearch/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: elasticsearch-data
```

- [ ] **Step 2: Validate YAML**

Run: `kubectl apply --dry-run=client -f apps/gitlab/deploy-elasticsearch.yaml`
Expected: `deployment.apps/gitlab-elasticsearch created (dry run)`. (No `resources:` block — intentional, per the no-limits convention.)

---

## Task 3: Create the Service + register in kustomization

**Files:**
- Create: `apps/gitlab/svc-elasticsearch.yaml`
- Modify: `apps/gitlab/kustomization.yaml`

- [ ] **Step 1: Write the Service**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gitlab-elasticsearch
  namespace: gitlab
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/part-of: gitlab
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: elasticsearch
  ports:
    - name: http
      port: 9200
      targetPort: 9200
```

- [ ] **Step 2: Register the three resources in `apps/gitlab/kustomization.yaml`**

Insert the ES trio immediately after the `- svc-valkey.yaml` line (keeps data services grouped, storage-before-deploy ordering):

```yaml
  - svc-valkey.yaml
  - pvc-elasticsearch.yaml
  - deploy-elasticsearch.yaml
  - svc-elasticsearch.yaml
  - cnpg-cluster.yaml
```

- [ ] **Step 3: Validate the whole kustomization builds and applies cleanly (server dry-run)**

Run:
```bash
kustomize build apps/gitlab >/dev/null && echo "build ok"
kustomize build apps/gitlab | kubectl apply --dry-run=server -f -
```
Expected: `build ok`, then every resource reports `... (server dry run)` with no errors (server dry-run validates against live CRDs/schemas).

---

## Task 4: Commit + deploy (CHECKPOINT — pushing deploys to the live cluster)

**Files:** none (git + Flux)

- [ ] **Step 1: Stage and commit**

```bash
git add apps/gitlab/pvc-elasticsearch.yaml apps/gitlab/deploy-elasticsearch.yaml \
        apps/gitlab/svc-elasticsearch.yaml apps/gitlab/kustomization.yaml
git commit -m "feat(gitlab): single-node Elasticsearch for Advanced Search

Hand-rolled ES Deployment (no ECK), plaintext HTTP + basic auth, idle-
reclaiming JVM heap, no resource limits. Mirrors the valkey/rustfs pattern.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 2: GET EXPLICIT USER GO-AHEAD, then push**

Pause and confirm with the user. Then: `git push`.

- [ ] **Step 3: Reconcile Flux**

Run: `flux reconcile kustomization apps --with-source`
Expected: reconciliation succeeds; revision advances to the new commit.

- [ ] **Step 4: Wait for the pod to roll out**

Run: `kubectl -n gitlab rollout status deploy/gitlab-elasticsearch --timeout=300s`
Expected: `deployment "gitlab-elasticsearch" successfully rolled out`.
If it CrashLoops on a data-dir permission error (`AccessDeniedException ... /data`), add a chown initContainer (see Risks in the spec) and re-commit.

- [ ] **Step 5: Verify cluster health over the in-cluster Service**

Run (uses the toolbox, which has curl + the same DNS path GitLab uses):
```bash
PW="$(kubectl -n gitlab get secret gitlab-elasticsearch -o jsonpath='{.data.ELASTIC_PASSWORD}' | base64 -d)"
printf '%s' "$PW" | kubectl -n gitlab exec -i deploy/gitlab-toolbox -- sh -c \
  'read PW; curl -s -u "elastic:$PW" http://gitlab-elasticsearch.gitlab.svc:9200/_cluster/health'
unset PW
```
Expected: JSON with `"status":"green"` (or `"yellow"` — fine for a single node) and `"number_of_nodes":1`.

---

## Task 5: Part B — enable Advanced Search (CHECKPOINT — mutates live GitLab)

**Files:** none (runtime against the live instance)

> Re-verify the exact rake task names / setting keys against this instance first:
> `kubectl -n gitlab exec deploy/gitlab-toolbox -- gitlab-rake -T | grep elastic`

- [ ] **Step 1: Preflight — license is Ultimate**

Run:
```bash
kubectl -n gitlab exec deploy/gitlab-toolbox -- gitlab-rails runner 'puts(License.current&.plan || "NO LICENSE")'
```
Expected: `ultimate`. If not, STOP — Advanced Search won't function.

- [ ] **Step 2: Point GitLab at ES + enable indexing** (password via STDIN, never in argv)

```bash
PW="$(kubectl -n gitlab get secret gitlab-elasticsearch -o jsonpath='{.data.ELASTIC_PASSWORD}' | base64 -d)"
printf '%s' "$PW" | kubectl -n gitlab exec -i deploy/gitlab-toolbox -- gitlab-rails runner '
  pw = STDIN.read
  s = ApplicationSetting.current
  s.update!(
    elasticsearch_url: "http://gitlab-elasticsearch.gitlab.svc:9200",
    elasticsearch_username: "elastic",
    elasticsearch_password: pw,
    elasticsearch_indexing: true,
    elasticsearch_search: false)
  puts "indexing=#{s.elasticsearch_indexing} search=#{s.elasticsearch_search} url=#{s.elasticsearch_url}"'
unset PW
```
Expected: `indexing=true search=false url=http://gitlab-elasticsearch.gitlab.svc:9200`.

- [ ] **Step 3: Run the full initial index**

```bash
kubectl -n gitlab exec deploy/gitlab-toolbox -- gitlab-rake gitlab:elastic:index
```
Expected: task creates the index and queues projects/wikis/DB records to Sidekiq without error.

- [ ] **Step 4: Wait for indexing to drain**

Run (repeat until pending counts reach 0):
```bash
kubectl -n gitlab exec deploy/gitlab-toolbox -- gitlab-rake gitlab:elastic:info
```
Expected: pending migrations/specs settle and document counts are non-zero. Cross-check from ES:
```bash
PW="$(kubectl -n gitlab get secret gitlab-elasticsearch -o jsonpath='{.data.ELASTIC_PASSWORD}' | base64 -d)"
printf '%s' "$PW" | kubectl -n gitlab exec -i deploy/gitlab-toolbox -- sh -c \
  'read PW; curl -s -u "elastic:$PW" "http://gitlab-elasticsearch.gitlab.svc:9200/_cat/indices?v"'
unset PW
```
Expected: `gitlab-production*` indices listed with non-zero `docs.count`.

- [ ] **Step 5: Enable search**

```bash
kubectl -n gitlab exec deploy/gitlab-toolbox -- gitlab-rails runner '
  ApplicationSetting.current.update!(elasticsearch_search: true)
  puts "search=#{ApplicationSetting.current.elasticsearch_search}"'
```
Expected: `search=true`.

- [ ] **Step 6: Verify end-to-end**

In the GitLab UI: **Admin → Settings → Search** shows Advanced Search green; the global search bar returns results (toggle "Advanced search" scope). Optionally confirm a code/issue search returns hits.

---

## Task 6: Record outcome

- [ ] **Step 1: Update auto-memory**

Append a one-line pointer in `MEMORY.md` and add a `project_gitlab_advanced_search.md` memory noting: ES is hand-rolled (not ECK), plaintext+auth, idle-reclaiming heap, enablement is a runtime DB setting (re-run Task 5 Step 2 if the lockbox password is ever rotated or the PVC wiped).

- [ ] **Step 2: Mark the spec/plan done**

Note completion in the spec's Status line if desired.

---

## Self-Review (completed by author)

- **Spec coverage:** PVC/Deploy/Svc/kustomization (Part A) → Tasks 1–4; lockbox secret → Task 0; runtime enablement (Part B) → Task 5; SAST out of scope → stated. All spec sections covered.
- **Placeholders:** `<ES_TAG>` is a deliberate, resolved-in-Task-0 pin with a discovery command (not a TODO). No other placeholders.
- **Consistency:** Secret `gitlab-elasticsearch`/`ELASTIC_PASSWORD`, Service DNS `gitlab-elasticsearch.gitlab.svc:9200`, and label `app.kubernetes.io/name: elasticsearch` are identical across Tasks 0–5.
