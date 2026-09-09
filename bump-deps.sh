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
# Exit status is a verdict on *this repo*, not on the upstream registry
# (Issue #195). A non-zero exit means "a bump was written and it is bad --
# revert it", so an unreachable registry or a missing prerequisite tool
# must NOT exit non-zero: nothing was written, so there is nothing to
# revert, and three such exits in a row disable bumps for the repo. Those
# conditions are reported loudly on stderr, the affected action is skipped
# with its pin left untouched, and the run exits 0.
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
JQ_CMD="${BUMP_DEPS_JQ:-jq}"
# Transient registry errors (rate limit, 5xx, network blip) are retried
# before an action is skipped for the run.
API_ATTEMPTS="${BUMP_DEPS_API_ATTEMPTS:-3}"
RETRY_DELAY="${BUMP_DEPS_RETRY_DELAY_SECONDS:-2}"

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
  VIBE_BUMP_QUARANTINE_HOURS   Default quarantine window in hours (24).
  BUMP_DEPS_GH                 Override the gh binary used (test hook).
  BUMP_DEPS_JQ                 Override the jq binary used (test hook).
  BUMP_DEPS_API_ATTEMPTS       Registry attempts per lookup (3).
  BUMP_DEPS_RETRY_DELAY_SECONDS  Delay between attempts (2).

Output:
  No-op:    "OK no bumps -- actions already current"
  Skipped:  "OK no bumps -- <N> action(s) skipped" then one indented
            line per action naming the upstream error, plus a WARNING
            on stderr for each.
  Bump:     "OK bumped: <N> action(s)" then one indented diff line per
            action: "owner/repo: oldsha -> newsha (vX.Y.Z -> vA.B.C)"

Exit codes:
  0  No-op, successful bump (audit gate green), or a run where some
     actions were skipped because the registry or a prerequisite tool
     was unavailable. Nothing was written for a skipped action.
  1  A written bump was rejected by the audit gate, or an invalid flag
     was supplied. The worker should revert per VibeCoding#1613.
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

require_non_negative_integer() {
    local name="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $name must be a non-negative integer, got '$value'" >&2
        exit 1
    fi
}
require_non_negative_integer BUMP_DEPS_API_ATTEMPTS "$API_ATTEMPTS"
require_non_negative_integer BUMP_DEPS_RETRY_DELAY_SECONDS "$RETRY_DELAY"
if [ "$API_ATTEMPTS" -lt 1 ]; then
    echo "ERROR: BUMP_DEPS_API_ATTEMPTS must be at least 1, got '$API_ATTEMPTS'" >&2
    exit 1
fi

# A prerequisite missing from an unattended PATH is not a bad bump: no
# file has been touched, so warn loudly and exit 0 rather than signalling
# "revert me" to the worker (Issue #195).
MISSING_TOOL=""
if ! command -v "$GH_CMD" >/dev/null 2>&1; then
    MISSING_TOOL="$GH_CMD"
elif ! command -v "$JQ_CMD" >/dev/null 2>&1; then
    MISSING_TOOL="$JQ_CMD"
fi
if [ -n "$MISSING_TOOL" ]; then
    echo "WARNING: '$MISSING_TOOL' is not on PATH -- no dependency bump was attempted" >&2
    echo "OK no bumps -- required tool unavailable: $MISSING_TOOL"
    exit 0
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

# Last error text from the lookup helpers. Those helpers are invoked
# inside command substitutions, so the cause is passed back through a
# file rather than a variable the subshell would drop (Issue #195).
LOOKUP_ERROR_FILE="$(mktemp)"
trap 'rm -f "$LOOKUP_ERROR_FILE"' EXIT

set_lookup_error() {
    printf '%s' "$1" >"$LOOKUP_ERROR_FILE"
}

get_lookup_error() {
    cat "$LOOKUP_ERROR_FILE"
}

# Prefix the recorded cause with the caller's context, e.g.
# "failed to query the latest release (HTTP 403: rate limit exceeded)".
wrap_lookup_error() {
    local prefix="$1" cause
    cause="$(get_lookup_error)"
    set_lookup_error "${prefix} (${cause})"
}

