#!/usr/bin/env bash
# Strict-mode SAB direct-codegen sweep for fallback-zeroing.
# Usage: tools/strict_sweep.sh [tests|rosetta|all]
set -u
export SLA_SAB_NO_FALLBACK=1
export SA_PLUGIN_DEV=1
export SLA_SAB_TRACE_UNSUPPORTED=1

mode="${1:-all}"
pass=0; fail=0
fail_list=()

sweep_one() {
  local f="$1"
  if sla sab build "$f" --out /tmp/_sweep_out.sab >/tmp/_sweep_err.txt 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    fail_list+=("$f")
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

echo "=========================================="
echo "STRICT SWEEP ($mode): pass=$pass fail=$fail total=$((pass+fail))"
if [ "${#fail_list[@]}" -gt 0 ]; then
  echo "---- FAILURES ----"
  for f in "${fail_list[@]}"; do echo "$f"; done
fi
