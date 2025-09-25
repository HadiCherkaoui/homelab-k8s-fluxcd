#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

HELMREPO_FILE="infrastructure/helmrepositories/repositories.yaml"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq not found in PATH" >&2
  exit 1
fi
if ! command -v crane >/dev/null 2>&1; then
  echo "crane not found in PATH" >&2
  exit 1
fi

# Ensure yq is mikefarah v4+
YQ_VER_STR=$(yq --version 2>/dev/null || true)
if echo "$YQ_VER_STR" | grep -qE '^yq [0-3]\.'; then
  echo "This script requires mikefarah yq v4+. Detected: $YQ_VER_STR" >&2
  echo "Install yq v4, e.g.:" >&2
  echo "  curl -sSL -o /usr/local/bin/yq \"https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64\" && chmod +x /usr/local/bin/yq" >&2
  exit 1
fi

log(){ echo "[helm-bump] $*"; }

# Load HelmRepository map: name -> (type,url)
# Requires mikefarah/yq v4

declare -A REPO_TYPE
declare -A REPO_URL

if [[ -f "$HELMREPO_FILE" ]]; then
  while IFS='|' read -r name rtype url; do
    [[ -z "${name:-}" || -z "${url:-}" ]] && continue
    rtype="${rtype:-http}"
    REPO_TYPE["$name"]="$rtype"
    REPO_URL["$name"]="$url"
  done < <(yq -r 'select(.kind=="HelmRepository") | (.metadata.name + "|" + (.spec.type // "http") + "|" + .spec.url)' "$HELMREPO_FILE")
else
  echo "HelmRepository file not found: $HELMREPO_FILE" >&2
  exit 1
fi

