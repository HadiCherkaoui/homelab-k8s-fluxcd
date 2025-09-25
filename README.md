# homelab-k8s-fluxcd

This repository contains Flux v2 GitOps manifests for the homelab Kubernetes cluster, migrated from the previous OpenTofu/Terraform setup.

Key practices followed:
- Repo structure per Flux guidance: `clusters/`, `infrastructure/`, `apps/`, `secrets/`, `crds/`.
- SOPS + Age for secret encryption. No plaintext secrets in Git.
- Git hooks and GitLab CI to block unencrypted secrets.

References:
- Flux repo structure: https://fluxcd.io/flux/guides/repository-structure/
- Kustomizations: https://fluxcd.io/flux/components/kustomize/kustomizations/
- SOPS with Age: https://fluxcd.io/flux/guides/mozilla-sops/

## Repository layout

```
homelab-k8s-fluxcd/
  clusters/
    homelab/
      kustomization.yaml           # Applies Flux Source + Kustomizations below
      source.yaml                  # GitRepository pointing to this repo (branch main)
      infrastructure.yaml          # Kustomization -> ../../infrastructure
      apps.yaml                    # Kustomization -> ../../apps
  infrastructure/
    traefik/ ...                  # Ingress controller, middleware, ServiceMonitor
    storage/ ...                  # Local-path-provisioner
    cnpg-operator/ ...            # CloudNativePG operator
    monitoring/ ...               # kube-prometheus-stack and Grafana ingress
  apps/
    media/ ...                    # Plex, Jellyfin, etc.
    paperless/ ...                # Paperless-NGX
    openwebui/ ...                # AI open-webui
    gitlab/ ...                   # GitLab + agent
    scolx/ ...                    # Scolx app + CNPG Cluster + pgAdmin
    n8n/, craftycontroller/, websites/ ...
  secrets/                        # SOPS-encrypted secret manifests only
  crds/                           # CRDs if needed (generally installed by Helm)
  scripts/
    bootstrap-flux.sh
    encrypt-secret.sh
    verify-no-plaintext-secrets.sh
  .sops.yaml
  .gitlab-ci.yml
  docs/AGE-SOPS.md
  MIGRATION.md
```
