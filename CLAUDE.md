# AGENTS.md

Guidelines for AI coding agents working in this repository.

## Project Overview

This is a **Flux v2 GitOps repository** for managing a homelab Kubernetes cluster. It uses a declarative approach where the desired state of the cluster is defined in YAML manifests stored in Git, and Flux CD continuously applies these changes to the cluster.

### Technology Stack

| Component | Purpose |
|-----------|---------|
| **Flux CD v2.6.4** | GitOps continuous delivery |
| **SOPS + Age** | Secret encryption |
| **Kustomize** | Kubernetes manifest management and customization |
| **Helm** | Package management via HelmRelease and HelmRepository |
| **Traefik** | Ingress controller and reverse proxy |
| **Cilium** | CNI (Container Network Interface) with L2 announcements |
| **CloudNativePG** | PostgreSQL operator for database management |
| **kube-prometheus-stack** | Monitoring and alerting (Prometheus + Grafana) |
| **local-path-provisioner** | Dynamic volume provisioning |

### Repository Structure

```
homelab-k8s-fluxcd/
├── clusters/homelab/           # Flux bootstrap and cluster configuration
│   ├── flux-system/            # Flux components (auto-generated)
│   ├── kustomization.yaml      # Root kustomization
│   ├── infrastructure.yaml     # Infrastructure Kustomization
│   ├── apps.yaml               # Apps Kustomization
│   └── secrets.yaml            # Secrets Kustomization (with SOPS decryption)
├── infrastructure/             # Core cluster infrastructure
│   ├── helmrepositories/       # Helm chart repositories
│   ├── traefik/                # Ingress controller
│   ├── storage/                # Local path provisioner
│   ├── cnpg-operator/          # CloudNativePG operator
│   ├── monitoring/             # Prometheus/Grafana stack
│   └── cilium-l2/              # Cilium L2 configuration
├── apps/                       # Application deployments
│   ├── media/                  # Plex, Jellyfin, *arr stack
│   ├── scolx/                  # Custom application with CNPG
│   ├── gitlab/                 # GitLab instance and agent
│   ├── websites/               # Static websites
│   ├── n8n/                    # Workflow automation
│   ├── paperless/              # Document management
│   ├── immich/                 # Photo management
│   ├── searxng/                # Search engine
│   ├── openwebui/              # AI chat interface
│   ├── craftycontroller/       # Minecraft server management
│   └── wg-easy/                # WireGuard VPN
├── secrets/                    # SOPS-encrypted secrets only
│   ├── media/
│   ├── scolx/
│   ├── gitlab/
│   ├── monitoring/
│   ├── paperless/
│   └── traefik/
├── scripts/                    # Helper scripts
│   ├── encrypt-secret.sh       # Create encrypted secrets
│   ├── update_helm_charts.sh   # Automated version updates
│   └── remove-resource-limits.sh # Debug helper
├── .sops.yaml                  # SOPS encryption configuration
└── .gitlab-ci.yml              # CI/CD pipeline
```

## File Naming Conventions

- **HelmReleases**: `helmrelease-<name>.yaml`
- **Deployments**: `deploy-<name>.yaml`
- **Services**: `svc-<name>.yaml`
- **IngressRoutes**: `ingressroute-<name>.yaml` or `ingress-<name>.yaml`
- **PVCs**: `pvc-<name>.yaml`
- **CronJobs**: `cronjob-<name>.yaml`
- **Secrets**: `<name>.secret.yaml` (must be SOPS-encrypted)
- **Kustomization**: `kustomization.yaml`
- **Namespaces**: `namespace.yaml`

## Key Configuration Patterns

### HelmRelease Guidelines

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app-name>
  namespace: <app-namespace>
spec:
  interval: 10m
  chart:
    spec:
      chart: <chart-name>
      version: "X.Y.Z"           # Always use explicit version, no wildcards
      sourceRef:
        kind: HelmRepository
        name: <repo-name>
        namespace: flux-system   # Always reference repos in flux-system
  install:
    createNamespace: false       # Namespace managed separately
  values:
    # Chart-specific values
