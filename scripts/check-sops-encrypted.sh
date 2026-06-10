#!/usr/bin/env bash
# pre-commit hook: every file under secrets/ must be SOPS-encrypted
# (i.e. carry a top-level `sops:` block). Blocks committing a plaintext
# secret into secrets/. Invoked by .pre-commit-config.yaml.
set -euo pipefail
status=0
for f in "$@"; do
	if ! grep -q '^sops:' "$f"; then
		echo "ERROR: not SOPS-encrypted (no 'sops:' block): $f" >&2
		status=1
	fi
done
exit "$status"
