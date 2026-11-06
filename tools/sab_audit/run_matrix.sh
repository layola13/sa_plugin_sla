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
# Requires: the dev plugin built from THIS tree installed
# (SA_PLUGIN_DEV=1 sa plugin install --dev .) and `sa` on PATH.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
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
    sig="$(grep -oE '"trap":"[A-Za-z]+"' "$log" | head -1 | sed 's/"trap":"//; s/"//')"
    if [ -z "$sig" ]; then
        sig="$(grep -oE 'error\[[A-Za-z]+' "$log" | head -1 | sed 's/error\[//')"
    fi
    if [ -z "$sig" ]; then
        sig="$(grep -oE "$TOKENS" "$log" | head -1)"
    fi
    if [ -z "$sig" ]; then
        sig="$(grep -oE "panic: code=[0-9]+" "$log" | head -1 | sed 's/panic: code=/panic:/')"
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
        ( cd "$work" && SLA_NO_FRESHNESS_CACHE=1 SA_PLUGIN_DEV=1 timeout 180 sa sla test "$probe" --test-backend "$flag" ) > "$log" 2>&1
        rc=$?
        read -r verdict phase sig <<< "$(classify "$log" "$rc")"
        echo -e "${pid}\t${backend}\t${verdict}\t${phase}\t${sig}\t${rc}" >> "$RESULTS"
        rm -rf "$work"
    done
done
echo "run_matrix: $(($(wc -l < "$RESULTS") - 1)) cells -> $RESULTS"
