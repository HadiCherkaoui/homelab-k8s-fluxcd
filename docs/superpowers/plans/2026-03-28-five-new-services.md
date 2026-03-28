# Five New Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ntfy, Uptime Kuma, Headscale, Changedetection.io, and Wallos to the FluxCD homelab cluster.

**Architecture:** Each service gets its own namespace, HelmRelease, and Traefik IngressRoute following existing repo conventions. Headscale additionally gets a LoadBalancer service for DERP/STUN UDP and control plane TCP. Three new HelmRepositories are added to the shared repositories file.

**Tech Stack:** Flux CD v2, Helm, Traefik IngressRoute, Kustomize, Cilium L2 (LoadBalancer)

---

## File Map

### Modified files
- `infrastructure/helmrepositories/repositories.yaml` — append 3 new HelmRepository entries
- `apps/kustomization.yaml` — append 5 new app directory references

### New files (4 per service = 20 total)
- `apps/ntfy/{namespace,helmrelease,ingressroute,kustomization}.yaml`
- `apps/uptime-kuma/{namespace,helmrelease,ingressroute,kustomization}.yaml`
- `apps/headscale/{namespace,helmrelease,ingressroute,kustomization}.yaml`
- `apps/changedetection/{namespace,helmrelease,ingressroute,kustomization}.yaml`
- `apps/wallos/{namespace,helmrelease,ingressroute,kustomization}.yaml`

---

### Task 1: Add HelmRepositories

**Files:**
- Modify: `infrastructure/helmrepositories/repositories.yaml`

- [ ] **Step 1: Append 3 new HelmRepository entries to the end of repositories.yaml**

Append after the last entry (nextcloud):

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: uptime-kuma
  namespace: flux-system
spec:
  interval: 1h
  url: https://dirsigler.github.io/uptime-kuma-helm
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: wrenix
  namespace: flux-system
spec:
  type: oci
  interval: 1h
  url: oci://codeberg.org/wrenix/helm-charts
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: alekc
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.alekc.dev
```

- [ ] **Step 2: Validate YAML**

Run: `yq eval '.' infrastructure/helmrepositories/repositories.yaml > /dev/null && echo "OK"`
Expected: `OK`

- [ ] **Step 3: Validate kustomize build**

Run: `kustomize build infrastructure/helmrepositories/`
Expected: All 17 HelmRepository resources printed (14 existing + 3 new)

- [ ] **Step 4: Commit**

```bash
git add infrastructure/helmrepositories/repositories.yaml
git commit -m "feat: add uptime-kuma, wrenix, and alekc HelmRepositories"
```

---

### Task 2: Create ntfy app (parallel with Tasks 3-6)

**Files:**
- Create: `apps/ntfy/namespace.yaml`
- Create: `apps/ntfy/helmrelease.yaml`
- Create: `apps/ntfy/ingressroute.yaml`
- Create: `apps/ntfy/kustomization.yaml`

- [ ] **Step 1: Create apps/ntfy/namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ntfy
  labels:
    name: ntfy
```

- [ ] **Step 2: Create apps/ntfy/helmrelease.yaml**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ntfy
  namespace: ntfy
spec:
  interval: 10m
  chart:
    spec:
      chart: ntfy
      version: "13.1.1"
      sourceRef:
        kind: HelmRepository
        name: truecharts
        namespace: flux-system
  install:
    createNamespace: false
  values:
    persistence:
      config:
        storageClass: fast
        enabled: true
        size: 1Gi
```

- [ ] **Step 3: Create apps/ntfy/ingressroute.yaml**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: ntfy
  namespace: ntfy
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`ntfy.cherkaoui.ch`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: traefik
      services:
        - name: ntfy
          port: main
  tls:
    certResolver: letsencrypt
```

- [ ] **Step 4: Create apps/ntfy/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ntfy
resources:
  - namespace.yaml
  - helmrelease.yaml
  - ingressroute.yaml
```

- [ ] **Step 5: Validate kustomize build**

Run: `kustomize build apps/ntfy/`
Expected: 3 resources (Namespace, HelmRelease, IngressRoute) printed without errors

- [ ] **Step 6: Commit**

```bash
git add apps/ntfy/
git commit -m "feat: add ntfy push notification service"
```

---

### Task 3: Create Uptime Kuma app (parallel with Tasks 2, 4-6)

**Files:**
- Create: `apps/uptime-kuma/namespace.yaml`
- Create: `apps/uptime-kuma/helmrelease.yaml`
- Create: `apps/uptime-kuma/ingressroute.yaml`
- Create: `apps/uptime-kuma/kustomization.yaml`

- [ ] **Step 1: Create apps/uptime-kuma/namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: uptime-kuma
  labels:
    name: uptime-kuma
```

