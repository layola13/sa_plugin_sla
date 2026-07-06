# SLA 编译器 Benchmark Harness

日期：2026-07-06

## 范围

本仓库只维护 compiler-owned benchmark：SLA frontend、direct SAB emission、SAB fallback/direct 测试路径、以及 native build 主链路。
下游项目的业务吞吐，例如 ECS spawn/query/schedule，不在本仓库硬编码；通过 external command hook 接入。

## 工具

```sh
tools/bench_sla_pipeline.sh --runs 3 --out /tmp/sla_pipeline_bench.jsonl
```

默认输入是 `tests/test_sab_direct.sla`，默认 CLI 是 `./zig-out/bin/sla-local-cli`（存在时）否则使用 `sa`。

内置项目：

- `sla_to_sab_cold`：删除 managed SAB cache 后计时 `.sla -> .sab`。
- `sla_to_sab_warm`：保留 cache 计时 `.sla -> .sab`。
- `sla_to_native`：计时 `.sla -> native` build-exe 主链路。
- `sab_test_fallback_allowed`：SAB test，允许 fallback。
- `sab_test_direct_no_fallback`：SAB test，`SLA_SAB_NO_FALLBACK=1`。

输出为 JSONL，每行包含 `name`、`input`、`run`、`elapsed_ms`、`status`、`command`。

## 下游 Hook

下游项目可把自己的吞吐 benchmark 作为外部命令传入：

```sh
tools/bench_sla_pipeline.sh \
  --runs 5 \
  --external 'ecs_spawn::cd /path/to/downstream && ./bench_spawn.sh' \
  --external 'ecs_schedule::cd /path/to/downstream && ./bench_schedule.sh' \
  --out /tmp/sla_pipeline_with_downstream.jsonl
```

这些 external 结果只表示命令计时；业务语义、fixture、标签和阈值由下游项目维护。