```

### Namespace Management

Each app directory includes a `namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <app-name>
  labels:
    # Optional: monitoring label for ServiceMonitor selection
    app.kubernetes.io/part-of: <app-name>
```

Namespaces are always created explicitly and referenced in kustomization files with `namespace: <name>`.

### Kustomization Structure

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <target-namespace>
resources:
  - namespace.yaml              # Always first
  - pvc-<name>.yaml             # Storage claims before deployments
  - helmrelease-<name>.yaml     # Helm releases
  - ingressroute-<name>.yaml    # Ingress configuration
  # ... other resources
```

### Traefik IngressRoute Pattern

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app-name>
  namespace: <app-namespace>
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`<subdomain>.cherkaoui.ch`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: traefik
      services:
        - name: <service-name>
          port: <port>
  tls:
    certResolver: letsencrypt
```

### PersistentVolumeClaim Pattern

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <name>
  namespace: <namespace>
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: <size>Gi
```

## Secret Management

### CRITICAL: Never Commit Plaintext Secrets

All secrets must be stored in `secrets/` directory and encrypted with SOPS.

### Creating Encrypted Secrets

Use the helper script:

```bash
./scripts/encrypt-secret.sh \
  --namespace <namespace> \
  --name <secret-name> \
  --data KEY1=VALUE1 \
  --data KEY2=VALUE2 \
  --out secrets/<app>/<secret-name>.secret.yaml
```

Or encrypt an existing secret file:

```bash
./scripts/encrypt-secret.sh \
  --from-file /path/to/plain-secret.yaml \
  --out secrets/<app>/<name>.secret.yaml
```

### Manual SOPS Encryption

```bash
# Encrypt a file
sops --encrypt --in-place secrets/<app>/<name>.secret.yaml

# Edit an encrypted file
sops secrets/<app>/<name>.secret.yaml
```

### Encrypted Secret Structure

Encrypted files must have a `sops:` section at the end:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <name>
  namespace: <namespace>
type: Opaque
stringData:
  KEY: ENC[AES256_GCM,...]
sops:
  age:
    - recipient: age1lkt8h48rt7addnx0a4fjjmlul03xt32wdwh832d5k6xn7x4h24msgs05kn
  # ... sops metadata
```

## Build/Test/Lint Commands

### YAML Validation

```bash
# Validate YAML syntax
yq eval '.' <file.yaml> > /dev/null

# Validate with kustomize
kustomize build <directory>
```

### Kubernetes Validation (requires kubectl)

```bash
# Dry-run validation
kubectl apply --dry-run=client -f <file.yaml>

# Validate entire kustomization
kubectl apply --dry-run=client -k <directory>
```

### Helper Scripts

```bash
# Create and encrypt a secret
./scripts/encrypt-secret.sh [options]

# Update Helm chart versions (requires yq and crane)
./scripts/update_helm_charts.sh

# Remove resource limits (debugging only)
./scripts/remove-resource-limits.sh
```

## CI/CD Pipeline

GitLab CI runs a scheduled pipeline for maintenance:

- **Schedule**: `helm_chart_bump` job runs on scheduled triggers
- **Function**: Automatically checks for new Helm chart versions and creates MRs
- **Requirements**: `DEPLOY_TOKEN` for GitLab API access

### Pipeline Stages

1. `maintenance`: Automated Helm chart version updates

## Code Style Guidelines

### YAML Formatting

- Use **2 spaces** for indentation
- Use **lowercase** for resource names (kebab-case)
- Multi-document YAML files use `---` separator
- End files with a newline

### Resource Ordering

In kustomization files, order resources logically:
1. Namespace (always first)
2. Storage (PVCs)
3. Secrets (encrypted)
4. ConfigMaps
5. Deployments/StatefulSets/DaemonSets
6. Services
7. IngressRoutes
8. ServiceMonitors/CronJobs/Other

### Helm Values

- Use explicit chart versions (no wildcards like `*` or `>=`)
- Set reasonable intervals (`10m` for apps, `1h` for infrastructure)
- Document non-default values with comments when necessary

## Testing Strategies

### Validation Checklist

Before committing changes:

- [ ] YAML syntax is valid (`yq eval`)
- [ ] Kustomize builds successfully (`kustomize build`)
- [ ] Secrets are encrypted (check for `sops:` section)
- [ ] Namespaces are explicitly created
- [ ] HelmRelease `createNamespace: false` is set
- [ ] File names follow conventions
- [ ] No plaintext credentials in any file

### Testing Changes

1. Apply to test cluster first if available
2. Use `kubectl apply --dry-run=client` for validation
3. Monitor Flux reconciliation with `flux get kustomizations --watch`
4. Check pod status: `kubectl get pods -n <namespace>`

## Security Considerations

1. **Secret Encryption**: All secrets must be SOPS-encrypted
2. **Namespace Isolation**: Each app has its own namespace
3. **Network Security**: 
   - Traefik middleware for security headers
   - Cilium network policies (via Flux)
4. **TLS**: All external traffic uses TLS via Let's Encrypt (DNS challenge with Cloudflare)
5. **Resource Limits**: Define CPU/memory limits where appropriate

### Security Headers Middleware

All IngressRoutes should use the `security-headers` middleware:

```yaml
middlewares:
  - name: security-headers
    namespace: traefik
