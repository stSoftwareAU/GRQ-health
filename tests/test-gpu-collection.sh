#!/bin/bash
# Test for Issue #136: cross-platform GPU metric collection in run.sh.
# Extracts collect_gpu_info() and exercises it with stubbed vendor commands so
# the test is hardware-independent and cross-platform.

# The gpu_* variables are assigned by the eval'd collect_gpu_info function,
# which shellcheck cannot see, so it treats them as unassigned.
# shellcheck disable=SC2154

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"

echo "Testing Issue #136: GPU metric collection"
echo "========================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

pass_test() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_test() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Extract the collect_gpu_info function from run.sh
eval "$(sed -n '/^collect_gpu_info()/,/^}/p' "$RUN_SH")"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
REAL_PATH="$PATH"

make_stub() {
    # $1 = command name, $2 = body
    local dir="$1" name="$2" body="$3"
    mkdir -p "$dir"
    printf '#!/bin/bash\n%s\n' "$body" > "$dir/$name"
    chmod +x "$dir/$name"
}

# --- Test 1: NVIDIA host (Linux) ---
echo "Test 1: NVIDIA host populates load, VRAM, temperature and model..."
NV_BIN="$WORK_DIR/nvidia-bin"
make_stub "$NV_BIN" "nvidia-smi" 'echo "30, 2048, 8192, 65, NVIDIA GeForce RTX 3080"'
(
    OSTYPE="linux-gnu"
    PATH="$NV_BIN:$REAL_PATH"
    collect_gpu_info
    echo "$gpu_load|$gpu_memory|$gpu_breakdown|$gpu_model"
) > "$WORK_DIR/out1"
read -r OUT1 < "$WORK_DIR/out1"
if [ "$OUT1" = "30%|2048 / 8192 MB|65°C|NVIDIA GeForce RTX 3080" ]; then
    pass_test "NVIDIA fields parsed — $OUT1"
else
    fail_test "NVIDIA fields parsed — got $OUT1"
fi

# --- Test 2: No GPU host (Linux, no nvidia-smi) degrades to N/A ---
echo "Test 2: Host without a GPU degrades every field to N/A..."
EMPTY_BIN="$WORK_DIR/empty-bin"
mkdir -p "$EMPTY_BIN"
# Provide only the coreutils the function needs, not nvidia-smi.
for tool in bash echo grep sed awk tr head bc command; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$EMPTY_BIN/$tool" 2>/dev/null || true
done
(
    OSTYPE="linux-gnu"
    PATH="$EMPTY_BIN"
    collect_gpu_info
    echo "$gpu_load|$gpu_model|$gpu_cores|$gpu_memory|$gpu_breakdown"
) > "$WORK_DIR/out2"
read -r OUT2 < "$WORK_DIR/out2"
if [ "$OUT2" = "N/A|N/A|N/A|N/A|N/A" ]; then
    pass_test "no-GPU host all N/A — $OUT2"
else
    fail_test "no-GPU host all N/A — got $OUT2"
fi

# --- Test 3: Apple Silicon host via ioreg + system_profiler ---
echo "Test 3: Apple Silicon populates load, memory, model and core count..."
MAC_BIN="$WORK_DIR/mac-bin"
# ioreg reports PerformanceStatistics as one line; include the (driver) decoy
# and a trailing "In use system memory" to mirror the real format.
make_stub "$MAC_BIN" "ioreg" 'echo "      \"PerformanceStatistics\" = {\"In use system memory (driver)\"=0,\"Device Utilization %\"=45,\"In use system memory\"=2684354560}"'
make_stub "$MAC_BIN" "system_profiler" 'cat <<EOF
    Chipset Model: Apple M2 Pro
    Total Number of Cores: 19
EOF'
(
    OSTYPE="darwin23"
    PATH="$MAC_BIN:$REAL_PATH"
    collect_gpu_info
    echo "$gpu_load|$gpu_memory|$gpu_model|$gpu_cores"
) > "$WORK_DIR/out3"
read -r OUT3 < "$WORK_DIR/out3"
if [ "$OUT3" = "45%|2.50 GB in use|Apple M2 Pro|19" ]; then
    pass_test "Apple Silicon fields parsed — $OUT3"
else
    fail_test "Apple Silicon fields parsed — got $OUT3"
fi

# --- Test 4: Apple Silicon missing Device Utilization key falls back to N/A load ---
echo "Test 4: Apple host missing utilisation key shows N/A load but keeps model..."
MAC_BIN2="$WORK_DIR/mac-bin2"
make_stub "$MAC_BIN2" "ioreg" 'echo "      \"PerformanceStatistics\" = {\"Alloc system memory\"=927285248}"'
make_stub "$MAC_BIN2" "system_profiler" 'cat <<EOF
    Chipset Model: Apple M1
    Total Number of Cores: 8
EOF'
(
    # Run under the same flags as run.sh — a no-match grep must NOT abort.
    set -euo pipefail
    OSTYPE="darwin23"
    PATH="$MAC_BIN2:$REAL_PATH"
    collect_gpu_info
    echo "$gpu_load|$gpu_model|$gpu_cores"
) > "$WORK_DIR/out4"
read -r OUT4 < "$WORK_DIR/out4"
if [ "$OUT4" = "N/A|Apple M1|8" ]; then
    pass_test "graceful N/A load with known model — $OUT4"
else
    fail_test "graceful N/A load with known model — got $OUT4"
fi

echo ""
echo "========================================="
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
