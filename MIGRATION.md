# Migration Log: OpenTofu -> FluxCD GitOps
### Secret creation commands (to run locally)
Use `scripts/encrypt-secret.sh` to create SOPS-encrypted secrets. Replace placeholder values before running.

#### Media: qbittorrent OpenVPN (namespace: media)
Creates Secret `qbittorrent-openvpn` with keys OPENVPN_USER, OPENVPN_PASSWORD, openvpn.conf

```bash
./scripts/encrypt-secret.sh \
  --namespace media \
  --name qbittorrent-openvpn \
  --data OPENVPN_USER='<your-openvpn-user>' \
  --data OPENVPN_PASSWORD='<your-openvpn-password>' \
  --data openvpn.conf='$(cat /path/to/openvpn.conf | sed -e "s/[$][}{]/\\&/g")' \
  --out secrets/media/qbittorrent-openvpn.secret.yaml
```

Note: For large/multiline files, prefer `--from-file` with a plaintext template outside the repo, then move the encrypted result under `secrets/`.

#### Media: Notifiarr API key (namespace: media)
Creates Secret `notifiarr-env` with key NOTIFIARR_APIKEY

```bash
./scripts/encrypt-secret.sh \
  --namespace media \
  --name notifiarr-env \
  --data NOTIFIARR_APIKEY='<your-notifiarr-apikey>' \
  --out secrets/media/notifiarr-env.secret.yaml
```

#### Paperless admin (namespace: paperless)
Creates Secret `paperless-admin` with keys PAPERLESS_ADMIN_USER, PAPERLESS_ADMIN_PASSWORD, PAPERLESS_ADMIN_MAIL

```bash
./scripts/encrypt-secret.sh \
  --namespace paperless \
  --name paperless-admin \
  --data PAPERLESS_ADMIN_USER='hadi' \
  --data PAPERLESS_ADMIN_PASSWORD='<your-strong-password>' \
  --data PAPERLESS_ADMIN_MAIL='paperless@hide.cherkaoui.ch' \
  --out secrets/paperless/paperless-admin.secret.yaml
```

#### OpenWebUI OAuth (namespace: openwebui)
Creates Secret `openwebui-oauth` with the OAuth client IDs/secrets

```bash
./scripts/encrypt-secret.sh \
  --namespace openwebui \
  --name openwebui-oauth \
  --data GOOGLE_CLIENT_ID='<id>' \
  --data GOOGLE_CLIENT_SECRET='<secret>' \
  --data GITHUB_CLIENT_ID='Ov23litXbu4HLy3nuqSq' \
  --data GITHUB_CLIENT_SECRET='<secret>' \
  --data MICROSOFT_CLIENT_ID='<id>' \
  --data MICROSOFT_CLIENT_SECRET='<secret>' \
  --data MICROSOFT_TENANT_ID='<tenant>' \
  --out secrets/openwebui/openwebui-oauth.secret.yaml
```

After creating each encrypted file, you can edit safely with:

```bash
sops secrets/<ns>/<name>.secret.yaml
```


This document captures the mapping from the existing OpenTofu modules to Flux v2 resources, notes on secrets, and any manual steps.

References:
- Flux repo structure: https://fluxcd.io/flux/guides/repository-structure/
- Kustomizations: https://fluxcd.io/flux/components/kustomize/kustomizations/
- SOPS with Age: https://fluxcd.io/flux/guides/mozilla-sops/

## Cluster and Source
- `clusters/homelab/source.yaml`: `GitRepository` pointing to `git@ssh-gitlab.cherkaoui.ch:HadiCherkaoui/homelab-k8s-fluxcd.git` on `main`.
- `clusters/homelab/infrastructure.yaml`: `Kustomization` for `./infrastructure`.
- `clusters/homelab/apps.yaml`: `Kustomization` for `./apps`, depends on `infrastructure`.

## Infrastructure

### Traefik (from `modules/traefik`)
- Namespace: `infrastructure/traefik/namespace.yaml`.
- Helm repo: `infrastructure/traefik/helmrepository.yaml`.
- HelmRelease: `infrastructure/traefik/helmrelease.yaml` (version 35.4.0).
- Middleware: `infrastructure/traefik/middleware-security-headers.yaml`.
- ServiceMonitor: `infrastructure/traefik/servicemonitor.yaml`.
- Secrets: ACME email is not secret; retained via values. No secrets stored.

### Storage (from `modules/storage`)
- Helm repo: `infrastructure/storage/helmrepository.yaml` (containeroo).
- HelmRelease: `infrastructure/storage/helmrelease.yaml` (default storageClass + nodePathMap).
- Requires host path `/mnt/k8s` (from GitLab variables).

### CloudNativePG operator (from `modules/cnpg-operator`)
- Helm repo: `infrastructure/cnpg-operator/helmrepository.yaml`.
- HelmRelease: `infrastructure/cnpg-operator/helmrelease.yaml` (version 0.26.0) in `cnpg-system` namespace.