```

This enables:
- XSS protection
- Content type sniffing protection
- Strict transport security (HSTS)
- CSP headers
- Permissions policy

## Common Tasks

### Adding a New Application

1. Create directory: `mkdir apps/<app-name>/`
2. Create `namespace.yaml` with app namespace
3. Create `kustomization.yaml` referencing all resources
4. Add HelmRelease or Deployment manifests
5. Add IngressRoute if external access needed
6. Add PVCs if persistent storage needed
7. Add to `apps/kustomization.yaml`
8. Commit and push to trigger Flux reconciliation

### Adding Infrastructure Component

1. Create directory under `infrastructure/<component>/`
2. Follow the same pattern as applications
3. Add to `infrastructure/kustomization.yaml`
4. Consider adding dependency to `clusters/homelab/apps.yaml` if apps depend on it

### Adding a Secret

```bash
./scripts/encrypt-secret.sh \
  --namespace <namespace> \
  --name <secret-name> \
  --data KEY1=VALUE1 \
  --data KEY2=VALUE2 \
  --out secrets/<app>/<secret-name>.secret.yaml
```

Then reference in your deployment:

```yaml
envFrom:
  - secretRef:
      name: <secret-name>
```

### Updating Helm Chart Versions

Automated via GitLab CI scheduled pipeline. To manually update:

```bash
# Requires yq (mikefarah v4+) and crane
./scripts/update_helm_charts.sh
```

### Debugging Flux Issues

```bash
# Check kustomization status
flux get kustomizations

# Check helmrelease status
flux get helmreleases -n <namespace>

# View logs
flux logs -n flux-system

# Suspend/resume reconciliation
flux suspend kustomization <name>
flux resume kustomization <name>
```

**lockbox-k8s-controller:** The controller is event-driven — a Secret deleted or pruned by Flux will not be self-healed until the next event or controller restart; if a lockbox-managed Secret is missing, run `kubectl -n lockbox-system rollout restart deploy/lockbox-k8s-controller` to force an immediate replay.

## Required Tools

| Tool | Purpose | Version |
|------|---------|---------|
| `yq` | YAML processing | mikefarah v4+ |
| `sops` | Secret encryption | 3.x+ |
| `crane` | OCI registry operations | 0.20+ |
| `kubectl` | Kubernetes CLI | 1.28+ |
| `kustomize` | Kustomize CLI | 5.x+ |
| `flux` | Flux CLI | 2.x+ |

## References

- [Flux Repository Structure](https://fluxcd.io/flux/guides/repository-structure/)
- [SOPS with Age](https://fluxcd.io/flux/guides/mozilla-sops/)
- [HelmRelease Specification](https://fluxcd.io/flux/components/helm/helmreleases/)
- [Kustomization Specification](https://fluxcd.io/flux/components/kustomize/kustomizations/)
- [Traefik Kubernetes CRD](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/)
- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
