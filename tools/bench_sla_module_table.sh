#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
usage: tools/bench_sla_module_table.sh [options]

Synthetic benchmarks for SLA Module Table import expansion and test-codegen
pruning. Results are JSONL on stdout or --out.

Options:
  --cli <path>              CLI executable (default: sa)
  --runs <n>                Iterations per scenario/command (default: 3)
  --workdir <dir>           Reuse/create benchmark fixture directory
  --out <file.jsonl>        Write JSONL to file instead of stdout
  --fanout <n>              Number of imported leaf modules (default: 40)
  --repeat-imports <n>      Repeated imports of the same module (default: 120)
  --dead-funcs <n>          Dead functions per imported leaf module (default: 80)
  --timeout <duration>      Per command timeout(1) duration (default: 120s)
  -h, --help                Show this help

Scenarios:
  repeated_import_check     many repeated @import lines of one dependency
  fanout_check              many imported modules with many dead functions
  fanout_test_sa            test-codegen path over the same fanout graph
  imported_macro_test_sa    imported .sa macro direct-callee pruning path

To compare before/after, run this script twice with different --cli values and
the same --workdir/options, then compare elapsed_ms by scenario.
USAGE
}

cli="sa"
runs=3
workdir=""
out=""
fanout=40
repeat_imports=120
dead_funcs=80
cmd_timeout="120s"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --cli) cli=${2:?missing value for --cli}; shift 2 ;;
        --runs) runs=${2:?missing value for --runs}; shift 2 ;;
        --workdir) workdir=${2:?missing value for --workdir}; shift 2 ;;
        --out) out=${2:?missing value for --out}; shift 2 ;;
        --fanout) fanout=${2:?missing value for --fanout}; shift 2 ;;
        --repeat-imports) repeat_imports=${2:?missing value for --repeat-imports}; shift 2 ;;
        --dead-funcs) dead_funcs=${2:?missing value for --dead-funcs}; shift 2 ;;
        --timeout) cmd_timeout=${2:?missing value for --timeout}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for value in "$runs" "$fanout" "$repeat_imports" "$dead_funcs"; do
    case "$value" in
        ''|*[!0-9]*) echo "numeric options must be positive integers" >&2; exit 2 ;;
    esac
    if [ "$value" -lt 1 ]; then
        echo "numeric options must be >= 1" >&2
        exit 2
    fi
done

if [ -z "$workdir" ]; then
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/sla-module-bench.XXXXXX")
else
    mkdir -p "$workdir"
fi

if [ -n "$out" ]; then
    : > "$out"
fi

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

emit_result() {
    local scenario=$1
    local command_name=$2
    local run=$3
    local elapsed_ms=$4
    local status=$5
    local command=$6
    local line
    line=$(printf '{"scenario":"%s","command_name":"%s","run":%s,"elapsed_ms":%s,"status":%s,"fanout":%s,"repeat_imports":%s,"dead_funcs":%s,"cli":"%s","command":"%s"}' \
        "$(json_escape "$scenario")" \
        "$(json_escape "$command_name")" \
        "$run" \
        "$elapsed_ms" \
        "$status" \
        "$fanout" \
        "$repeat_imports" \
        "$dead_funcs" \
        "$(json_escape "$cli")" \
        "$(json_escape "$command")")
    if [ -n "$out" ]; then
        printf '%s\n' "$line" >> "$out"
    else
        printf '%s\n' "$line"
    fi
}

quote() {
    printf '%q' "$1"
}

write_leaf_module() {
    local path=$1
    local index=$2
    {
        printf 'fn live_%s() -> i64 {\n    return %s;\n}\n\n' "$index" "$index"
        local j
        for j in $(seq 1 "$dead_funcs"); do
            printf 'fn dead_%s_%s() -> i64 {\n    return missing_%s_%s();\n}\n\n' "$index" "$j" "$index" "$j"
        done
    } > "$path"
}