log "Loaded ${#REPO_URL[@]} HelmRepository entries"
if [[ ${#REPO_URL[@]} -eq 0 ]]; then
  echo "No HelmRepository entries parsed from $HELMREPO_FILE" >&2
  exit 1
fi

# Find HelmRelease specs across repo
mapfile -t HR_FILES < <(git ls-files '*.yaml' '*.yml' | xargs -r grep -l "kind: HelmRelease" || true)

declare -a UPDATES=()

fetch_http_versions(){
  local base_url="$1" chart="$2"
  local idx_url="$base_url"
  if [[ "$idx_url" != *"index.yaml" ]]; then
    [[ "$idx_url" != */ ]] && idx_url+="/"
    idx_url+="index.yaml"
  fi
  log "Fetching index: $idx_url for chart $chart"
  if ! curl -fsSL "$idx_url" | yq -r ".entries[\"$chart\"][].version" 2>/dev/null; then
    return 1
  fi
}

fetch_oci_versions(){
  local repo_url="$1" chart="$2"
  local norm="$repo_url"
  norm="${norm#oci://}"
  local target="$norm/$chart"
  log "crane ls $target"
  crane ls "$target" 2>/dev/null || true
}

pick_latest(){
  # reads versions on stdin, prints best version to stdout
  # prefer non-prerelease (no '-') else any; use sort -V
  local versions stable latest
  versions=$(cat)
  [[ -z "$versions" ]] && return 1
  stable=$(printf '%s
' "$versions" | grep -Ev '\-' || true)
  if [[ -n "$stable" ]]; then
    latest=$(printf '%s
' "$stable" | sort -V | tail -n1)
  else
    latest=$(printf '%s
' "$versions" | sort -V | tail -n1)
  fi
  [[ -n "$latest" ]] && printf '%s' "$latest"
}

version_gt(){
  # returns 0 if $2 > $1
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 1
  if [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$b" ]]; then
    return 0
  fi
  return 1
}

for f in "${HR_FILES[@]}"; do
  # Extract per-doc chart info: chart|version|repoName|docIndex
  while IFS='|' read -r chart ver repo dindex; do
    [[ -z "${chart:-}" || -z "${repo:-}" || -z "${ver:-}" ]] && continue
    if [[ -z "${REPO_URL[$repo]:-}" ]]; then
      log "Repo $repo not found for $f"
      continue
    fi
    rtype="${REPO_TYPE[$repo]}"
    rurl="${REPO_URL[$repo]}"

    # Collect available versions
    available=""
    if [[ "$rtype" == "oci" ]]; then
      available="$(fetch_oci_versions "$rurl" "$chart")"
    else
      available="$(fetch_http_versions "$rurl" "$chart" || true)"
    fi
    [[ -z "$available" ]] && continue

    newver="$(printf '%s\n' "$available" | pick_latest || true)"
    [[ -z "$newver" ]] && continue

    if version_gt "$ver" "$newver"; then
      log "Update available for $chart ($repo): $ver -> $newver in $f"
      # Update the YAML in-place by matching on chart and sourceRef name
      CHART_NAME="$chart" REPO_NAME="$repo" NEWVER="$newver" \
        yq -i 'select(.kind=="HelmRelease" and .spec.chart.spec.chart == env(CHART_NAME) and .spec.chart.spec.sourceRef.name == env(REPO_NAME)).spec.chart.spec.version = strenv(NEWVER)' "$f"
      UPDATES+=("$chart|$repo|$ver|$newver|$f")
    fi
  done < <(yq -r 'select(.kind=="HelmRelease") | (.spec.chart.spec.chart + "|" + (.spec.chart.spec.version // "") + "|" + .spec.chart.spec.sourceRef.name + "|" + ("0"))' "$f" 2>/dev/null)
  # Note: The awk NR-1 hack may not map exact doc index in all cases; fallback to -d'*' select by kind works if single HR per file.
  # In practice, most files contain a single HelmRelease document. For multi-doc files, consider enhancing index detection.

done

if [[ -z "${UPDATES+x}" || ${#UPDATES[@]} -eq 0 ]]; then
  log "No chart updates available"
  exit 0
fi

# Prepare branch, commit, push, MR
BRANCH="chore/helm-bump-$(date -u +%Y%m%d%H%M%S)"

git config user.name "${GIT_AUTHOR_NAME:-${GITLAB_USER_NAME:-helm-bump-bot}}"
git config user.email "${GIT_AUTHOR_EMAIL:-helm-bump-bot@example.com}"

git checkout -B "$BRANCH"

git add apps infrastructure || true

if git diff --cached --quiet; then
  log "Nothing staged after update; aborting commit"
  exit 0
fi

COMMIT_MSG=$'chore(helm): bump charts\n\nUpdates:'
for u in "${UPDATES[@]}"; do
  IFS='|' read -r chart repo from to path <<<"$u"
  relpath=$(realpath --relative-to="${REPO_ROOT}" "$path" 2>/dev/null || echo "$path")
  COMMIT_MSG+=$"\n- ${chart} (${repo}): ${from} -> ${to} [${relpath}]"
done

git commit -m "$COMMIT_MSG"

# Push branch
git push -u origin "$BRANCH"

# Create Merge Request using CI variables if available
if [[ -n "${CI_API_V4_URL:-}" && -n "${CI_PROJECT_ID:-}" && -n "${DEPLOY_TOKEN:-}" ]]; then
  TITLE="chore(helm): bump charts"
  TARGET_BRANCH="${CI_DEFAULT_BRANCH:-main}"
  # Check if MR already exists
  if ! curl --silent --show-error --fail -H "PRIVATE-TOKEN: ${DEPLOY_TOKEN}" \
      --get "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests" \
      --data-urlencode "source_branch=${BRANCH}" --data-urlencode "state=opened" | grep -q '"iid"'; then
    curl --silent --show-error --fail -H "PRIVATE-TOKEN: ${DEPLOY_TOKEN}" \
      -X POST "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests" \
      --data-urlencode "source_branch=${BRANCH}" \
      --data-urlencode "target_branch=${TARGET_BRANCH}" \
      --data-urlencode "title=${TITLE}" \
      --data-urlencode "remove_source_branch=true" \
      >/dev/null || log "Failed to create MR"
  else
    log "MR already exists for ${BRANCH}"
  fi
else
  log "CI variables not available; skipping MR creation"
fi
