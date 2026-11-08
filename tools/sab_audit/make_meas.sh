#!/bin/bash
# DEF-SAB-AUDIT measurement-assembly constructor.
#
#   make_meas.sh <dest-dir> <sci-root>
#
# Builds the two artifacts a registry regeneration may run against,
# in a scratch location OUTSIDE the shipped tree:
#
#   <dest-dir>/plugin-meas/   a copy of THIS plugin tree whose
#       src/plugin_compile.zig carries the measurement gate
#       (SLA_SAB_AUDIT_MEASURE, applied below from meas_gate.patch):
#       audit findings are still computed, but hard findings no
#       longer block compilation, so registry probes measure the
#       backends themselves instead of being intercepted by the
#       registry baked into the plugin under test
#       (DEF-SAB-AUDIT-REGEN-SELF-BLOCK).
#   <dest-dir>/std/   the narrowed sa_std tree the measurement
#       plugin is baked against (see tools/sab_audit/std/README.md):
#       the sa_std sources plus the sa-std-static archive built from
#       the SAME sci tree, all under <dest-dir>/std/sa_std, so the
#       plugin build bakes sa_std_source_dir at that tree (sha
#       three-step rule: compare before/after, restore nothing —
#       the shipped sci tree is never written to).
#
# The measurement plugin is built and installed into an ISOLATED
# home (<dest-dir>/home); nothing here touches the shipped plugin
# sources, the production audit gate, or the caller's HOME.
#
# Requires: zig 0.17 on PATH (or $ZIG), and an LLVM 14 devroot for
# the sci archive build (SA_LLVM_INCLUDE_DIR / SA_LLVM_LIB_DIR, the
# same flags the sci build itself takes).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_TREE="$(cd "$HERE/../.." && pwd)"
DEST="${1:?usage: make_meas.sh <dest-dir> <sci-root>}"
SCI_ROOT="$(cd "${2:?usage: make_meas.sh <dest-dir> <sci-root>}" && pwd)"
ZIG="${ZIG:-zig}"
LLVM_INC="${SA_LLVM_INCLUDE_DIR:?set SA_LLVM_INCLUDE_DIR to the llvm include dir (the one containing both llvm-c/ and llvm/)}"
LLVM_LIB="${SA_LLVM_LIB_DIR:?set SA_LLVM_LIB_DIR (dir holding libLLVM-14)}"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
MEAS="$DEST/plugin-meas"
STDROOT="$DEST/std"
MEASHOME="$DEST/home"

echo "make_meas: sci archive (sa-std-static, ReleaseFast)..."
( cd "$SCI_ROOT" && "$ZIG" build sa-std-static -Doptimize=ReleaseFast \
    -Dllvm-include-dir="$LLVM_INC" -Dllvm-lib-dir="$LLVM_LIB" )
ARCHIVE="$SCI_ROOT/zig-out/lib/libsa_std.a"
[ -f "$ARCHIVE" ] || { echo "make_meas: FAIL — $ARCHIVE not produced" >&2; exit 1; }

echo "make_meas: narrowed std tree -> $STDROOT/sa_std"
rm -rf "$STDROOT"
mkdir -p "$STDROOT/sa_std"
cp -a "$SCI_ROOT/sa_std/." "$STDROOT/sa_std/"
cp "$ARCHIVE" "$STDROOT/sa_std/libsa_std.a"

echo "make_meas: measurement plugin copy -> $MEAS"
rm -rf "$MEAS"
mkdir -p "$MEAS"
( cd "$PLUGIN_TREE" && tar --exclude='./.git' --exclude='./.zig-cache' \
    --exclude='./zig-out' --exclude='./.sla-cache' -cf - . ) | ( cd "$MEAS" && tar -xf - )
( cd "$MEAS" && patch -p1 --no-backup-if-mismatch < "$HERE/meas_gate.patch" )
grep -q "SLA_SAB_AUDIT_MEASURE" "$MEAS/src/plugin_compile.zig" || {
    echo "make_meas: FAIL — measurement gate did not land in the copy" >&2; exit 1; }
grep -q "SLA_SAB_AUDIT_MEASURE" "$PLUGIN_TREE/src/plugin_compile.zig" && {
    echo "make_meas: FAIL — shipped tree carries the measurement gate; refusing" >&2; exit 1; }

echo "make_meas: building + installing measurement plugin (isolated HOME $MEASHOME)..."
mkdir -p "$MEASHOME"
( cd "$MEAS" && rm -rf .zig-cache zig-out \
    && SCI_ROOT="$SCI_ROOT" SA_STD_DIR="$STDROOT/sa_std" "$ZIG" build )
( cd "$MEAS" && HOME="$MEASHOME" SCI_ROOT="$SCI_ROOT" SA_STD_DIR="$STDROOT/sa_std" \
    SA_PLUGIN_DEV=1 timeout 600 "$SCI_ROOT/zig-out/bin/sa" plugin install --dev . )
SO="$(find "$MEASHOME" -name 'libsla.so' -o -name 'libsla.dylib' | head -1)"
[ -n "$SO" ] || { echo "make_meas: FAIL — no installed measurement .so under $MEASHOME" >&2; exit 1; }
cmp -s "$SO" "$MEAS/zig-out/lib/libsla.so" || {
    echo "make_meas: FAIL — installed .so differs from the built one (stale install?)" >&2; exit 1; }

cat > "$DEST/meas.env" <<EOF
# Measurement assembly coordinates — source this before regen.sh.
# Produced by tools/sab_audit/make_meas.sh; do not edit by hand.
export SAB_AUDIT_MEAS_HOME="$MEASHOME"
export SAB_AUDIT_MEAS_STD="$STDROOT/sa_std"
export SAB_AUDIT_MEAS_SCI="$SCI_ROOT"
EOF
echo "make_meas: OK — plugin $SO"
echo "make_meas: std    $STDROOT/sa_std (archive sha256 $(sha256sum "$STDROOT/sa_std/libsa_std.a" | cut -d' ' -f1))"
echo "make_meas: env    $DEST/meas.env"
