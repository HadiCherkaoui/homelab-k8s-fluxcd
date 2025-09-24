#!/usr/bin/env bash
set -euo pipefail

# bootstrap-flux.sh
# Purpose: Install Flux controllers and required secrets for Git access and SOPS Age decryption.
# Note: Run this after you have kubectl access to the cluster.

NS=${FLUX_NAMESPACE:-flux-system}
REPO_URL=${REPO_URL:-"ssh://git@ssh-gitlab.cherkaoui.ch/HadiCherkaoui/homelab-k8s-fluxcd.git"}
BRANCH=${BRANCH:-main}

cat <<'INFO'
[bootstrap] This script will:
  1) Ensure flux-system namespace exists
  2) Install Flux controllers
  3) Optionally create Git SSH deploy key Secret (if IDENTITY_FILE provided)
  4) Create SOPS Age secret (if AGE_KEY_FILE provided)
  5) Apply cluster bootstrap kustomization (clusters/homelab)

Environment variables:
  FLUX_NAMESPACE   Namespace for Flux (default: flux-system)
  REPO_URL         Git repo URL for Flux GitRepository (default: ssh://git@ssh-gitlab.cherkaoui.ch/HadiCherkaoui/homelab-k8s-fluxcd.git)
  BRANCH           Git branch (default: main)
  IDENTITY_FILE    Path to SSH private key for repo access (optional)
  KNOWN_HOSTS_FILE Path to known_hosts for git server (optional)
  AGE_KEY_FILE     Path to Age private key (age-key.txt) for SOPS decryption (optional)
INFO

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

# Install Flux controllers
if ! command -v flux >/dev/null 2>&1; then
  echo "[bootstrap] ERROR: flux CLI not found. Install from https://fluxcd.io/flux/installation/" >&2
  exit 1
fi

flux install --namespace "$NS"

echo "[bootstrap] Flux controllers installed in namespace: $NS"

# Git deploy key secret (optional)
if [[ -n "${IDENTITY_FILE:-}" ]]; then
  echo "[bootstrap] Creating/updating Secret flux-git-deploy with SSH key"
  if [[ -n "${KNOWN_HOSTS_FILE:-}" ]]; then
    kubectl -n "$NS" create secret generic flux-git-deploy \
      --from-file=identity="$IDENTITY_FILE" \
      --from-file=known_hosts="$KNOWN_HOSTS_FILE" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    kubectl -n "$NS" create secret generic flux-git-deploy \
      --from-file=identity="$IDENTITY_FILE" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi
fi

# SOPS Age Secret (optional)
if [[ -n "${AGE_KEY_FILE:-}" ]]; then
  echo "[bootstrap] Creating/updating Secret sops-age with Age private key"
  kubectl -n "$NS" create secret generic sops-age \
    --from-file=age.agekey="$AGE_KEY_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# Apply cluster kustomization
kubectl apply -k clusters/homelab

echo "[bootstrap] Triggering Flux reconciliations"
flux reconcile source git homelab --namespace "$NS" --with-source || true
flux reconcile kustomization infrastructure --namespace "$NS" --with-source || true
flux reconcile kustomization apps --namespace "$NS" --with-source || true

echo "[bootstrap] Done"