### Monitoring (from `modules/monitoring`)
- Namespace: `infrastructure/monitoring/namespace.yaml`.
- Helm repo: `infrastructure/monitoring/helmrepository.yaml`.
- HelmRelease: `infrastructure/monitoring/helmrelease.yaml` (version 72.9.0). Grafana admin password intentionally omitted here; set via SOPS Secret or runtime env.
- Grafana IngressRoute: `infrastructure/monitoring/grafana-ingressroute.yaml` with host from variables.

## Applications (planned)

### Media (from `modules/media`)
- Namespace: `apps/media/namespace.yaml`.
- HelmReleases for apps (e.g., TrueCharts `plex`, `jellyfin`, etc.).
- PVCs as YAML manifests.
- IngressRoutes for each hostname.
- Secrets to SOPS:
  - `notifiarr_apikey`
  - `openvpn_user`, `openvpn_password`, `openvpn_config`
  - `plex_claim`

### Paperless (from `modules/paperless`)
- Namespace: `apps/paperless/namespace.yaml`.
- HelmRelease: TrueCharts `paperless-ngx` with PVCs.
- IngressRoute for hostname.
- Secrets to SOPS:
  - `paperless_admin_password` (user/mail can be plain or secret per preference)

### OpenWebUI (from `modules/ai`)
- Namespace: `apps/openwebui/namespace.yaml`.
- Kustomize manifests for Deployment/Service/PVC (or a HelmRelease if desired).
- IngressRoute for hostname.
- Secrets to SOPS:
  - `github_client_id`, `github_client_secret`
  - `google_client_id`, `google_client_secret`
  - `microsoft_client_id`, `microsoft_client_secret`, `microsoft_tenant_id`

### GitLab (from `modules/gitlab`)
- Namespace: `apps/gitlab/namespace.yaml`.
- HelmRelease: `gitlab` (chart `gitlab`), ingress disabled; IngressRoute/IngressRouteTCP defined separately.
- HelmRelease: `gitlab-agent` with RBAC and ServiceMonitor.
- Protonmail bridge HelmRelease if needed.
- IngressRoutes for web, registry, minio, kas, and SSH (TCP).
- Secrets to SOPS:
  - `gitlab_smtp_password`
  - `protonmail_username` (optional)
  - `gitlab_agent_token`

### Scolx (from `modules/scolx`)
- Namespace: `apps/scolx/namespace.yaml`.
- ImagePullSecret from registry credentials (SOPS secret).
- CNPG `Cluster` manifest and `pg-superuser-secret` (SOPS).
- Deployments/Services/PVC as Kustomize.
- HelmRelease: `pgadmin` with env.
- IngressRoute for hostname.
- Secrets to SOPS:
  - `scolx_postgres_password`
  - `jwt_secret`
  - `scolx_admin_password`
  - registry credentials: server, username, password (username optional as secret).

### n8n, craftycontroller, websites
- To be ported similarly. Websites hostnames from variables will become IngressRoutes.

## Secrets and Git Hygiene
- `.sops.yaml` enforces encryption for files under `secrets/`.
- `docs/AGE-SOPS.md` provides step-by-step key generation and cluster secret installation.
- Scripts and hooks:
  - `scripts/encrypt-secret.sh` to create/update SOPS-encrypted secrets.
  - `scripts/verify-no-plaintext-secrets.sh` used by `.githooks/*` and `.gitlab-ci.yml`.

## Variables imported from GitLab (snapshot)
From `gitlab-project-variables.json`:
- Non-secret settings used directly in Helm values or manifests:
  - `acme_email`, `local_path_provisioner_path`, `grafana_hostname`, `prometheus_retention`, `prometheus_storage`, `alertmanager_storage`, `grafana_storage`, `plex_hostname`, `wg_easy_hostname`, `hadi_hostname`, `laura_hostname`, `quillium_docs_hostname`, `docs_hostname`, `github_client_id`.
- Secrets to be SOPS-encrypted:
  - `grafana_admin_password`, `plex_claim`, `openvpn_user`, `openvpn_password`, `openvpn_config` (if used), `notifiarr_apikey`, `wg_easy_password_hash` (treated as secret), and others listed in app sections.

## Manual Steps Required
- Install Flux controllers and create:
  - `flux-git-deploy` Secret (SSH key) for Git access, if using SSH.
  - `sops-age` Secret with Age private key (see `docs/AGE-SOPS.md`).
- Provide/confirm any values not retrievable from GitLab variables (e.g., gitlab domain/hostnames, registry creds, OAuth secrets).

## Test Plan
- Lint/scan: `.gitlab-ci.yml` runs `scripts/verify-no-plaintext-secrets.sh`.
- Dry-run locally:
  - `kubectl kustomize clusters/homelab | kubectl apply --server-dry-run -f -`
- After cluster bootstrap:
  - `flux reconcile source git homelab --namespace flux-system --with-source`
  - `flux reconcile kustomization infrastructure --namespace flux-system --with-source`
  - `flux reconcile kustomization apps --namespace flux-system --with-source`

## Open Questions
- Do you prefer SSH deploy key or HTTPS with PAT for Flux GitRepository access?
- Confirm CNPG operator namespace (`cnpg-system`) or prefer default install NS.
- Confirm Traefik service type (LoadBalancer) and annotations for your environment.
- Any additional CRDs to include explicitly, or rely on Helm chart CRD installation.
