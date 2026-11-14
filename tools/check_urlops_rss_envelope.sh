#!/bin/bash
# Regression check for DEF-SAB-URLOPS: tests/test_unit_reg4_url_ops.sla
# via the SAB test route under a 1 GB peak-RSS envelope.
#
#   RED  pre-fix: the `sa sla test` command ran the whole compile inside
#        a per-command ArenaAllocator that never frees, so this file's
#        SAB compile peaked ~3.96 GB RSS and the envelope kills it
#        (exit 137).
#   GREEN post-fix (test command on a freeing allocator): rc=0,
#        "test result: ok. 9 passed; 0 failed; 0 skipped", peak << 1 GB.
#
# Four-part verdict: rc + result line + failure name set (must be
# empty, i.e. the ok line) + SAB backend specifically (the text
# backend is a different allocator path and out of scope).
#
# Run from the sa_plugin_sla repo root, with the plugin under test
# installed into the active HOME (SA_PLUGIN_DEV=1) and `sa` on PATH
# (override with SA_BIN). Cold caches are enforced for the three
# test-side surfaces (.sla-cache, frontend cache, per-dir .sa_cache).
set -u
CAP_MB=1024
SA_BIN="${SA_BIN:-sa}"
export SA_PLUGIN_DEV=1
export SLA_NO_FRESHNESS_CACHE=1
export SA_SLA_FIXTURE_DIR="$PWD/tests/import_fixtures/"
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$PWD/.sla-cache" "$HOME/.cache/sa/frontend"
find "$PWD" -type d -name .sa_cache -prune -exec rm -rf {} + 2>/dev/null
OUT="$(mktemp -t urlops_envelope.XXXXXX.out)"
python3 "$TOOLS_DIR/rss_envelope_run.py" "$CAP_MB" "$OUT" \
  "$SA_BIN" sla test tests/test_unit_reg4_url_ops.sla --test-backend sab
rc=$?
echo "ENVELOPE_RC=$rc"
grep -E "test result" "$OUT" | tail -1 || true
if [ "$rc" -ne 0 ]; then
  echo "CHECK_FAIL rc=$rc (137 = envelope exceeded)"
  exit 1
fi
if ! grep -q "test result: ok. 9 passed; 0 failed; 0 skipped" "$OUT"; then
  echo "CHECK_FAIL result line mismatch"
  exit 1
fi
echo "CHECK_PASS url_ops SAB within ${CAP_MB} MB envelope"
