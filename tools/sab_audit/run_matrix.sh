#!/bin/bash
# DEF-SAB-AUDIT probe matrix runner.
#
# For every generated probe (probes/*.sla) and every backend
# (text via --test-backend sa, SAB via --test-backend sab), run the
# probe as an ordinary SLA test in a FRESH directory (no .sla-cache
# reuse; freshness cache disabled) and classify the outcome with
# four-link reading:
#   verdict=ok    requires rc=0 AND the "test result" line AND a
#                 "0 failed" reading AND no error signature.
#   verdict=fail  carries a phase (check|codegen|run|unknown) and a
#                 signature token extracted from the output.
# Raw logs land in runs/latest/ for evidence; results.tsv is the
# only output consumed downstream (build_registry.py).
#
# Requires: the MEASUREMENT plugin built from this tree installed
# and selected via SAB_AUDIT_MEAS_HOME (see regen.sh / make_meas.sh):
# the checked-in registry baked into an ordinary plugin build would
# intercept every probe whose row is fail, so the matrix would only
# ever re-measure the registry itself
# (DEF-SAB-AUDIT-REGEN-SELF-BLOCK). `sa` on PATH.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

# Measurement assembly is mandatory: without it the audit hard gate
# in the shipped plugin pre-empts the probes and the run measures
# the fossil registry, not the backends. Fail loudly instead of
# producing a plausible-but-void results.tsv.
if [ -z "${SAB_AUDIT_MEAS_HOME:-}" ] || [ -z "${SAB_AUDIT_MEAS_STD:-}" ]; then
    echo "run_matrix: REFUSING to run without a measurement assembly." >&2
    echo "run_matrix: build one with tools/sab_audit/make_meas.sh and run via tools/sab_audit/regen.sh." >&2
    exit 2
fi
export HOME="$SAB_AUDIT_MEAS_HOME"
export SA_SAB_STD_DIR="$SAB_AUDIT_MEAS_STD"
export SLA_SAB_AUDIT_MEASURE=1
# SAB fragment routing prefers the plugin-baked sa_std_source_dir
# (the measurement plugin is baked against SAB_AUDIT_MEAS_STD) over
# SA_STD_DIR; SA_STD_DIR is set for the text fragments / decl plane.
export SA_STD_DIR="$SAB_AUDIT_MEAS_STD"
export SLA_STD_DIR="$HERE/../../sla_std"
PROBES="$HERE/probes"
RUNS="$HERE/runs/latest"
rm -rf "$RUNS"
mkdir -p "$RUNS"
RESULTS="$HERE/results.tsv"
echo -e "probe_id\tbackend\tverdict\tphase\tsignature\trc" > "$RESULTS"

TOKENS="UnknownRegister|Undefined call|UnsupportedSabDirectFeature|UndefinedMacro|CodegenError|UseAfterMove|InvalidArgsCount|TypeMismatch|MemoryLeak|AmbiguousCall|UndefinedVariable|FieldNotFound|NotAStruct|InvalidBorrow|UseBeforeInit|DereferenceNonPointer|CompileError"

classify() {
    # $1=log $2=rc ; echoes "verdict phase signature"
    local log="$1" rc="$2"
    if [ "$rc" = "0" ] && grep -q "test result" "$log" && grep -q "0 failed" "$log"; then
        echo "ok - -"
        return
    fi
    local sig
    # Signature extraction, panic patterns FIRST
    # (DEF-SAB-AUDIT-REGEN-SELF-BLOCK (c)): a log can carry echoes of
    # OTHER signatures — the audit findings list quotes registry
    # signature strings verbatim, and stdout/stderr interleave — so a
    # generic error-token grep can pick an echoed old signature over
    # the cell's real one. A panic code in the log is the probe's own
    # runtime outcome and outranks every token-shaped echo.
    sig="$(grep -oE "panic: code=[0-9]+" "$log" | head -1 | sed 's/panic: code=/panic:/')"
    if [ -z "$sig" ]; then
        sig="$(grep -oE '"trap":"[A-Za-z]+"' "$log" | head -1 | sed 's/"trap":"//; s/"//')"
    fi
    if [ -z "$sig" ]; then
        sig="$(grep -oE 'error\[[A-Za-z]+' "$log" | head -1 | sed 's/error\[//')"
    fi
    if [ -z "$sig" ]; then
        # Audit-listing lines quote registry signatures; never let an
        # echo be mistaken for this cell's own failure signature.
        sig="$(grep -v '^SAB Audit: ' "$log" | grep -oE "$TOKENS" | head -1)"
    fi
    if [ -z "$sig" ]; then
        sig="$(grep -oE "panic [0-9]+|trap [0-9]+|error\.[A-Za-z]+" "$log" | head -1)"
    fi
    [ -z "$sig" ] && sig="rc$rc"
    # Phase order matters: a run failure can carry trap JSON too,
    # but only after a "test result" line exists; an assembly-stage
    # trap (generated .sa/.sab rejected) has no result line.
    local phase="unknown"
    if grep -q "Type Check Error" "$log"; then
        phase="check"
    elif grep -qE "SAB Error|Codegen Error" "$log"; then
        phase="codegen"
    elif grep -qE "test result" "$log"; then
        phase="run"
    elif grep -q '"trap":' "$log"; then
        phase="codegen"
    elif grep -qE "$TOKENS" "$log"; then
        phase="check"
    fi
    echo "fail $phase $sig"
}

for probe in "$PROBES"/*.sla; do
    pid="$(basename "$probe" .sla)"
    for spec in "text sa" "sab sab"; do
        backend="${spec%% *}"
        flag="${spec##* }"
        work="$(mktemp -d)"
        log="$RUNS/${pid}.${backend}.log"
        ( cd "$work" && SLA_NO_FRESHNESS_CACHE=1 SA_PLUGIN_DEV=1 SA_SAB_STD_DIR="$SAB_AUDIT_MEAS_STD" SLA_SAB_AUDIT_MEASURE=1 timeout 180 sa sla test "$probe" --test-backend "$flag" ) > "$log" 2>&1
        rc=$?
        read -r verdict phase sig <<< "$(classify "$log" "$rc")"
        echo -e "${pid}\t${backend}\t${verdict}\t${phase}\t${sig}\t${rc}" >> "$RESULTS"
        rm -rf "$work"
    done
done
echo "run_matrix: $(($(wc -l < "$RESULTS") - 1)) cells -> $RESULTS"
