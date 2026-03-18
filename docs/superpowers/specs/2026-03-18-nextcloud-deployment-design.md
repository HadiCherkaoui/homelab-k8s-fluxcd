# Nextcloud Deployment Design

**Date:** 2026-03-18
**Repo:** homelab-k8s-fluxcd (Flux v2 GitOps)

---

## Overview

Add Nextcloud to the homelab Kubernetes cluster using the official `nextcloud/nextcloud` Helm chart, with:
- CNPG-managed PostgreSQL (auto-generated credentials)
- RustFS (MinIO-compatible S3) in the `nextcloud` namespace as primary object storage
- Traefik IngressRoute for external access at `cloud.cherkaoui.ch`
- Authentik OIDC SSO stubs (requires manual Authentik app registration to activate)

All resources follow the existing conventions in this repository.

---

## Architecture

```
Traefik (websecure / letsencrypt)
    └── cloud.cherkaoui.ch
            └── nextcloud (HelmRelease, nextcloud/nextcloud chart)
                    ├── postgresql subchart  ← DISABLED (use CNPG instead)
                    ├── externalDatabase.existingSecret → nextcloud-postgres-cluster-app (CNPG auto-generated)
                    ├── objectStore.s3 → rustfs-svc:9000 (RustFS, in-namespace)
                    ├── nextcloud.existingSecret → nextcloud-admin (SOPS)
                    └── extraEnv: OIDC_CLIENT_ID, OIDC_CLIENT_SECRET → nextcloud-admin (SOPS)

CNPG Cluster (nextcloud-postgres-cluster)
    └── auto-creates secret: nextcloud-postgres-cluster-app
            keys: host, user, password, dbname, uri, fqdn-uri

RustFS HelmRelease (rustfs chart, nextcloud namespace)
    └── secret: rustfs-credentials (SOPS)
    └── storageClass: tank, dataStorageSize: 500Gi
    └── service: rustfs-svc:9000 (ClusterIP, internal only)
```

---

## File Layout

### New files

```
apps/nextcloud/
├── namespace.yaml
├── kustomization.yaml
├── cnpg-cluster.yaml
├── helmrelease-rustfs.yaml
├── helmrelease-nextcloud.yaml
└── ingressroute-nextcloud.yaml

secrets/nextcloud/
├── rustfs-credentials.secret.yaml
└── nextcloud-admin.secret.yaml
```

### Modified files

```
apps/kustomization.yaml                              ← add nextcloud entry
infrastructure/helmrepositories/repositories.yaml   ← add nextcloud HelmRepository
```

---

## Resource Specifications

### namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nextcloud
  labels:
    name: nextcloud
```

### kustomization.yaml

Resources in order per repo convention (namespace → storage → secrets → configmaps → workloads → services → ingress):

```
namespace.yaml
cnpg-cluster.yaml
helmrelease-rustfs.yaml
helmrelease-nextcloud.yaml
ingressroute-nextcloud.yaml
```

Namespace: `nextcloud`

### cnpg-cluster.yaml

Follows the scolx pattern exactly:

- `name`: `nextcloud-postgres-cluster`
- `namespace`: `nextcloud`
- `instances`: 2
- `image`: `ghcr.io/cloudnative-pg/postgresql:18`
- `storageClass`: `fast`
- `size`: `10Gi`
- `enableSuperuserAccess`: `false`

CNPG auto-creates secret `nextcloud-postgres-cluster-app` with keys:
`host`, `user`, `password`, `dbname`, `uri`, `fqdn-uri`

### helmrelease-rustfs.yaml

Follows the scolx `helmrelease-rustfs.yaml` pattern exactly:

- `name`: `rustfs`, `namespace`: `nextcloud`
- Chart: `rustfs` version `0.0.85` from HelmRepository `rustfs` (already in `repositories.yaml`)
- `install.createNamespace: false`
- Standalone mode, 1 replica
- `secret.existingSecret: rustfs-credentials`
- `storageclass.name: tank`, `dataStorageSize: 500Gi`, `logStorageSize: 1Gi`
- `config.rustfs.region: eu-central-2`
- `service.type: ClusterIP`
- `ingress.enabled: false`

### helmrelease-nextcloud.yaml

- `name`: `nextcloud`, `namespace`: `nextcloud`
- Chart: `nextcloud` from HelmRepository `nextcloud`, version `9.0.3`
- `install.createNamespace: false`, `interval: 10m`

Key values:

**Admin credentials (from SOPS secret, no chart-side generation):**
```yaml
nextcloud:
  host: cloud.cherkaoui.ch
  existingSecret:
    enabled: true
    secretName: nextcloud-admin
    usernameKey: admin-username
    passwordKey: admin-password
```

**Bundled DB disabled, CNPG external DB:**
```yaml
internalDatabase:
  enabled: false
postgresql:
  enabled: false
mariadb:
  enabled: false
externalDatabase:
  enabled: true
  type: postgresql
  existingSecret:
    enabled: true
    secretName: nextcloud-postgres-cluster-app
    hostKey: host
    usernameKey: user
    passwordKey: password
    databaseKey: dbname
```

**S3 primary object storage (RustFS):**
```yaml
nextcloud:
  objectStore:
    s3:
      enabled: true
      host: rustfs-svc
      ssl: false
      port: 9000
      region: eu-central-2
      bucket: nextcloud
      usePathStyle: true
      existingSecret: rustfs-credentials
      accessKeyKey: RUSTFS_ACCESS_KEY
      secretKeyKey: RUSTFS_SECRET_KEY
