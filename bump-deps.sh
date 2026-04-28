#!/usr/bin/env bash
# bump-deps.sh — refresh GitHub Action SHAs in .github/workflows/*.yml.
#
# Walks every `uses: <owner>/<repo>@<sha> # vX.Y.Z` line in the workflow
# files, classifies each action as internal (stSoftwareAU/*) or external,
# and rewrites pinned SHAs to the latest release/tag's commit SHA.
#
# External actions are quarantined: a release is only eligible once it is
# at least VIBE_BUMP_QUARANTINE_HOURS old (default 24h). Internal actions
# bump immediately. After applying bumps the script runs ./quality.sh as
# the audit gate; any failure prints the offending bump diff and exits
# non-zero so the worker can revert per VibeCoding#1613.
#
# Cross-platform: must run on macOS bash 3.2 — empty-array expansions are
# guarded with ${arr[@]+"${arr[@]}"}, no GNU-only flags are used.

set -euo pipefail

# Operate on the current working directory so tests can invoke the
# script from a sandbox containing fixture workflow files.
QUARANTINE_HOURS="${VIBE_BUMP_QUARANTINE_HOURS:-24}"
DRY_RUN=false
WORKFLOW_DIR=".github/workflows"
QUALITY_CMD="./quality.sh"
GH_CMD="${BUMP_DEPS_GH:-gh}"

