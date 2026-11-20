# SLA Compiler Benchmark Harness

> This is the English counterpart of the Chinese document [SLA 编译器 Benchmark Harness](./benchmarking_cn.md).

Date: 2026-07-06

## Scope

This repository only maintains compiler-owned benchmarks: the SLA frontend, direct SAB emission, the SAB fallback/direct test path, and the native build main chain. Downstream project business throughput, such as ECS spawn/query/schedule, is not hardcoded in this repository; it is plugged in via an external command hook.

## Tools

```sh
tools/bench_sla_pipeline.sh --runs 3 --out /tmp/sla_pipeline_bench.jsonl
```

The default input is `tests/test_sab_direct.sla`, and the default CLI is `./zig-out/bin/sla-local-cli` (when it exists), otherwise `sa`.

Built-in projects:

- `sla_to_sab_cold`: times `.sla -> .sab` after deleting the managed SAB cache.
- `sla_to_sab_warm`: times `.sla -> .sab` with the cache retained.
- `sla_to_native`: times the `.sla -> native` build-exe main chain.
- `sab_test_fallback_allowed`: SAB test, fallback allowed.
- `sab_test_direct_no_fallback`: SAB test, `SLA_SAB_NO_FALLBACK=1`.

The output is JSONL, with each line containing `name`, `input`, `run`, `elapsed_ms`, `status`, and `command`.

## Downstream Hooks

Downstream projects can pass their own throughput benchmarks as external commands:

```sh
tools/bench_sla_pipeline.sh \
  --runs 5 \
  --external 'ecs_spawn::cd /path/to/downstream && ./bench_spawn.sh' \
  --external 'ecs_schedule::cd /path/to/downstream && ./bench_schedule.sh' \
  --out /tmp/sla_pipeline_with_downstream.jsonl
```

These external results only represent command timing; business semantics, fixtures, labels, and thresholds are maintained by the downstream project.
