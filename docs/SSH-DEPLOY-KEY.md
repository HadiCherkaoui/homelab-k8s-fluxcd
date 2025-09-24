# Flux GitRepository SSH deploy key instructions

This guide explains how to create and install an SSH deploy key for Flux to access the repo:

- Repo: git@ssh-gitlab.cherkaoui.ch:HadiCherkaoui/homelab-k8s-fluxcd.git
- Namespace: flux-system
- Secret name: flux-git-deploy

## 1) Generate an SSH keypair (local)

```bash
ssh-keygen -t ed25519 -C "flux@homelab" -f ./flux-deploy -N ""
```

This creates:
- Private key: `./flux-deploy`
- Public key:  `./flux-deploy.pub`

## 2) Add the public key as a Deploy Key in GitLab

1. Open the project in GitLab.
2. Settings → Repository → Deploy Keys → Add new key.
3. Name: `flux-homelab`
4. Paste the content of `flux-deploy.pub`.
5. Check "Grant write permissions" only if you want Flux to push (usually not required). Read-only is sufficient.

## 3) Create the Secret in the cluster

When you have kubectl access to the cluster:

```bash
# Optional but recommended: generate known_hosts for your Git server
ssh-keyscan ssh-gitlab.cherkaoui.ch > known_hosts

# Create/update the Secret used by GitRepository.spec.secretRef
kubectl -n flux-system create secret generic flux-git-deploy \
  --from-file=identity=./flux-deploy \
  --from-file=known_hosts=./known_hosts \
  --dry-run=client -o yaml | kubectl apply -f -
```

Notes:
- The key file must be named `identity` in the Secret.
- `known_hosts` prevents MITM attacks during git clones.
- The `clusters/homelab/source.yaml` is already configured to reference this Secret.

## 4) Test repository access

```bash
flux reconcile source git homelab --namespace flux-system --with-source
```

If authentication works, Flux will fetch and produce an Artifact. Check status:

```bash
kubectl -n flux-system get gitrepositories.source.toolkit.fluxcd.io homelab -o yaml
```