# Call `gh api <path>`, retrying transient registry failures. Echoes the
# response body on success. On failure returns 1 and records gh's own
# diagnostic — the previous code sent it to /dev/null, which left
# operators with no way to tell a rate limit from a 404.
gh_api() {
    local path="$1"
    local attempt=1 err_file body rc api_error
    err_file="$(mktemp)"
    while :; do
        rc=0
        body=$("$GH_CMD" api "$path" 2>"$err_file") || rc=$?
        if [ "$rc" -eq 0 ]; then
            rm -f "$err_file"
            printf '%s' "$body"
            return 0
        fi
        if [ "$attempt" -ge "$API_ATTEMPTS" ]; then
            break
        fi
        attempt=$((attempt + 1))
        if [ "$RETRY_DELAY" -gt 0 ]; then
            sleep "$RETRY_DELAY"
        fi
    done
    api_error="$(tr '\n' ' ' <"$err_file" | sed 's/[[:space:]]*$//')"
    rm -f "$err_file"
    if [ -z "$api_error" ]; then
        api_error="gh exited ${rc} with no diagnostic output"
    fi
    set_lookup_error "after ${attempt} attempt(s): ${api_error}"
    return 1
}

# Actions whose upstream state could not be established this run. Their
# pins are left exactly as they are and reported, never silently dropped.
SKIP_KEYS=()
SKIP_REASONS=()
record_skip() {
    local key="$1" reason="$2" i
    for ((i=0; i<${#SKIP_KEYS[@]}; i++)); do
        if [ "${SKIP_KEYS[$i]}" = "$key" ]; then
            return 0
        fi
    done
    SKIP_KEYS+=("$key")
    SKIP_REASONS+=("$reason")
    echo "WARNING: skipping ${key} -- ${reason}" >&2
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

# Read one field out of a JSON body. Returns non-zero, recording the
# cause, when the body is not parseable — a rate-limit HTML page reaches
# jq the same way a real response does.
json_field() {
    local body="$1" filter="$2" value
    if ! value=$(printf '%s' "$body" | "$JQ_CMD" -r "$filter" 2>/dev/null); then
        set_lookup_error "unparseable response from the registry"
        return 1
    fi
    printf '%s' "$value"
}

# Resolve a tag to a 40-char commit SHA via gh. Echoes the SHA on
# success; on failure returns non-zero with the cause recorded via
# set_lookup_error.
resolve_tag_to_sha() {
    local owner="$1" repo="$2" tag="$3"
    local response sha obj_type obj_sha
    if ! response=$(gh_api "repos/${owner}/${repo}/git/refs/tags/${tag}"); then
        wrap_lookup_error "failed to resolve tag '${tag}'"
        return 1
    fi
    obj_type=$(json_field "$response" '.object.type // ""') || return 1
    obj_sha=$(json_field "$response" '.object.sha // ""') || return 1
    if [ -z "$obj_sha" ]; then
        set_lookup_error "empty SHA in the ref response for tag '${tag}'"
        return 1
    fi
    # Annotated tag — dereference to the underlying commit.
    if [ "$obj_type" = "tag" ]; then
        if ! response=$(gh_api "repos/${owner}/${repo}/git/tags/${obj_sha}"); then
            wrap_lookup_error "failed to dereference annotated tag '${tag}'"
            return 1
        fi
        sha=$(json_field "$response" '.object.sha // ""') || return 1
    else
        sha="$obj_sha"
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        set_lookup_error "invalid SHA '${sha}' for tag '${tag}'"
        return 1
    fi
    echo "$sha"
}

# Look up the latest release for a repo. Echoes "tag\tpublished_at" on
# success. On failure returns non-zero with the cause recorded via
# set_lookup_error.
lookup_latest_release() {
    local owner="$1" repo="$2"
    local response tag published_at
    if ! response=$(gh_api "repos/${owner}/${repo}/releases/latest"); then
        wrap_lookup_error "failed to query the latest release"
        return 1
    fi
    tag=$(json_field "$response" '.tag_name // ""') || return 1
    published_at=$(json_field "$response" '.published_at // ""') || return 1
    if [ -z "$tag" ] || [ -z "$published_at" ]; then
        set_lookup_error "latest release response missing tag_name/published_at"
        return 1
    fi
    # Normalise: keep tag with leading "v" intact for SHA resolution, but
    # also emit a bare "X.Y.Z" version so callers can format diffs without
    # producing "vv" by accident.
    printf '%s\t%s\n' "$tag" "$published_at"
}

# Establish the bump target for one action. Sets RESOLVED_STATE to one of:
#   yes   — RESOLVED_SHA/RESOLVED_VER hold the target to bump to
#   no    — the latest release is still inside the quarantine window
#   skip  — upstream state is unknown; RESOLVED_REASON says why
# Always returns 0: an unreachable registry is reported, not fatal.
RESOLVED_SHA=""
RESOLVED_VER=""
RESOLVED_STATE=""
RESOLVED_REASON=""
resolve_action() {
    local owner="$1" repo="$2"
    local classification release_info target_tag published_at pub_epoch
    RESOLVED_SHA=""
    RESOLVED_VER=""
    RESOLVED_STATE=""
    RESOLVED_REASON=""
    set_lookup_error ""
    classification=$(classify_owner "$owner")

    if ! release_info=$(lookup_latest_release "$owner" "$repo"); then
        RESOLVED_STATE="skip"
        RESOLVED_REASON="$(get_lookup_error)"
        return 0
    fi
    target_tag=$(echo "$release_info" | cut -f1)
    published_at=$(echo "$release_info" | cut -f2)
    # Strip a single leading "v" so downstream formatting can always
    # re-prepend it without producing "vv".
    RESOLVED_VER="${target_tag#v}"

    # Quarantine check (external only).
    if [ "$classification" = "external" ]; then
        if ! pub_epoch=$(iso_to_epoch "$published_at"); then
            RESOLVED_STATE="skip"
            RESOLVED_REASON="cannot parse published_at '${published_at}'"
            return 0
        fi
        if [ "$pub_epoch" -gt "$CUTOFF_EPOCH" ]; then
            RESOLVED_STATE="no"
            return 0
        fi
    fi

    if ! RESOLVED_SHA=$(resolve_tag_to_sha "$owner" "$repo" "$target_tag"); then
        RESOLVED_SHA=""
        RESOLVED_STATE="skip"
        RESOLVED_REASON="$(get_lookup_error)"
        return 0
    fi
    RESOLVED_STATE="yes"
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
            resolve_action "$owner" "$repo"
            target_sha="$RESOLVED_SHA"
            target_ver="$RESOLVED_VER"
            eligible="$RESOLVED_STATE"
            if [ "$eligible" = "skip" ]; then
                record_skip "$cache_key" "$RESOLVED_REASON"
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

SKIP_COUNT=${#SKIP_KEYS[@]}

print_skips() {
    local i
    for ((i=0; i<SKIP_COUNT; i++)); do
        echo "  ${SKIP_KEYS[$i]}: ${SKIP_REASONS[$i]}"
    done
}

if [ "$PLAN_COUNT" -eq 0 ]; then
    if [ "$SKIP_COUNT" -gt 0 ]; then
        # Loud, but not a failure: nothing was written, so the worker has
        # nothing to revert (Issue #195).
        echo "OK no bumps -- ${SKIP_COUNT} action(s) skipped, upstream state unknown"
        print_skips
        exit 0
    fi
    echo "OK no bumps -- actions already current"
    exit 0
fi

report_skips_if_any() {
    if [ "$SKIP_COUNT" -gt 0 ]; then
        echo "Skipped ${SKIP_COUNT} action(s), upstream state unknown:"
        print_skips
    fi
}

if [ "$DRY_RUN" = true ]; then
    echo "OK bumped: ${PLAN_COUNT} action(s) [dry-run]"
    print_diff
    report_skips_if_any
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
trap 'rm -f "$audit_log" "$LOOKUP_ERROR_FILE"' EXIT
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
report_skips_if_any