generate_fixtures() {
    rm -rf "$workdir/fixtures"
    mkdir -p "$workdir/fixtures/leaves"

    write_leaf_module "$workdir/fixtures/repeated_dep.sla" 1

    {
        local i
        for i in $(seq 1 "$repeat_imports"); do
            printf '@import "repeated_dep.sla"\n'
        done
        printf '\nfn main_value() -> i64 {\n    return live_1();\n}\n'
    } > "$workdir/fixtures/repeated_main.sla"

    {
        local i
        for i in $(seq 1 "$fanout"); do
            write_leaf_module "$workdir/fixtures/leaves/dep_$i.sla" "$i"
            printf '@import "leaves/dep_%s.sla"\n' "$i"
        done
        printf '\nfn total() -> i64 {\n    return '
        for i in $(seq 1 "$fanout"); do
            if [ "$i" -gt 1 ]; then printf ' + '; fi
            printf 'live_%s()' "$i"
        done
        printf ';\n}\n\n@test "fanout live only"() {\n    if total() <= 0 { panic(90001); };\n}\n'
    } > "$workdir/fixtures/fanout_main.sla"

    {
        printf '[MACRO] BENCH_IMPORTED_SUM %%out, %%value\n'
        printf '    %%out = call @sla__macro_callee(&%%value)\n'
        printf '[END_MACRO]\n'
    } > "$workdir/fixtures/imported_macro.sa"

    {
        printf '@import "imported_macro.sa"\n\n'
        printf 'struct Pair { left: i64, right: i64 }\n\n'
        printf 'fn macro_callee(value: &Pair) -> i64 {\n    value.left + value.right\n}\n\n'
        local j
        for j in $(seq 1 "$((dead_funcs * 2))"); do
            printf 'fn macro_dead_%s() -> i64 {\n    return macro_missing_%s();\n}\n\n' "$j" "$j"
        done
        printf 'fn use_macro() -> i64 {\n    let pair = Pair { left: 31, right: 11 };\n    BENCH_IMPORTED_SUM(pair)\n}\n\n'
        printf '@test "imported macro callee"() {\n    if use_macro() != 42 { panic(90002); };\n}\n'
    } > "$workdir/fixtures/imported_macro_main.sla"
}

run_timed() {
    local scenario=$1
    local command_name=$2
    local run=$3
    local command=$4
    local start end elapsed status stderr_path
    stderr_path="$workdir/${scenario}_${command_name}_${run}.stderr"
    start=$(date +%s%N)
    set +e
    timeout "$cmd_timeout" bash -lc "$command" >/dev/null 2>"$stderr_path"
    status=$?
    set -e
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    emit_result "$scenario" "$command_name" "$run" "$elapsed" "$status" "$command"
    if [ "$status" -ne 0 ]; then
        echo "benchmark failed: $scenario/$command_name run $run (status $status)" >&2
        echo "stderr: $stderr_path" >&2
        exit "$status"
    fi
}

generate_fixtures

export SA_PLUGIN_DEV=${SA_PLUGIN_DEV:-1}
cli_q=$(quote "$cli")
repeated_q=$(quote "$workdir/fixtures/repeated_main.sla")
fanout_q=$(quote "$workdir/fixtures/fanout_main.sla")
macro_q=$(quote "$workdir/fixtures/imported_macro_main.sla")

for i in $(seq 1 "$runs"); do
    run_timed "repeated_import_check" "check" "$i" "SA_PLUGIN_DEV=\${SA_PLUGIN_DEV:-1} $cli_q sla check $repeated_q"
done

for i in $(seq 1 "$runs"); do
    run_timed "fanout_check" "check" "$i" "SA_PLUGIN_DEV=\${SA_PLUGIN_DEV:-1} $cli_q sla check $fanout_q"
done

for i in $(seq 1 "$runs"); do
    run_timed "fanout_test_sa" "test_sa" "$i" "SA_PLUGIN_DEV=\${SA_PLUGIN_DEV:-1} $cli_q sla test $fanout_q --test-backend sa --jobs 1 --trace-panic"
done

for i in $(seq 1 "$runs"); do
    run_timed "imported_macro_test_sa" "test_sa" "$i" "SA_PLUGIN_DEV=\${SA_PLUGIN_DEV:-1} $cli_q sla test $macro_q --test-backend sa --jobs 1 --trace-panic"
done

if [ -n "$out" ]; then
    echo "wrote benchmark results: $out" >&2
fi
echo "fixtures: $workdir/fixtures" >&2
