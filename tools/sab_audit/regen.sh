#!/bin/bash
# DEF-SAB-AUDIT registry regeneration + anti-staleness gate.
#
#   regen.sh           regenerate probes, re-run the matrix, rebuild
#                      registry.tsv and src/sab_audit_registry.zig.
#   regen.sh --check   snapshot the on-disk registry first, then
#                      regenerate and FAIL if either generated file
#                      differs from the snapshot (i.e. the registry
#                      is stale for this (plugin tree, sa_std tree)
#                      pair). Byte comparison, not `git diff`: the
#                      gate must also hold while the generated files
#                      are untracked in a staging tree.
#
# Inputs (the measurement assembly, see make_meas.sh):
#   SAB_AUDIT_MEAS_HOME   isolated HOME holding the installed
#                         measurement plugin (audit gate disarmed by
#                         SLA_SAB_AUDIT_MEASURE; the shipped plugin
#                         would intercept every fail-row probe with
#                         its own baked registry —
#                         DEF-SAB-AUDIT-REGEN-SELF-BLOCK).
#   SAB_AUDIT_MEAS_STD    the narrowed sa_std tree the measurement
#                         plugin is baked against (tools/sab_audit/
#                         std/README.md); becomes SA_STD_DIR and
#                         SA_SAB_STD_DIR for the matrix.
#   SAB_AUDIT_MEAS_SCI    the sci tree that std tree was built from;
#                         its git head is the registry stamp.
# Build the assembly once per (plugin tree, sci tree) pair:
#   SA_LLVM_INCLUDE_DIR=... SA_LLVM_LIB_DIR=... \
#     tools/sab_audit/make_meas.sh <scratch-dir> <sci-tree>
#   source <scratch-dir>/meas.env
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SAB_AUDIT_MEAS_HOME:?build the measurement assembly first: tools/sab_audit/make_meas.sh <scratch-dir> <sci-tree>, then source <scratch-dir>/meas.env}"
: "${SAB_AUDIT_MEAS_STD:?build the measurement assembly first: tools/sab_audit/make_meas.sh <scratch-dir> <sci-tree>, then source <scratch-dir>/meas.env}"
: "${SAB_AUDIT_MEAS_SCI:?build the measurement assembly first: tools/sab_audit/make_meas.sh <scratch-dir> <sci-tree>, then source <scratch-dir>/meas.env}"
export HOME="$SAB_AUDIT_MEAS_HOME"
export SA_STD_DIR="$SAB_AUDIT_MEAS_STD"
export SA_SAB_STD_DIR="$SAB_AUDIT_MEAS_STD"
export SLA_SAB_AUDIT_MEASURE=1
export SLA_STD_DIR="$HERE/../../sla_std"
if [ -z "${AUDIT_SA_STD_HEAD:-}" ] && [ -d "$SAB_AUDIT_MEAS_SCI/.git" ]; then
    AUDIT_SA_STD_HEAD="$(git -C "$SAB_AUDIT_MEAS_SCI" rev-parse HEAD)"
    export AUDIT_SA_STD_HEAD
fi

SNAP=""
if [ "${1:-}" = "--check" ]; then
    SNAP="$(mktemp -d)"
    cp "$HERE/registry.tsv" "$SNAP/registry.tsv"
    cp "$HERE/../../src/sab_audit_registry.zig" "$SNAP/sab_audit_registry.zig"
    echo "regen --check: snapshot taken, regenerating..."
fi

python3 "$HERE/gen_probes.py"
bash "$HERE/run_matrix.sh"
python3 "$HERE/build_registry.py"
python3 "$HERE/emit_registry_zig.py"

if [ -n "$SNAP" ]; then
    ok=1
    cmp -s "$HERE/registry.tsv" "$SNAP/registry.tsv" || { echo "regen --check: STALE — registry.tsv differs after regeneration" >&2; ok=0; }
    cmp -s "$HERE/../../src/sab_audit_registry.zig" "$SNAP/sab_audit_registry.zig" || { echo "regen --check: STALE — src/sab_audit_registry.zig differs after regeneration" >&2; ok=0; }
    rm -rf "$SNAP"
    if [ "$ok" = "1" ]; then
        echo "regen --check: PASS — registry is byte-identical after regeneration"
    else
        exit 1
    fi
fi