show_help() {
    cat <<'HELP'
Usage: ./bump-deps.sh [OPTIONS]

Refresh GitHub Action commit SHAs in .github/workflows/*.yml, then run
./quality.sh as the audit gate. Designed to be invoked by the Vibe Coder
worker before quality.sh per the VibeCoding#1613 contract.

Internal vs external classification:
  - Internal: actions under stSoftwareAU/* — bump immediately.
  - External: everything else — only bump to releases older than
    VIBE_BUMP_QUARANTINE_HOURS (default 24h, env-overridable).

Options:
  --dry-run                 Print planned bumps without writing files.
                            Audit gate is skipped.
  --quarantine-hours <H>    Override VIBE_BUMP_QUARANTINE_HOURS for this
                            run. Must be a non-negative integer.
  --help, -h                Show this help and exit.

Environment:
  VIBE_BUMP_QUARANTINE_HOURS  Default quarantine window in hours (24).
  BUMP_DEPS_GH                Override the gh binary used (test hook).

Output:
  No-op:    "OK no bumps -- actions already current"
  Bump:     "OK bumped: <N> action(s)" then one indented diff line per
            action: "owner/repo: oldsha -> newsha (vX.Y.Z -> vA.B.C)"

Exit codes:
  0  No-op or successful bump (audit gate green).
  1  Bump rejected by audit gate, invalid flag, or upstream lookup
     failure. The worker should revert per VibeCoding#1613.
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --quarantine-hours)
            if [ $# -lt 2 ]; then
                echo "ERROR: --quarantine-hours requires a non-negative integer" >&2
                exit 1
            fi
            QUARANTINE_HOURS="$2"
            shift 2
            ;;
        --quarantine-hours=*)
            QUARANTINE_HOURS="${1#--quarantine-hours=}"
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            echo "Run './bump-deps.sh --help' for usage." >&2
            exit 1
            ;;
    esac
done

if ! [[ "$QUARANTINE_HOURS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: quarantine hours must be a non-negative integer, got '$QUARANTINE_HOURS'" >&2
    exit 1
fi

if ! command -v "$GH_CMD" >/dev/null 2>&1; then
    echo "ERROR: '$GH_CMD' is required on PATH" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is required on PATH" >&2
    exit 1
fi

# Convert ISO-8601 (YYYY-MM-DDTHH:MM:SSZ) to epoch seconds. Tries GNU
# date first, then BSD date (macOS).
iso_to_epoch() {
    local iso="$1"
    local epoch
    if epoch=$(date -d "$iso" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi
    if epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi
    return 1
}

# Classify owner — "internal" for stSoftwareAU, "external" otherwise.
classify_owner() {
    local owner="$1"
    if [ "$owner" = "stSoftwareAU" ]; then
        echo "internal"
    else
        echo "external"
    fi
}

# Resolve a tag to a 40-char commit SHA via gh. Echoes the SHA on
# success, returns non-zero on failure.
resolve_tag_to_sha() {
    local owner="$1" repo="$2" tag="$3"
    local response sha obj_type obj_sha
    if ! response=$("$GH_CMD" api "repos/${owner}/${repo}/git/refs/tags/${tag}" 2>/dev/null); then
        echo "ERROR: failed to resolve tag '${tag}' for ${owner}/${repo}" >&2
        return 1
    fi
    obj_type=$(echo "$response" | jq -r '.object.type // ""')
    obj_sha=$(echo "$response" | jq -r '.object.sha // ""')
    if [ -z "$obj_sha" ]; then
        echo "ERROR: empty SHA in ref response for ${owner}/${repo}@${tag}" >&2
        return 1
    fi
    # Annotated tag — dereference to the underlying commit.
    if [ "$obj_type" = "tag" ]; then
        if ! response=$("$GH_CMD" api "repos/${owner}/${repo}/git/tags/${obj_sha}" 2>/dev/null); then
            echo "ERROR: failed to dereference annotated tag for ${owner}/${repo}@${tag}" >&2
            return 1
        fi
        sha=$(echo "$response" | jq -r '.object.sha // ""')
    else
        sha="$obj_sha"
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ERROR: invalid SHA '$sha' for ${owner}/${repo}@${tag}" >&2
        return 1
    fi
    echo "$sha"
}

# Look up the latest release for a repo. Echoes "tag\tpublished_at" on
# success. Returns non-zero on lookup failure.
lookup_latest_release() {
    local owner="$1" repo="$2"
    local response tag published_at
    if ! response=$("$GH_CMD" api "repos/${owner}/${repo}/releases/latest" 2>/dev/null); then
        echo "ERROR: failed to query latest release for ${owner}/${repo}" >&2
        return 1
    fi
    tag=$(echo "$response" | jq -r '.tag_name // ""')
    published_at=$(echo "$response" | jq -r '.published_at // ""')
    if [ -z "$tag" ] || [ -z "$published_at" ]; then
        echo "ERROR: latest release for ${owner}/${repo} missing tag/published_at" >&2
        return 1
    fi
    # Normalise: keep tag with leading "v" intact for SHA resolution, but
    # also emit a bare "X.Y.Z" version so callers can format diffs without
    # producing "vv" by accident.
    printf '%s\t%s\n' "$tag" "$published_at"
}

# Plan storage: parallel arrays indexed by plan-entry. bash 3.2 has no
# associative arrays, so we use plain arrays.
PLAN_FILE=()      # which workflow file the bump applies to
PLAN_OWNER=()
PLAN_REPO=()
PLAN_OLD_SHA=()
PLAN_NEW_SHA=()
PLAN_OLD_VER=()
PLAN_NEW_VER=()

# Cutoff epoch — releases newer than this are quarantined.
NOW_EPOCH=$(date -u +%s)
CUTOFF_EPOCH=$((NOW_EPOCH - QUARANTINE_HOURS * 3600))

# Walk each workflow file.
shopt -s nullglob
WORKFLOW_FILES=("$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml)
shopt -u nullglob

if [ ${#WORKFLOW_FILES[@]} -eq 0 ]; then
    echo "OK no bumps -- actions already current"
    exit 0
fi

# Track unique action keys we have already processed in this run so we
# don't re-query gh for actions/checkout used in five workflows.
SEEN_KEYS=()
seen_key() {
    local key="$1" k
    if [ ${#SEEN_KEYS[@]} -eq 0 ]; then
        return 1
    fi
    for k in ${SEEN_KEYS[@]+"${SEEN_KEYS[@]}"}; do
        if [ "$k" = "$key" ]; then
            return 0
        fi
    done
    return 1
}

# Cache resolved (target_sha, target_version, eligible) per owner/repo.
CACHE_KEYS=()
CACHE_TARGET_SHA=()
CACHE_TARGET_VER=()
CACHE_ELIGIBLE=()
cache_lookup() {
    local key="$1" i
    if [ ${#CACHE_KEYS[@]} -eq 0 ]; then
        return 1
    fi
    for ((i=0; i<${#CACHE_KEYS[@]}; i++)); do
        if [ "${CACHE_KEYS[$i]}" = "$key" ]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

for wf in ${WORKFLOW_FILES[@]+"${WORKFLOW_FILES[@]}"}; do
    # Each `uses:` line might or might not carry a trailing version comment.
    # Collect them line-by-line so we can rewrite the file in-place later.
    while IFS= read -r line; do
        # Match `uses: owner/repo@<40-char-sha>` with optional `# vX.Y.Z` comment.
        if [[ "$line" =~ uses:[[:space:]]*([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)@([0-9a-f]{40})([[:space:]]+#[[:space:]]*v([0-9]+(\.[0-9]+){0,2}))? ]]; then
            owner="${BASH_REMATCH[1]}"
            repo="${BASH_REMATCH[2]}"
            old_sha="${BASH_REMATCH[3]}"
            old_ver="${BASH_REMATCH[5]:-}"
        else
            continue
        fi

        cache_key="${owner}/${repo}"
        if cache_idx=$(cache_lookup "$cache_key"); then
            target_sha="${CACHE_TARGET_SHA[$cache_idx]}"
            target_ver="${CACHE_TARGET_VER[$cache_idx]}"
            eligible="${CACHE_ELIGIBLE[$cache_idx]}"
        else
            classification=$(classify_owner "$owner")

            if ! release_info=$(lookup_latest_release "$owner" "$repo"); then
                exit 1
            fi
            target_tag=$(echo "$release_info" | cut -f1)
            published_at=$(echo "$release_info" | cut -f2)
            # Strip a single leading "v" so downstream formatting can
            # always re-prepend it without producing "vv".
            target_ver="${target_tag#v}"

            # Quarantine check (external only).
            eligible="yes"
            if [ "$classification" = "external" ]; then
                if pub_epoch=$(iso_to_epoch "$published_at"); then
                    if [ "$pub_epoch" -gt "$CUTOFF_EPOCH" ]; then
                        eligible="no"
                    fi
                else
                    echo "ERROR: cannot parse published_at '$published_at' for ${owner}/${repo}" >&2
                    exit 1
                fi
            fi

            if [ "$eligible" = "yes" ]; then
                if ! target_sha=$(resolve_tag_to_sha "$owner" "$repo" "$target_tag"); then
                    exit 1
                fi
            else
                target_sha=""
            fi

            CACHE_KEYS+=("$cache_key")
            CACHE_TARGET_SHA+=("$target_sha")
            CACHE_TARGET_VER+=("$target_ver")
            CACHE_ELIGIBLE+=("$eligible")
        fi

        if [ "$eligible" != "yes" ]; then
            continue
        fi

        if [ "$target_sha" = "$old_sha" ]; then
            continue
        fi

        PLAN_FILE+=("$wf")
        PLAN_OWNER+=("$owner")
        PLAN_REPO+=("$repo")
        PLAN_OLD_SHA+=("$old_sha")
        PLAN_NEW_SHA+=("$target_sha")
        PLAN_OLD_VER+=("$old_ver")
        PLAN_NEW_VER+=("$target_ver")

        seen_key "${owner}/${repo}@${old_sha}" || SEEN_KEYS+=("${owner}/${repo}@${old_sha}")
    done < "$wf"
done

PLAN_COUNT=${#PLAN_FILE[@]}

print_diff() {
    local i owner repo old_sha new_sha old_ver new_ver line
    for ((i=0; i<PLAN_COUNT; i++)); do
        owner="${PLAN_OWNER[$i]}"
        repo="${PLAN_REPO[$i]}"
        old_sha="${PLAN_OLD_SHA[$i]}"
        new_sha="${PLAN_NEW_SHA[$i]}"
        old_ver="${PLAN_OLD_VER[$i]}"
        new_ver="${PLAN_NEW_VER[$i]}"
        if [ -n "$old_ver" ] || [ -n "$new_ver" ]; then
            line="  ${owner}/${repo}: ${old_sha} -> ${new_sha} (v${old_ver:-?} -> v${new_ver})"
        else
            line="  ${owner}/${repo}: ${old_sha} -> ${new_sha}"
        fi
        echo "$line"
    done
}

if [ "$PLAN_COUNT" -eq 0 ]; then
    echo "OK no bumps -- actions already current"
    exit 0
fi

if [ "$DRY_RUN" = true ]; then
    echo "OK bumped: ${PLAN_COUNT} action(s) [dry-run]"
    print_diff
    exit 0
fi

# Apply the bumps. Rewrite each unique workflow file once by feeding it
# through awk/sed-friendly bash substitutions per plan entry.
APPLIED_FILES=()
file_seen() {
    local f="$1" x
    if [ ${#APPLIED_FILES[@]} -eq 0 ]; then
        return 1
    fi
    for x in ${APPLIED_FILES[@]+"${APPLIED_FILES[@]}"}; do
        [ "$x" = "$f" ] && return 0
    done
    return 1
}

for ((i=0; i<PLAN_COUNT; i++)); do
    wf="${PLAN_FILE[$i]}"
    owner="${PLAN_OWNER[$i]}"
    repo="${PLAN_REPO[$i]}"
    old_sha="${PLAN_OLD_SHA[$i]}"
    new_sha="${PLAN_NEW_SHA[$i]}"
    new_ver="${PLAN_NEW_VER[$i]}"

    # Replace SHA on the matching uses: line, and rewrite the trailing
    # version comment in lock-step. Use awk for portability.
    tmp="$(mktemp)"
    awk -v owner="$owner" -v repo="$repo" -v old_sha="$old_sha" \
        -v new_sha="$new_sha" -v new_ver="$new_ver" '
    {
        line = $0
        prefix = "uses: " owner "/" repo "@"
        idx = index(line, prefix)
        if (idx > 0 && index(line, old_sha) > 0) {
            head = substr(line, 1, idx - 1)
            rest = substr(line, idx)
            # Replace the SHA.
            sub(old_sha, new_sha, rest)
            # Replace any existing trailing # vX.Y.Z comment with new_ver,
            # or append one if absent.
            if (rest ~ /#[[:space:]]*v[0-9]+(\.[0-9]+){0,2}/) {
                sub(/#[[:space:]]*v[0-9]+(\.[0-9]+){0,2}/, "# v" new_ver, rest)
            } else {
                rest = rest " # v" new_ver
            }
            print head rest
            next
        }
        print line
    }
    ' "$wf" > "$tmp"
    mv "$tmp" "$wf"

    file_seen "$wf" || APPLIED_FILES+=("$wf")
done

# Audit gate.
echo "Audit gate: running ${QUALITY_CMD}..."
audit_log="$(mktemp)"
trap 'rm -f "$audit_log"' EXIT
if ! "$QUALITY_CMD" >"$audit_log" 2>&1 < /dev/null; then
    cat "$audit_log" >&2 || true
    echo "" >&2
    echo "ERROR: ${QUALITY_CMD} failed after dependency bumps." >&2
    echo "Offending bump(s):" >&2
    print_diff >&2
    echo "Worker should revert per VibeCoding#1613." >&2
    exit 1
fi

echo "OK bumped: ${PLAN_COUNT} action(s)"
print_diff
