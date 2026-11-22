#!/usr/bin/env bash
# task112 fail-before / pass-after regression harness.
#
# Bug: the artifact-emitting build path parses SLA with parse_test_bodies=false,
# so @test bodies are hollowed to an empty statement list. A must-fail assertion
# inside @test silently disappears -> the emitted .sa carries a hollow stub.
#
# This harness asserts the FIXED behaviour, so it FAILS on the buggy plugin and
# PASSES once B+C lands. Two acceptable fixed outcomes:
#   1. B: the emitted .sa carries the must-fail assertion (real body), or
#   2. C: the build loudly refuses to emit a skipped @test body.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$REPO_ROOT/tests/task112_regression/hollow_body_sentinel.sla"
SENTINEL='112112'
OUT="${TASK112_OUT:-${TMPDIR:-/tmp}/task112_hollow_body_sentinel.sa}"
LOG="${TASK112_LOG:-${TMPDIR:-/tmp}/task112_build.log}"

if [ -f /content/tools/env.sh ]; then . /content/tools/env.sh; fi
export HOME="${OWN_HOME:-$HOME}"
export SLA_NO_FRESHNESS_CACHE=1
# Dev-mode install is the only supported mode on this host (formal mode needs
# an enforced sandbox). The Zig plugin build itself was done with
# `env -u SA_PLUGIN_DEV`; only these `sa sla` invocations need dev mode.
export SA_PLUGIN_DEV=1

rm -f "$OUT" "$LOG"
cd "$REPO_ROOT"
sa sla build "$FIXTURE" --out "$OUT" >"$LOG" 2>&1
rc=$?

if [ "$rc" -ne 0 ]; then
    if grep -Eqi 'hollow|skipped|empty body|test body|refus' "$LOG"; then
        echo "PASS: build loudly refused a hollow @test body (C guard)."
        echo "--- build log ---"
        cat "$LOG"
        exit 0
    fi
    echo "FAIL: build failed for an unrelated reason (rc=$rc)."
    echo "--- build log ---"
    cat "$LOG"
    exit 1
fi

if grep -F "$SENTINEL" "$OUT" >/dev/null 2>&1; then
    echo "PASS: emitted @test body carries the must-fail assertion (not hollow)."
    exit 0
fi

echo "FAIL: emitted @test body is HOLLOW (must-fail assertion missing) -> false-green bug reproduced."
echo "--- emitted @test block ---"
grep -n -A6 '@test' "$OUT" || true
exit 1
