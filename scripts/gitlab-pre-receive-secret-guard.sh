#!/bin/sh
# GitLab server-side pre-receive hook — rejects a push that INTRODUCES a secret,
# before it ever lands on the remote. This is the GitLab-CE equivalent of the
# Premium-only `prevent_secrets` push rule (which returns 404 on this instance).
#
# It is grep-based (no external binaries) so it runs in gitaly's minimal env.
#
# ---------------------------------------------------------------------------
# INSTALL  (per-repo custom hook on the in-cluster gitaly; persists on the PVC)
#
#   # homelab-k8s-fluxcd is GitLab project id 8 -> hashed storage path:
#   REPO=/home/git/repositories/@hashed/2c/62/2c624232cdd221771294dfbb310aca000a0df6ac8b66b696d90ef06fdefb64a3.git
#   # (other repo: SHA=$(printf '<project-id>' | sha256sum | cut -c1-64);
#   #  path = @hashed/${SHA%${SHA#??}}/<chars 3-4>/${SHA}.git)
#
#   # 0) sanity: confirm the storage root + repo dir exist
#   kubectl -n gitlab exec gitlab-gitaly-0 -c gitaly -- ls -d "$REPO"
#
#   # 1) install the hook
#   kubectl -n gitlab exec -i gitlab-gitaly-0 -c gitaly -- sh -c \
#     "mkdir -p $REPO/custom_hooks && cat > $REPO/custom_hooks/pre-receive && chmod +x $REPO/custom_hooks/pre-receive" \
#     < scripts/gitlab-pre-receive-secret-guard.sh
#
# ---------------------------------------------------------------------------
# TEST on a throwaway branch BEFORE trusting it:
#   git checkout -b hooktest
#   printf 'AGE-SECRET-KEY-1%s\n' "$(printf 'A%.0s' $(seq 60))" > /tmp/leak.txt
#   git add /tmp/leak.txt 2>/dev/null; cp /tmp/leak.txt leak.txt; git add leak.txt
#   git commit -m 'test: should be rejected'
#   git push origin hooktest      # EXPECT: rejected by GL-HOOK
#   git reset --hard HEAD~1; git push origin hooktest   # clean -> EXPECT: accepted
#   git push origin --delete hooktest; git checkout main; git branch -D hooktest
#
# DISABLE instantly if it ever blocks a legitimate push:
#   kubectl -n gitlab exec gitlab-gitaly-0 -c gitaly -- rm -f $REPO/custom_hooks/pre-receive
# ---------------------------------------------------------------------------

ZERO=0000000000000000000000000000000000000000

# age/SOPS private keys + PEM private-key blocks. (Encrypted SOPS values and
# age PUBLIC recipients do NOT match, so normal commits pass.)
PATTERN='AGE-SECRET-KEY-1[0-9A-Z]{40,}|BEGIN [A-Z ]*PRIVATE KEY'

rc=0
while read -r old new ref; do
	[ "$new" = "$ZERO" ] && continue # branch deletion: nothing to scan
	if [ "$old" = "$ZERO" ]; then
		commits=$(git rev-list "$new" --not --all 2>/dev/null) # new branch: only the genuinely-new commits
	else
		commits=$(git rev-list "$old..$new" 2>/dev/null)
	fi
	for c in $commits; do
		# inspect only ADDED lines (-U0, lines starting with '+')
		if git show --format= -U0 "$c" 2>/dev/null | grep '^+' | grep -Eq "$PATTERN"; then
			echo >&2
			echo "GL-HOOK REJECT: commit $c introduces a secret (age private key / PEM key)." >&2
			echo "GL-HOOK REJECT: scrub it before pushing — server-side secret guard." >&2
			rc=1
		fi
	done
done
exit "$rc"
