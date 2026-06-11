# GitLab Advanced Search via Elasticsearch — Design

- **Date:** 2026-06-11
- **Status:** Implemented & verified live 2026-06-11 — ES 9.4.1 deployed (commit `4973697`); Advanced Search enabled via API; 24/24 projects indexed; search confirmed across blobs/commits/MRs/projects/users. Deviation from plan: enablement done via `glab` API (not toolbox rake) because the toolbox can't see the Ultimate license — see memory `project_gitlab_advanced_search`.
- **Scope:** Advanced Search only. Advanced SAST is explicitly out of scope — the user
  configures it themselves; it is a `.gitlab-ci.yml` variable
  (`GITLAB_ADVANCED_SAST_ENABLED: "true"`) + the SAST template, with **no cluster
  component and no Elasticsearch dependency**. The two features were conflated in the
  original request.

## Goal

Stand up an Elasticsearch index and enable GitLab **Advanced Search** so that search
across issues, MRs, comments, code, and commits is served by Elasticsearch on the
self-managed GitLab 19.0.2 instance.

## Context

- GitLab **19.0.2**, edition `ee`, **Ultimate license active (confirmed)** → Advanced
  Search (a Premium+ feature) is available.
- Cluster: k0s bare-metal, Flux v2 GitOps, Cilium CNI, lockbox for `Opaque` secrets.
- GitLab's data services are already hand-rolled as **single-node Deployments**:
  `gitlab-valkey` (Redis), `rustfs` (S3), plus CNPG for Postgres. Elasticsearch follows
  the same convention — there is a strong house pattern (Recreate strategy, `fsGroup`,
  password-from-secret env, separate RWO PVC) to mirror.

## Decisions

| Topic | Choice | Rationale |
|---|---|---|
| Search backend | **Elasticsearch** (not OpenSearch) | User choice; GitLab.com-blessed path |
| Deployment method | **Hand-rolled single Deployment** (NOT the ECK operator) | No always-on operator RAM (~150–250Mi); mirrors `gitlab-valkey`/`rustfs`; plaintext removes ECK's cert-lifecycle value; user controls the password |
| ES major version | **9.x** (8.x fallback) | GitLab 19 docs recommend 9.x for forward compat; 7.x removed in 19.1; greenfield means no migration cost to starting on 9 |
| Transport security | **Plaintext HTTP + basic auth** (`elastic` user) | User choice; traffic stays in-cluster (same namespace, Cilium) |
| Heap / memory | `-Xms512m -Xmx2g`, G1 periodic idle-uncommit, `memory_lock` off; **no k8s requests/limits** | Hand RAM back to the OS when idle; matches the cluster-wide no-limits convention |
| Storage | **20Gi**, `fast`, RWO | Homelab index is only a few GB; matches Valkey's storage class |
| Secret | lockbox `gitlab-elasticsearch` / `ELASTIC_PASSWORD` | House convention for `Opaque` app secrets |
| Search enablement | **Runtime** via toolbox `gitlab-rails` + `gitlab-rake` | Advanced Search settings live in GitLab's DB, not in Helm/Flux values |

## Part A — Flux-managed manifests (committed → reconciled by Flux)

Three new files in `apps/gitlab/`, registered in `apps/gitlab/kustomization.yaml`. **No
`infrastructure/` changes, no new HelmRepository, no GitLab HelmRelease changes.**

### `pvc-elasticsearch.yaml`
- `PersistentVolumeClaim` `elasticsearch-data`, ns `gitlab`, RWO, `storageClassName: fast`, 20Gi.

### `deploy-elasticsearch.yaml`
- `Deployment` `gitlab-elasticsearch`, ns `gitlab`, `replicas: 1`, `strategy.type: Recreate`.
- `securityContext`: `runAsUser/runAsGroup/fsGroup: 1000`.
- Image: `docker.elastic.co/elasticsearch/elasticsearch:9.x.y` (exact tag pinned at
  implementation via `crane ls`, verified GitLab-19 supported).
