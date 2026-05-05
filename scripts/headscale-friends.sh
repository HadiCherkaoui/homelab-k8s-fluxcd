#!/usr/bin/env bash
# Manage members of group:friends in the headscale ACL.
#
# Usage:
#   headscale-friends.sh list
#   headscale-friends.sh add <username>
#   headscale-friends.sh remove <username>
#
# Username is a headscale username (e.g. "yanis"); a trailing "@" is appended
# if missing, since headscale ACLs require it. Email-format identifiers are
# passed through unchanged.

set -euo pipefail

NS="${HEADSCALE_NS:-headscale}"
DEPLOY="${HEADSCALE_DEPLOY:-deploy/headscale}"
GROUP="group:friends"

usage() {
	cat >&2 <<EOF
Usage:
  $(basename "$0") list
  $(basename "$0") add <username>
  $(basename "$0") remove <username>
EOF
	exit 1
}

normalize() {
	case "$1" in
	*@*) printf '%s' "$1" ;;
	*) printf '%s@' "$1" ;;
	esac
}

policy_get() {
	kubectl exec -n "$NS" "$DEPLOY" -- headscale policy get -o json
}

policy_set() {
	kubectl exec -i -n "$NS" "$DEPLOY" -- headscale policy set -f /dev/stdin >/dev/null
}

case "${1:-}" in
list)
	policy_get | jq -r --arg g "$GROUP" '.groups[$g][]?'
	;;
add)
	[ $# -ge 2 ] || usage
	u=$(normalize "$2")
	policy_get |
		jq --arg g "$GROUP" --arg u "$u" \
			'.groups[$g] = ((.groups[$g] // []) + [$u] | unique)' |
		policy_set
	echo "added $u to $GROUP"
	;;
remove | rm | del)
	[ $# -ge 2 ] || usage
	u=$(normalize "$2")
	policy_get |
		jq --arg g "$GROUP" --arg u "$u" \
			'.groups[$g] = ((.groups[$g] // []) - [$u])' |
		policy_set
	echo "removed $u from $GROUP"
	;;
*)
	usage
	;;
esac
