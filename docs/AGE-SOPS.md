# SOPS + Age setup for FluxCD

This document explains how to generate Age keys, configure SOPS, and install the SOPS Age key in the cluster for FluxCD. Do NOT commit plaintext secrets to the repository.

References:
- Flux official guide: https://fluxcd.io/flux/guides/mozilla-sops/

## 1) Generate an Age key locally (one-time)

```bash
# Install age if not available
# macOS: brew install age
# Arch:  sudo pacman -S age
# Debian/Ubuntu: sudo apt-get install age -y

# Generate a key file
age-keygen -o age-key.txt

# Show the public key (starts with age1...)
grep '^# public key:' -n age-key.txt
```

Keep `age-key.txt` PRIVATE. The line starting with `age1...` is your public key.

## 2) Configure SOPS to use the Age public key

The repository contains `.sops.yaml` configured to encrypt any `secrets/*.yaml` files with your public key.

- Public key in use:

```
age1tjr83dnugjcyvy8tdhd3xp7v6enqczetmfql6cyazen06lcjddrqt93am7
```

If you ever rotate keys, update `.sops.yaml` accordingly.

## 3) Storing the Age private key in the cluster (required before Flux can decrypt)

Only run these commands when you have kubectl access to the cluster. This creates the `sops-age` Secret in `flux-system` namespace as expected by Flux.

```bash
# Create the namespace if Flux is not yet installed
kubectl create namespace flux-system || true

# Create the secret containing your private Age key
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=age-key.txt \
  --dry-run=client -o yaml | kubectl apply -f -
```

Notes:
- The key must be stored with key name `age.agekey` in that Secret.
- Ensure only admins can access this Secret (namespace RBAC is recommended).

## 4) Creating a new SOPS-encrypted Secret manifest

Example: create a Kubernetes Secret for `grafana-admin` in the `monitoring` namespace.

```bash
# 1) Create a plaintext template outside of the repo (DO NOT COMMIT)
cat > /tmp/grafana-admin.secret.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
type: Opaque
stringData:
  admin-password: "<your-strong-password>"
YAML

# 2) Encrypt it to the repo path using SOPS
sops --encrypt \
  --in-place \
  /tmp/grafana-admin.secret.yaml

# 3) Move the encrypted file into the repo under secrets/
mkdir -p secrets/monitoring
mv /tmp/grafana-admin.secret.yaml secrets/monitoring/grafana-admin.secret.yaml
```

SOPS will add the `sops:` metadata block and encrypt all values in `data`/`stringData` fields using the Age public key.

## 5) Editing an existing encrypted secret

```bash
sops secrets/monitoring/grafana-admin.secret.yaml
```

SOPS will decrypt on-the-fly and re-encrypt on save.

## 6) Verifying decryption (optional)

```bash
sops -d secrets/monitoring/grafana-admin.secret.yaml | yq eval '.stringData.admin-password' -
```

This should print the plaintext value locally. Flux will decrypt in-cluster using the `sops-age` Secret created earlier.
