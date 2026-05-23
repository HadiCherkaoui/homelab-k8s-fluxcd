#!/usr/bin/env bash
# push-sops-to-lockbox.sh — one-shot migration helper.
#
# Iterates every secrets/**/*.secret.yaml EXCEPT secrets/lockbox/* (which is
# bootstrap material that stays SOPS-managed). For each file:
#   1. sops --decrypt the file
#   2. yq-extract metadata.name + metadata.namespace + stringData + data
#   3. base64-decode any `data:` values back to strings (lbx wants string KV pairs)
#   4. lbx set -n <namespace> <name> KEY1=value1 KEY2=value2 ...
#
# Idempotent: lbx set overwrites, so re-running is safe.
#
# Requires: sops, yq (mikefarah v4+), lbx; SOPS_AGE_KEY exported.
set -euo pipefail

if [[ -z "${SOPS_AGE_KEY:-}" ]]; then
	echo "ERROR: SOPS_AGE_KEY must be exported" >&2
	exit 1
fi

for cmd in sops yq lbx find base64; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "ERROR: required tool '$cmd' not on PATH" >&2
		exit 1
	fi
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAILED=()
PUSHED=()

while IFS= read -r -d '' f; do
	case "$f" in
	secrets/lockbox/*) continue ;;
	esac

	if ! plain=$(sops --decrypt "$f" 2>/dev/null); then
		echo "  skip (sops decrypt failed): $f" >&2
		FAILED+=("$f")
		continue
	fi
	name=$(echo "$plain" | yq -r '.metadata.name')
	ns=$(echo "$plain" | yq -r '.metadata.namespace')
	if [[ -z "$name" || -z "$ns" || "$name" == "null" || "$ns" == "null" ]]; then
		echo "  skip (no name/namespace): $f" >&2
		FAILED+=("$f")
		continue
	fi

	pairs=()
	# stringData values are plain strings
	while IFS=$'\t' read -r k v; do
		[[ -z "$k" ]] && continue
		pairs+=("${k}=${v}")
	done < <(echo "$plain" | yq -r '.stringData // {} | to_entries | .[] | [.key, .value] | @tsv')

	# data values are base64
	while IFS=$'\t' read -r k v; do
		[[ -z "$k" ]] && continue
		decoded=$(printf '%s' "$v" | base64 -d)
		pairs+=("${k}=${decoded}")
	done < <(echo "$plain" | yq -r '.data // {} | to_entries | .[] | [.key, .value] | @tsv')

	if [[ ${#pairs[@]} -eq 0 ]]; then
		echo "  skip (no data): $f" >&2
		FAILED+=("$f")
		continue
	fi

	echo "push: $f → namespace=$ns name=$name (${#pairs[@]} keys)"
	if lbx set -n "$ns" "$name" "${pairs[@]}" >/dev/null; then
		PUSHED+=("$ns/$name")
	else
		echo "  lbx set FAILED for $ns/$name" >&2
		FAILED+=("$f")
	fi
done < <(find secrets -type f -name '*.secret.yaml' -print0)

echo
echo "Pushed (${#PUSHED[@]}):"
if [[ ${#PUSHED[@]} -gt 0 ]]; then
	printf '  - %s\n' "${PUSHED[@]}"
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
	echo
	echo "FAILED (${#FAILED[@]}):"
	printf '  - %s\n' "${FAILED[@]}"
	exit 1
fi
