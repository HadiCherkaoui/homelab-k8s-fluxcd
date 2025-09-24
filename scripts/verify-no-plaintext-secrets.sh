#!/usr/bin/env bash
set -euo pipefail

# verify-no-plaintext-secrets.sh
# Purpose: Prevent committing or pushing plaintext secrets.
# Fails if it finds:
#  - Kubernetes Secret manifests without SOPS metadata
#  - Files containing suspicious secret-like keys unless SOPS-encrypted
#
# Dependencies: bash, grep, awk, sed. Optional: sops, yq.

REPO_ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# File globs to scan (exclude .git and common binary dirs)
SCAN_PATHS=(
  "$REPO_ROOT_DIR"
)

IGNORE_GLOBS=(
  ".git"
  ".gitlab"
  ".githooks"
)

# Suspicious keys to flag when found in clear text
SUSPICIOUS_KEYS_REGEX='(secret|password|token|api[_-]?key|client[_-]?secret|private[_-]?key|authorization|authToken|oauth|smtp[_-]?password|claim)'

failures=0

is_ignored() {
  local path="$1"
  for pat in "${IGNORE_GLOBS[@]}"; do
    [[ "$path" == *$pat* ]] && return 0
  done
  return 1
}

# 1) Check Secret manifests are SOPS-encrypted
while IFS= read -r -d '' file; do
  is_ignored "$file" && continue
  # quick check for kind: Secret
  if grep -qE '^kind:\s*Secret\b' "$file"; then
    if ! grep -q '^sops:' "$file"; then
      echo "[ERROR] Secret manifest missing SOPS metadata: $file" >&2
      failures=$((failures+1))
      continue
    fi
    # Optional deeper check: ensure sops can parse/decrypt metadata (does not require the key)
    # Just verify the presence of sops metadata block structure
    if ! grep -qE '^sops:\n' "$file"; then
      echo "[ERROR] Secret manifest has malformed sops block: $file" >&2
      failures=$((failures+1))
    fi
  fi
done < <(find "$REPO_ROOT_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

# 2) Check for suspicious keys in non-SOPS files
while IFS= read -r -d '' file; do
  is_ignored "$file" && continue
  # Skip files that are SOPS-encrypted
  if grep -q '^sops:' "$file"; then
    continue
  fi
  if grep -qiE "$SUSPICIOUS_KEYS_REGEX" "$file"; then
    echo "[ERROR] Potential plaintext secret-like key found in: $file" >&2
    echo "        Ensure this file is SOPS-encrypted or remove the secret value." >&2
    failures=$((failures+1))
  fi
done < <(find "$REPO_ROOT_DIR" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.env' -o -name '*.txt' \) -print0)

if [[ $failures -gt 0 ]]; then
  echo "[FAIL] Found $failures potential secret hygiene issues." >&2
  exit 1
fi

echo "[OK] No plaintext secrets detected."
