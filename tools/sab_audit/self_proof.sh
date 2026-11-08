#!/bin/bash
# DEF-SAB-AUDIT independent-driver self-proof.
#
# Builds src/sab_audit_driver.zig (which exercises src/sab_audit.zig
# WITHOUT any pipeline wiring) and asserts, over the checked sample
# programs in samples/:
#
#  1. sample_good (only registry-green surfaces, incl. a chained
#     iter().sum()): audit finds NOTHING, exit 0.
#  2. sample_gaps in production mode: the surfaces this sample
#     exercises (held iterator, the Vec iter/sum chain, the
#     HashMap/BTreeMap insert family, HashMap.len, Vec.push,
#     panic) were the poisoned d31faea6-pairing snapshot false
#     gaps. On the healthy pairing (DEF-SAB-REGISTRY-POISONED-
#     REGEN regeneration) every one measures ok on both
#     backends, so the audit must now find NOTHING here, exit
#     0 — and any future regression that re-breaks one of them
#     reappears as a finding and fails this proof. (One-pass
#     listing of hard findings is exercised again as soon as a
#     sample uses a symbol whose regenerated row carries a
#     real failure, e.g. the MAP_KEYS family; re-pin a sample
#     to one of those if listing coverage is wanted back.)
#  3. sample_gaps in mirror mode: same healed state — no
#     findings on either target set, exit 0.
#  4. sample_using in lenient mode: post-E0 the checker accepts
#     the `using` surface, the audit lists the extension symbols
#     i32.double / i32.add_offset as plain uses with no findings,
#     exit 0. (Pre-E0 this asserted checker rejection, exit 4.)
#
# Expectations are keyed to the checked-in registry
# (tools/sab_audit/registry.tsv @ the stamped head pair); if a
# future fix turns a gap green, regenerate the registry and update
# the affected assertion — that diff is the review surface.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export SCI_ROOT="${SCI_ROOT:-/content/sa_all/sci}"
DRIVER="$HERE/.driver_out/bin/sab_audit_driver"

zig build --build-file "$HERE/driver_build/build.zig" -Dsci-root="$SCI_ROOT" \
    -p "$HERE/.driver_out" --cache-dir "$HERE/.driver_cache" > /dev/null || {
    echo "SELF-PROOF FAIL: driver build"; exit 1; }

fail=0
note() { echo "self_proof: $1"; }
expect_rc() { # name expected actual
    if [ "$2" != "$3" ]; then note "FAIL $1: exit $3, want $2"; fail=1; fi
}
expect_has() { # name file pattern
    if ! grep -qF "$3" "$2"; then note "FAIL $1: missing: $3"; fail=1; fi
}
expect_lacks() { # name file pattern
    if grep -qF "$3" "$2"; then note "FAIL $1: unexpected: $3"; fail=1; fi
}

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# 1. good surfaces stay silent
"$DRIVER" "$HERE/samples/sample_good.sla" both > "$W/good.out" 2>&1
expect_rc good 0 $?
expect_has good "$W/good.out" "SUMMARY uses=5 findings=0 hard=0"
expect_lacks good "$W/good.out" "FINDING"

# 2. gaps sample, production targets: every surface in this
#    sample measured ok/ok in the healthy-pairing regeneration
#    (DEF-SAB-REGISTRY-POISONED-REGEN); the audit must be silent.
"$DRIVER" "$HERE/samples/sample_gaps.sla" production > "$W/gaps.out" 2>&1
expect_rc gaps-production 0 $?
expect_has gaps-production "$W/gaps.out" "SUMMARY uses=9 findings=0 hard=0"
expect_lacks gaps-production "$W/gaps.out" "FINDING"

# 3. gaps sample, mirror targets: same healed state, silent.
"$DRIVER" "$HERE/samples/sample_gaps.sla" mirror > "$W/gaps_mirror.out" 2>&1
expect_rc gaps-mirror 0 $?
expect_has gaps-mirror "$W/gaps_mirror.out" "SUMMARY uses=9 findings=0 hard=0"
expect_lacks gaps-mirror "$W/gaps_mirror.out" "FINDING"

# 4. using: post-E0 the checker accepts; audit lists the extension
#    symbols as plain uses and finds nothing (exit 0)
"$DRIVER" "$HERE/samples/sample_using.sla" both --lenient > "$W/using.out" 2>&1
expect_rc using-lenient 0 $?
for pat in \
    "USE i32.add_offset method" \
    "USE i32.double method" \
    "SUMMARY uses=3 findings=0 hard=0" \
    "check_ok=true"; do
    expect_has using-lenient "$W/using.out" "$pat"
done
expect_lacks using-lenient "$W/using.out" "FINDING"

if [ "$fail" = "0" ]; then
    echo "SELF-PROOF PASS"
else
    echo "SELF-PROOF FAIL (outputs in $W — removed on exit; rerun pieces manually)"
    exit 1
fi
