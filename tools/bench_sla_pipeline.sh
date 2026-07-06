#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
usage: tools/bench_sla_pipeline.sh [options]

Compiler-owned SLA pipeline benchmark harness. Results are JSONL.

Options:
  --input <file.sla>          SLA input fixture (default: tests/test_sab_direct.sla)
  --runs <n>                  Iterations per built-in benchmark (default: 3)
  --cli <path>                CLI executable (default: ./zig-out/bin/sla-local-cli if present, otherwise sa)
  --out <file.jsonl>          Write JSONL to file instead of stdout
  --workdir <dir>             Reuse/create a benchmark work directory
  --external <name::cmd>      Time an external downstream benchmark command
  --skip-native               Skip .sla -> native build timing
  -h, --help                  Show this help

Built-in benchmarks:
  sla_to_sab_cold             Remove managed SAB cache before each .sla -> .sab build
  sla_to_sab_warm             Keep cache between .sla -> .sab builds
  sla_to_native               Build native executable through the SAB mainline
  sab_test_fallback_allowed   SAB test with fallback allowed
  sab_test_direct_no_fallback SAB test with SLA_SAB_NO_FALLBACK=1

External commands are intentionally generic hooks. For example, a downstream
project may pass --external 'ecs_spawn::cd /repo && ./bench_spawn.sh'. This
script does not contain ECS or other downstream business benchmark logic.
USAGE
}

input="tests/test_sab_direct.sla"
runs=3
cli=""
out=""
workdir=""
skip_native=0
externals=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --input)
            input=${2:?missing value for --input}
            shift 2
            ;;
        --runs)
            runs=${2:?missing value for --runs}
            shift 2
            ;;
        --cli)
            cli=${2:?missing value for --cli}
            shift 2
            ;;
        --out)
            out=${2:?missing value for --out}
            shift 2
            ;;
        --workdir)
            workdir=${2:?missing value for --workdir}
            shift 2
            ;;
        --external)
            externals+=("${2:?missing value for --external}")
            shift 2
            ;;
        --skip-native)
            skip_native=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$runs" in
    ''|*[!0-9]*) echo "--runs must be a positive integer" >&2; exit 2 ;;
esac
if [ "$runs" -lt 1 ]; then
    echo "--runs must be >= 1" >&2
    exit 2
fi

if [ -z "$cli" ]; then
    if [ -x "./zig-out/bin/sla-local-cli" ]; then
        cli="./zig-out/bin/sla-local-cli"
    else
        cli="sa"
    fi
fi

if [ ! -f "$input" ]; then
    echo "input not found: $input" >&2
    exit 2
fi

if [ -z "$workdir" ]; then
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/sla-bench.XXXXXX")
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
    local name=$1
    local run=$2
    local elapsed_ms=$3
    local status=$4
    local command=$5
    local line
    line=$(printf '{"name":"%s","input":"%s","run":%s,"elapsed_ms":%s,"status":%s,"command":"%s"}' \
        "$(json_escape "$name")" \
        "$(json_escape "$input")" \
        "$run" \
        "$elapsed_ms" \
        "$status" \
        "$(json_escape "$command")")
    if [ -n "$out" ]; then
        printf '%s\n' "$line" >> "$out"
    else
        printf '%s\n' "$line"
    fi
}

run_timed() {
    local name=$1
    local run=$2
    local command=$3
    local start end elapsed status
    start=$(date +%s%N)
    set +e
    bash -lc "$command" >/dev/null 2>"$workdir/${name}_${run}.stderr"
    status=$?
    set -e
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    emit_result "$name" "$run" "$elapsed" "$status" "$command"
    if [ "$status" -ne 0 ]; then
        echo "benchmark failed: $name run $run (status $status)" >&2
        echo "stderr: $workdir/${name}_${run}.stderr" >&2
        exit "$status"
    fi
}

quote() {
    printf "%q" "$1"
}

export SA_PLUGIN_DEV=${SA_PLUGIN_DEV:-1}

input_q=$(quote "$input")
cli_q=$(quote "$cli")
workdir_q=$(quote "$workdir")

for i in $(seq 1 "$runs"); do
    rm -rf .sla-cache/sab
    run_timed "sla_to_sab_cold" "$i" "SA_PLUGIN_DEV=\${SA_PLUGIN_DEV:-1} $cli_q sla sab build $input_q --out $workdir_q/cold_$i.sab"
done

for i in $(seq 1 "$runs"); do
    run_timed "sla_to_sab_warm" "$i" "SA_PLUGIN_DEV=\${SA_PLUGIN_DEV:-1} $cli_q sla sab build $input_q --out $workdir_q/warm_$i.sab"
done

if [ "$skip_native" -eq 0 ]; then
    for i in $(seq 1 "$runs"); do
        run_timed "sla_to_native" "$i" "SA_PLUGIN_DEV=\${SA_PLUGIN_DEV:-1} $cli_q sla build-exe $input_q -o $workdir_q/native_$i"
    done
fi

for i in $(seq 1 "$runs"); do
    run_timed "sab_test_fallback_allowed" "$i" "SA_PLUGIN_DEV=\${SA_PLUGIN_DEV:-1} $cli_q sla test $input_q --test-backend sab --jobs 1 --trace-panic"
done

for i in $(seq 1 "$runs"); do
    run_timed "sab_test_direct_no_fallback" "$i" "SA_PLUGIN_DEV=\${SA_PLUGIN_DEV:-1} SLA_SAB_NO_FALLBACK=1 $cli_q sla test $input_q --test-backend sab --jobs 1 --trace-panic"
done

for external in "${externals[@]}"; do
    if [[ "$external" != *::* ]]; then
        echo "--external must use name::cmd: $external" >&2
        exit 2
    fi
    name=${external%%::*}
    command=${external#*::}
    if [ -z "$name" ] || [ -z "$command" ]; then
        echo "--external must use non-empty name::cmd: $external" >&2
        exit 2
    fi
    for i in $(seq 1 "$runs"); do
        run_timed "external:$name" "$i" "$command"
    done
done

if [ -n "$out" ]; then
    echo "wrote benchmark results: $out" >&2
fi
