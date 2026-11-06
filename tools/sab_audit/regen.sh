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
# SA_STD_DIR must point at the sa_std tree the probes compile
# against; AUDIT_SA_STD_HEAD should carry that tree's git head (the
# registry stamp). The dev plugin must be installed from this tree.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
export SA_STD_DIR="${SA_STD_DIR:?SA_STD_DIR must name the sa_std tree the probes compile against}"
if [ -z "${AUDIT_SA_STD_HEAD:-}" ] && [ -d "$(dirname "$SA_STD_DIR")/.git" ]; then
    AUDIT_SA_STD_HEAD="$(git -C "$(dirname "$SA_STD_DIR")" rev-parse HEAD)"
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