- Env (ES settings via dotted env-var names + JVM opts):
  - `discovery.type=single-node`
  - `xpack.security.enabled=true`
  - `xpack.security.http.ssl.enabled=false`
  - `xpack.security.transport.ssl.enabled=false`
  - `node.store.allow_mmap=false`  (avoids a `vm.max_map_count` sysctl tweak on the nodes)
  - `bootstrap.memory_lock=false`  (don't pin pages — let the kernel reclaim)
  - `cluster.name=gitlab-search`
  - `ELASTIC_PASSWORD` ← `secretKeyRef: gitlab-elasticsearch/ELASTIC_PASSWORD`
  - `ES_JAVA_OPTS=-Xms512m -Xmx2g -XX:+UseG1GC -XX:G1PeriodicGCInterval=60000 -XX:-G1PeriodicGCInvokesConcurrent`
- Port `9200`.
- `startupProbe` (tcpSocket 9200, generous failureThreshold — ES is slow to boot) +
  `readinessProbe`/`livenessProbe` tcpSocket 9200 (matches Valkey; basic-auth makes an
  httpGet health probe awkward without embedding creds).
- Volume mount `elasticsearch-data` → `/usr/share/elasticsearch/data`.

### `svc-elasticsearch.yaml`
- `Service` `gitlab-elasticsearch` (ClusterIP), `9200 → 9200`.
- Endpoint for GitLab: `http://gitlab-elasticsearch.gitlab.svc:9200`.

### Secret (provisioned out-of-band, NOT committed)
```bash
lbx set -n gitlab gitlab-elasticsearch ELASTIC_PASSWORD=<strong-random>
```
The lockbox controller mirrors this into an `Opaque` Secret on its next sync.

## Part B — Runtime enablement (live cluster, NOT committed)

After the ES pod is Ready and `GET /_cluster/health` returns green/yellow:

1. **Pre-flight:** ES reachable; license active
   (`gitlab-rails runner "puts License.current&.plan"` → `ultimate`).
2. **Settings** (toolbox pod, password injected from the mirrored secret, never echoed):
   ```
   ApplicationSetting.current.update!(
     elasticsearch_url: 'http://gitlab-elasticsearch.gitlab.svc:9200',
     elasticsearch_username: 'elastic',
     elasticsearch_password: <pw>,
     elasticsearch_indexing: true)
   ```
3. **Full initial index:** `gitlab-rake gitlab:elastic:index` (creates the index with
   GitLab's mappings and queues repos/wikis/DB records through Sidekiq).
4. **Wait** for the index to drain (Sidekiq `elastic` queues empty; `gitlab:elastic:info`
   / `_cat/indices` show populated GitLab indices).
5. **Enable search:** `ApplicationSetting.current.update!(elasticsearch_search: true)`.
6. **Verify:** top-bar search returns hits; Admin → Search shows green; `_cat/indices`
   populated.

Exact rake task names / setting keys are re-verified against GitLab 19.0.2 before running
(version-sensitive).

## Out of scope / follow-ups

- **Advanced SAST** — user-owned (pure CI config).
- ES `ServiceMonitor` / Prometheus exporter — optional later (cluster has kube-prometheus-stack).
- A scoped ES user instead of the `elastic` superuser — optional hardening.
- Multi-node / HA — not needed for a homelab.

## Risks

- **ES 9.x quirk** with the GitLab 19.0.2 indexer → fallback to latest ES 8.x (one-line
  image-tag change).
- **`fsGroup` data-dir permissions** on `fast` (ZFS-backed) → if ES can't write `/data`,
  add a `chown -R 1000:1000` initContainer.
- **`ELASTIC_PASSWORD`** is only applied on first boot (empty data dir); thereafter it
  lives in the security index. Wiping the PVC resets it to the env value.
- **No k8s memory limit** → footprint is bounded by `-Xmx2g` + modest off-heap
  (mmap disabled); acceptable and intentional.
- **Part B touches the live instance** (toolbox `kubectl exec`) and requires Part A to be
  reconciled first; it is not reversible-by-git (settings live in the DB).
