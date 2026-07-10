#!/usr/bin/env bash
# Run the compiled test binary in small batches, each in a fresh process, so
# runtime memory is fully released between batches on memory-constrained hosts.
#
# Usage:
#   tools/run_tests_batched.sh [BATCH_SIZE]
#
# Builds the batched test binary once (serial, -j1), then invokes it repeatedly
# with SLA_TEST_START / SLA_TEST_COUNT. Exits non-zero if any batch fails.
set -uo pipefail

cd "$(dirname "$0")/.."

ZIG="${ZIG:-$HOME/.local/bin/zig}"
BATCH="${1:-5}"
BIN="zig-out/test/test"

echo "==> Building batched test binary (serial) ..."
"$ZIG" build test-batch-build -j1 || { echo "BUILD FAILED"; exit 1; }

TOTAL="$(SLA_TEST_LIST=1 "$BIN" 2>/dev/null | wc -l | tr -d ' ')"
if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
    echo "Could not enumerate tests"; exit 1
fi
echo "==> $TOTAL tests, batch size $BATCH"

fail_total=0
start=0
while [ "$start" -lt "$TOTAL" ]; do
    SLA_TEST_START="$start" SLA_TEST_COUNT="$BATCH" "$BIN"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail_total=$((fail_total + 1))
        echo "!! batch starting at $start reported failure (rc=$rc)"
    fi
    start=$((start + BATCH))
done

echo "======================================================"
if [ "$fail_total" -eq 0 ]; then
    echo "ALL BATCHES PASSED ($TOTAL tests)"
    exit 0
else
    echo "$fail_total batch(es) reported failures"
    exit 1
fi