- [ ] **Step 2: Create apps/uptime-kuma/helmrelease.yaml**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: uptime-kuma
  namespace: uptime-kuma
spec:
  interval: 10m
  chart:
    spec:
      chart: uptime-kuma
      version: "4.0.0"
      sourceRef:
        kind: HelmRepository
        name: uptime-kuma
        namespace: flux-system
  install:
    createNamespace: false
  values:
    volume:
      enabled: true
      size: 2Gi
      storageClassName: fast
```

- [ ] **Step 3: Create apps/uptime-kuma/ingressroute.yaml**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: uptime-kuma
  namespace: uptime-kuma
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`status.cherkaoui.ch`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: traefik
      services:
        - name: uptime-kuma
          port: 3001
  tls:
    certResolver: letsencrypt
```

- [ ] **Step 4: Create apps/uptime-kuma/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: uptime-kuma
resources:
  - namespace.yaml
  - helmrelease.yaml
  - ingressroute.yaml
```

- [ ] **Step 5: Validate kustomize build**

Run: `kustomize build apps/uptime-kuma/`
Expected: 3 resources printed without errors

- [ ] **Step 6: Commit**

```bash
git add apps/uptime-kuma/
git commit -m "feat: add Uptime Kuma monitoring at status.cherkaoui.ch"
```

---

### Task 4: Create Headscale app (parallel with Tasks 2-3, 5-6)

**Files:**
- Create: `apps/headscale/namespace.yaml`
- Create: `apps/headscale/helmrelease.yaml`
- Create: `apps/headscale/ingressroute.yaml`
- Create: `apps/headscale/kustomization.yaml`

- [ ] **Step 1: Create apps/headscale/namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: headscale
  labels:
    name: headscale
```

- [ ] **Step 2: Create apps/headscale/helmrelease.yaml**

The wrenix chart creates two Kubernetes Services:
- Main service (control plane, API, metrics, gRPC) — set to LoadBalancer
- DERP service (STUN relay on UDP 3478) — already defaults to LoadBalancer when DERP enabled

Cert-manager is disabled (Traefik handles TLS). Headscale TLS paths set empty (TLS terminated at Traefik). server_url uses the Traefik domain so clients connect with TLS.

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: headscale
  namespace: headscale
spec:
  interval: 10m
  chart:
    spec:
      chart: headscale
      version: "1.0.14"
      sourceRef:
        kind: HelmRepository
        name: wrenix
        namespace: flux-system
  install:
    createNamespace: false
  values:
    service:
      type: LoadBalancer
      port:
        http: 8080
        metrics: 9090
      derp:
        type: LoadBalancer
        port: 3478
    persistence:
      enabled: true
      storageClass: fast
      size: 1Gi
    headscale:
      certmanager:
        enabled: false
      config:
        server_url: "https://headscale.cherkaoui.ch"
        tls_cert_path: ""
        tls_key_path: ""
        database:
          type: sqlite
          sqlite:
            path: /var/lib/headscale/db.sqlite
        prefixes:
          v4: 100.64.0.0/10
          v6: fd7a:115c:a1e0::/48
          allocation: sequential
        derp:
          server:
            enabled: true
            region_id: 999
            region_code: "headscale"
            region_name: "Headscale Embedded DERP"
          urls:
            - "https://controlplane.tailscale.com/derpmap/default"
          auto_update_enabled: true
          update_frequency: 24h
        dns:
          base_domain: headscale.cherkaoui.ch
```

- [ ] **Step 3: Create apps/headscale/ingressroute.yaml**

This provides browser/API access via Traefik with TLS. Clients use this URL (server_url).

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: headscale
  namespace: headscale
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`headscale.cherkaoui.ch`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: traefik
      services:
        - name: headscale
          port: 8080
  tls:
    certResolver: letsencrypt
```

- [ ] **Step 4: Create apps/headscale/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: headscale
resources:
  - namespace.yaml
  - helmrelease.yaml
  - ingressroute.yaml
```

- [ ] **Step 5: Validate kustomize build**

Run: `kustomize build apps/headscale/`
Expected: 3 resources printed without errors

- [ ] **Step 6: Commit**

```bash
git add apps/headscale/
git commit -m "feat: add Headscale with LoadBalancer for DERP/control plane"
```

---

### Task 5: Create Changedetection.io app (parallel with Tasks 2-4, 6)

**Files:**
- Create: `apps/changedetection/namespace.yaml`
- Create: `apps/changedetection/helmrelease.yaml`
- Create: `apps/changedetection/ingressroute.yaml`
- Create: `apps/changedetection/kustomization.yaml`

- [ ] **Step 1: Create apps/changedetection/namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: changedetection
  labels:
    name: changedetection
```