```

**Persistence (for /var/www/html — app files, not user data):**
```yaml
persistence:
  enabled: true
  storageClass: tank
  size: 10Gi
```

**Ingress disabled (Traefik IngressRoute used instead):**
```yaml
ingress:
  enabled: false
```

**OIDC SSO stubs — all extraEnv merged into one block with proxy env vars above:**
```yaml
nextcloud:
  extraEnv:
    - name: NEXTCLOUD_TRUSTED_PROXIES
      value: "10.0.0.0/8"
    - name: OVERWRITEPROTOCOL
      value: "https"
    - name: OVERWRITECLIURL
      value: "https://cloud.cherkaoui.ch"
    - name: OIDC_CLIENT_ID
      valueFrom:
        secretKeyRef:
          name: nextcloud-admin
          key: OIDC_CLIENT_ID
    - name: OIDC_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: nextcloud-admin
          key: OIDC_CLIENT_SECRET
  configs:
    oidc.config.php: |-
      <?php
      $CONFIG = [
        'oidc_login_provider_url'       => 'https://authentik.cherkaoui.ch/application/o/nextcloud/',
        'oidc_login_client_id'          => getenv('OIDC_CLIENT_ID'),
        'oidc_login_client_secret'      => getenv('OIDC_CLIENT_SECRET'),
        'oidc_login_auto_redirect'      => false,
        'oidc_login_redir_fallback'     => true,
        'oidc_login_end_session_redirect' => false,
        'oidc_login_button_text'        => 'Login with Authentik',
        'oidc_login_hide_password_form' => false,
        'oidc_login_use_id_token'       => true,
        'oidc_login_scope'              => 'openid profile email',
      ];
```

> **SSO activation steps (post-deploy):**
> 1. Register a new OIDC application in Authentik with redirect URI `https://cloud.cherkaoui.ch/apps/oidc_login/oidc`
> 2. Fill `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET` in `secrets/nextcloud/nextcloud-admin.secret.yaml` and re-encrypt with SOPS
> 3. Install the `oidc_login` app inside Nextcloud (App Store → search "oidc login")
> 4. Set `oidc_login_auto_redirect: true` once SSO is confirmed working

### ingressroute-nextcloud.yaml

Follows the paperless/scolx IngressRoute pattern:

- `name`: `nextcloud`, `namespace`: `nextcloud`
- Annotations: `websecure`, `tls: "true"`, `certresolver: letsencrypt`
- `match`: `Host(\`cloud.cherkaoui.ch\`) && PathPrefix(\`/\`)`
- Middleware: `security-headers` (traefik namespace)
- Service: `nextcloud`, port: `http` (named port, maps to 8080)
- TLS certResolver: `letsencrypt`

---

## Secret Stubs

Both files go in `secrets/nextcloud/` and must be SOPS-encrypted before committing.

### rustfs-credentials.secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rustfs-credentials
  namespace: nextcloud
type: Opaque
stringData:
  RUSTFS_ACCESS_KEY: CHANGEME
  RUSTFS_SECRET_KEY: CHANGEME
```

### nextcloud-admin.secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: nextcloud-admin
  namespace: nextcloud
type: Opaque
stringData:
  admin-username: admin
  admin-password: CHANGEME
  OIDC_CLIENT_ID: CHANGEME
  OIDC_CLIENT_SECRET: CHANGEME
```

> Encrypt both files with:
> ```bash
> sops --encrypt --in-place secrets/nextcloud/rustfs-credentials.secret.yaml
> sops --encrypt --in-place secrets/nextcloud/nextcloud-admin.secret.yaml
> ```

---

## Repository File Edits

### apps/kustomization.yaml

Add `- nextcloud` to the resources list (alphabetical position between `matrix` and `paperless`, or at the end).

### infrastructure/helmrepositories/repositories.yaml

Append a new document:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: nextcloud
  namespace: flux-system
spec:
  interval: 1h
  url: https://nextcloud.github.io/helm/
```

---

## Storage Summary

| Volume | StorageClass | Size | Purpose |
|---|---|---|---|
| RustFS data | `tank` | 500Gi | Primary S3 object storage |
| RustFS logs | `tank` | 1Gi | RustFS operational logs |
| Nextcloud html | `tank` | 10Gi | App files (`/var/www/html`) |
| PostgreSQL data | `fast` | 10Gi | CNPG database |

---

## Secret Summary

| Secret name | Namespace | Source | Contents |
|---|---|---|---|
| `rustfs-credentials` | nextcloud | SOPS | `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY` |
| `nextcloud-admin` | nextcloud | SOPS | `admin-username`, `admin-password`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` |
| `nextcloud-postgres-cluster-app` | nextcloud | CNPG auto-generated | `host`, `user`, `password`, `dbname`, `uri`, `fqdn-uri` |

---

## Validation Checklist (pre-commit)

- [ ] YAML syntax valid (`yq eval`)
- [ ] Kustomize builds (`kustomize build apps/nextcloud`)
- [ ] Both secret files are SOPS-encrypted (contain `sops:` section)
- [ ] No plaintext credentials in any committed file
- [ ] `apps/kustomization.yaml` includes `nextcloud`
- [ ] `repositories.yaml` includes `nextcloud` HelmRepository
- [ ] HelmRelease `createNamespace: false` is set
- [ ] CNPG cluster storage references `fast` storageClass
- [ ] RustFS storage references `tank` storageClass
