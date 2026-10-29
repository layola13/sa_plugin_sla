#!/usr/bin/env bash
# Run the plugin test suite through the batch test binary's supervisor mode:
# the binary is built once, then supervises one worker process per test with
# a configurable number of concurrent workers, a hard per-test timeout, and
# an incrementally journaled result set (a killed run resumes where it left
# off when re-run with the same SLA_TEST_RESULTS file).
#
# Usage:
#   tools/run_tests_supervised.sh [JOBS]
#
# Environment:
#   ZIG                 zig binary (default: $HOME/.local/bin/zig)
#   JOBS / SLA_TEST_JOBS        concurrent workers (default: 4)
#   SLA_TEST_TIMEOUT_MS         per-test timeout (default: 60000)
#   SLA_TEST_RESULTS            journal path (default: ./test-results.journal)
#   SLA_TEST_LOG                ordered verdict log path (default: ./test-results.log)
#   SLA_TEST_SERIAL             comma-separated name substrings forced serial
#   SLA_TEST_SERIAL_FILE        file with one serial substring per line
#   SLA_TEST_START / SLA_TEST_COUNT   window selection
#
# The verdict log uses the segment-6 format: "TOTAL <n>", then per index
# "PASS <i>" / "FAIL <i> <i>\t<name> rc=<rc>" / "HANG <i> <i>\t<name>", then
# "DONE". Exit code is non-zero if any test fails or hangs.
set -uo pipefail

cd "$(dirname "$0")/.."

ZIG="${ZIG:-$HOME/.local/bin/zig}"
export SLA_TEST_JOBS="${1:-${SLA_TEST_JOBS:-4}}"
export SLA_TEST_RESULTS="${SLA_TEST_RESULTS:-./test-results.journal}"
export SLA_TEST_LOG="${SLA_TEST_LOG:-./test-results.log}"

echo "==> Building batched test binary (serial) ..."
"$ZIG" build test-batch-build -j1 || { echo "BUILD FAILED"; exit 1; }

echo "==> Supervised run: jobs=$SLA_TEST_JOBS results=$SLA_TEST_RESULTS log=$SLA_TEST_LOG"
./zig-out/test/test
