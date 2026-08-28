#!/usr/bin/env bash
export SLA_SAB_NO_FALLBACK=1
export SA_PLUGIN_DEV=1
export SLA_SAB_TRACE_UNSUPPORTED=1
mode="${1:-all}"
pass=0; fail=0
echo "START $mode" >&2
sweep_one() {
  local f="$1"
  if sla sab build "$f" --out /tmp/_sweep_out.sab >/tmp/_sweep_err.txt 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "FAIL: $f" >&2
    grep -i "unsupported\|error" /tmp/_sweep_err.txt | head -2 >&2
  fi
}
if [ "$mode" = "tests" ] || [ "$mode" = "all" ]; then
  for f in tests/test_unit_*.sla; do [ -f "$f" ] && sweep_one "$f"; done
fi
if [ "$mode" = "rosetta" ] || [ "$mode" = "all" ]; then
  for d in demos/rosetta/*/; do
    if [ -f "${d}main.sla" ]; then sweep_one "${d}main.sla"; fi
  done
fi
echo "STRICT SWEEP ($mode): pass=$pass fail=$fail total=$((pass+fail))"