- [ ] **Step 2: Create apps/changedetection/helmrelease.yaml**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: changedetection
  namespace: changedetection
spec:
  interval: 10m
  chart:
    spec:
      chart: changedetection
      version: "0.11.6"
      sourceRef:
        kind: HelmRepository
        name: alekc
        namespace: flux-system
  install:
    createNamespace: false
  values:
    persistence:
      enabled: true
      storageClass: fast
      size: 2Gi
    env:
      simple:
        BASE_URL: "https://changes.cherkaoui.ch"
```

- [ ] **Step 3: Create apps/changedetection/ingressroute.yaml**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: changedetection
  namespace: changedetection
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`changes.cherkaoui.ch`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: traefik
      services:
        - name: changedetection
          port: 5000
  tls:
    certResolver: letsencrypt
```

- [ ] **Step 4: Create apps/changedetection/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: changedetection
resources:
  - namespace.yaml
  - helmrelease.yaml
  - ingressroute.yaml
```

- [ ] **Step 5: Validate kustomize build**

Run: `kustomize build apps/changedetection/`
Expected: 3 resources printed without errors

- [ ] **Step 6: Commit**

```bash
git add apps/changedetection/
git commit -m "feat: add Changedetection.io at changes.cherkaoui.ch"
```

---

### Task 6: Create Wallos app (parallel with Tasks 2-5)

**Files:**
- Create: `apps/wallos/namespace.yaml`
- Create: `apps/wallos/helmrelease.yaml`
- Create: `apps/wallos/ingressroute.yaml`
- Create: `apps/wallos/kustomization.yaml`

- [ ] **Step 1: Create apps/wallos/namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: wallos
  labels:
    name: wallos
```

- [ ] **Step 2: Create apps/wallos/helmrelease.yaml**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: wallos
  namespace: wallos
spec:
  interval: 10m
  chart:
    spec:
      chart: wallos
      version: "10.1.0"
      sourceRef:
        kind: HelmRepository
        name: truecharts
        namespace: flux-system
  install:
    createNamespace: false
  values:
    persistence:
      config:
        storageClass: fast
        enabled: true
        size: 1Gi
```

- [ ] **Step 3: Create apps/wallos/ingressroute.yaml**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: wallos
  namespace: wallos
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`wallos.cherkaoui.ch`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: traefik
      services:
        - name: wallos
          port: main
  tls:
    certResolver: letsencrypt
```

- [ ] **Step 4: Create apps/wallos/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: wallos
resources:
  - namespace.yaml
  - helmrelease.yaml
  - ingressroute.yaml
```

- [ ] **Step 5: Validate kustomize build**

Run: `kustomize build apps/wallos/`
Expected: 3 resources printed without errors

- [ ] **Step 6: Commit**

```bash
git add apps/wallos/
git commit -m "feat: add Wallos subscription tracker"
```

---

### Task 7: Register apps and full validation

**Files:**
- Modify: `apps/kustomization.yaml`

- [ ] **Step 1: Add all 5 new app directories to apps/kustomization.yaml**

Append these entries to the `resources` list:

```yaml
  - ntfy
  - uptime-kuma
  - headscale
  - changedetection
  - wallos
```

The full file should read:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - media
  - paperless
  - websites
  - craftycontroller
  - gitlab
  - scolx
  - searxng
  - immich
  - authentik
  - matrix
  - sonarqube
  - ntfy
  - uptime-kuma
  - headscale
  - changedetection
  - wallos
```

- [ ] **Step 2: Validate full apps kustomize build**

Run: `kustomize build apps/`
Expected: All app resources printed without errors (existing + 15 new resources from 5 services)

- [ ] **Step 3: Validate full infrastructure kustomize build**

Run: `kustomize build infrastructure/`
Expected: All infrastructure resources printed without errors (including 3 new HelmRepositories)

- [ ] **Step 4: Commit**

```bash
git add apps/kustomization.yaml
git commit -m "feat: register ntfy, uptime-kuma, headscale, changedetection, wallos in apps"
```

---

## Parallelization Notes

- **Task 1** must complete first (HelmRepositories needed by HelmReleases)
- **Tasks 2-6** are fully independent and can run in parallel
- **Task 7** depends on Tasks 2-6 completing (references their directories)

## Authentik SSO Integration (future, not in scope)

- **Headscale**: Native OIDC — configure `headscale.config.oidc.issuer`, `client_id`, `client_secret` pointing at Authentik
- **Uptime Kuma**: No native OIDC — use Traefik ForwardAuth middleware with Authentik proxy provider outpost
