#!/usr/bin/env bash
set -euo pipefail

# encrypt-secret.sh
# Purpose: Create or update a SOPS-encrypted Kubernetes Secret manifest.
# Usage examples:
#   ./scripts/encrypt-secret.sh \
#     --namespace monitoring \
#     --name grafana-admin \
#     --data admin-password='your-strong-pass' \
#     --out secrets/monitoring/grafana-admin.secret.yaml
#
#   ./scripts/encrypt-secret.sh --from-file /path/plain.secret.yaml --out secrets/foo/bar.secret.yaml
#
# Requires: sops, yq

NAMESPACE=""
NAME=""
OUT_FILE=""
FROM_FILE=""
DATA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --from-file) FROM_FILE="$2"; shift 2 ;;
    --data) DATA_ARGS+=("$2"); shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! command -v sops >/dev/null 2>&1; then
  echo "ERROR: sops not found. Install from https://github.com/getsops/sops" >&2
  exit 1
fi

if [[ -z "$OUT_FILE" ]]; then
  echo "ERROR: --out is required" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

if [[ -n "$FROM_FILE" ]]; then
  cp "$FROM_FILE" "$TMP_FILE"
else
  if [[ -z "$NAMESPACE" || -z "$NAME" ]]; then
    echo "ERROR: --namespace and --name are required when not using --from-file" >&2
    exit 1
  fi
  cat > "$TMP_FILE" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData: {}
YAML
  for kv in "${DATA_ARGS[@]:-}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    yq -i ".stringData[\"${k}\"]=\"${v}\"" "$TMP_FILE"
  done
fi

# Encrypt in-place (sops reads .sops.yaml)
sops --encrypt --in-place "$TMP_FILE"

mv "$TMP_FILE" "$OUT_FILE"

echo "Encrypted secret written to: $OUT_FILE"
