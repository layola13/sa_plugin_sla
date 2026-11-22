#!/usr/bin/env bash
# task112 C-guard regression: an empty/skipped @test body reaching emission must
# be refused loudly (never emitted as a header-only hollow stub).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$REPO_ROOT/tests/task112_regression/empty_body_rejected.sla"
OUT="${TASK112_GUARD_OUT:-${TMPDIR:-/tmp}/task112_empty_body.sa}"
LOG="${TASK112_GUARD_LOG:-${TMPDIR:-/tmp}/task112_guard.log}"

if [ -f /content/tools/env.sh ]; then . /content/tools/env.sh; fi
export HOME="${OWN_HOME:-$HOME}"
export SLA_NO_FRESHNESS_CACHE=1
export SA_PLUGIN_DEV=1

rm -f "$OUT" "$LOG"
cd "$REPO_ROOT"
sa sla build "$FIXTURE" --out "$OUT" >"$LOG" 2>&1
rc=$?

if [ "$rc" -eq 0 ] && [ -f "$OUT" ]; then
    echo "FAIL: build emitted a hollow @test stub for an empty body."
    grep -n -A4 '@test' "$OUT" || true
    exit 1
fi

if grep -Fq 'refusing to emit hollow @test' "$LOG"; then
    echo "PASS: build loudly refused the empty @test body (C guard)."
    grep -F 'refusing to emit hollow @test' "$LOG"
    exit 0
fi

echo "FAIL: build failed but without the loud C guard diagnostic (rc=$rc)."
cat "$LOG"
exit 1
