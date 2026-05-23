#!/bin/bash
# Test for Issue #133: Service worker and HTML cache busters must match
# run.sh VERSION so threshold/code changes (e.g. Issue #131) are picked up
# by clients with the PWA installed instead of being masked by a stale
# cached dashboard.js.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Testing Issue #133: client cache-buster version consistency"
echo "==========================================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail_test() {
    echo "  FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

VERSION_RUN_SH=$(grep '^VERSION=' "$ROOT_DIR/run.sh" | head -1 | cut -d'"' -f2)
if [ -z "$VERSION_RUN_SH" ]; then
    fail_test "could not read VERSION from run.sh"
    exit 1
fi
echo "  run.sh VERSION = $VERSION_RUN_SH"
echo ""

# dashboard.js — VERSION constant
DASH_VER=$(grep '^const VERSION = ' "$ROOT_DIR/docs/dashboard.js" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ "$DASH_VER" = "$VERSION_RUN_SH" ]; then
    pass_test "dashboard.js const VERSION matches run.sh ($DASH_VER)"
else
    fail_test "dashboard.js const VERSION ($DASH_VER) != run.sh ($VERSION_RUN_SH)"
fi

# sw.js — comment, CACHE_NAME, STATIC_CACHE_NAME, dashboard.js?v= cache buster
SW_COMMENT=$(grep '^// Version:' "$ROOT_DIR/docs/sw.js" | head -1 | awk '{print $3}')
if [ "$SW_COMMENT" = "$VERSION_RUN_SH" ]; then
    pass_test "sw.js // Version comment matches run.sh ($SW_COMMENT)"
else
    fail_test "sw.js // Version comment ($SW_COMMENT) != run.sh ($VERSION_RUN_SH)"
fi

SW_CACHE=$(grep "^const CACHE_NAME" "$ROOT_DIR/docs/sw.js" | head -1 | sed "s/.*'grq-health-v\([0-9.]*\)'.*/\1/")
if [ "$SW_CACHE" = "$VERSION_RUN_SH" ]; then
    pass_test "sw.js CACHE_NAME matches run.sh ($SW_CACHE)"
else
    fail_test "sw.js CACHE_NAME ($SW_CACHE) != run.sh ($VERSION_RUN_SH) — stale cache will be served"
fi

SW_STATIC=$(grep "^const STATIC_CACHE_NAME" "$ROOT_DIR/docs/sw.js" | head -1 | sed "s/.*'grq-health-static-v\([0-9.]*\)'.*/\1/")
if [ "$SW_STATIC" = "$VERSION_RUN_SH" ]; then
    pass_test "sw.js STATIC_CACHE_NAME matches run.sh ($SW_STATIC)"
else
    fail_test "sw.js STATIC_CACHE_NAME ($SW_STATIC) != run.sh ($VERSION_RUN_SH) — stale static cache will be served"
fi

SW_DASH=$(grep "dashboard\.js?v=" "$ROOT_DIR/docs/sw.js" | head -1 | sed "s/.*dashboard\.js?v=\([0-9.]*\)['\"].*/\1/")
if [ "$SW_DASH" = "$VERSION_RUN_SH" ]; then
    pass_test "sw.js dashboard.js?v= cache buster matches run.sh ($SW_DASH)"
else
    fail_test "sw.js dashboard.js?v= ($SW_DASH) != run.sh ($VERSION_RUN_SH)"
fi

# index.html — three cache busters
for asset in "styles.css" "dashboard.js" "sw.js"; do
    HTML_VER=$(grep "${asset}?v=" "$ROOT_DIR/docs/index.html" | head -1 | sed "s/.*${asset}?v=\([0-9.]*\).*/\1/")
    if [ "$HTML_VER" = "$VERSION_RUN_SH" ]; then
        pass_test "index.html ${asset}?v= matches run.sh ($HTML_VER)"
    else
        fail_test "index.html ${asset}?v= ($HTML_VER) != run.sh ($VERSION_RUN_SH) — clients will load stale ${asset}"
    fi
done

echo ""
echo "==========================================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
