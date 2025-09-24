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

## Bootstrapping Flux

1. Install Flux CLI locally: https://fluxcd.io/flux/installation/
2. Ensure the cluster is reachable via kubectl.
3. Install Flux controllers:

```bash
flux install --namespace=flux-system
```

4. Configure Git access for the `GitRepository` in `clusters/homelab/source.yaml`.
   - Recommended: SSH deploy key for `git@ssh-gitlab.cherkaoui.ch:HadiCherkaoui/homelab-k8s-fluxcd.git`.
   - Provide the key as a Secret in `flux-system` with fields `identity` and `known_hosts`.

5. Apply cluster bootstrap manifests:

```bash
kubectl apply -k clusters/homelab
```

6. Reconcile and verify:

```bash
flux reconcile source git homelab --namespace flux-system --with-source
flux reconcile kustomization infrastructure --namespace flux-system --with-source
flux reconcile kustomization apps --namespace flux-system --with-source
```

## SOPS + Age (secrets)

- Age public key used: `age1tjr83dnugjcyvy8tdhd3xp7v6enqczetmfql6cyazen06lcjddrqt93am7`.
- See `docs/AGE-SOPS.md` for generating keys and installing the `sops-age` Secret in the cluster.
- Always keep plaintext secrets out of Git; use `scripts/encrypt-secret.sh` to create/update secrets.

## Git hooks and CI

- Local hooks live in `.githooks/`. Enable them:

```bash
git config core.hooksPath .githooks
```

- GitLab CI runs `scripts/verify-no-plaintext-secrets.sh` on Merge Requests and pushes.

## Migration status

See `MIGRATION.md` for a detailed mapping from OpenTofu modules to Flux resources, open questions, and any manual steps.
