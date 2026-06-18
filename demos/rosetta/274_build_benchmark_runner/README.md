# 274 Build Benchmark Runner

This slot keeps benchmark scheduling observable as one throughput benchmark group.

- `main.rs`: Rust reference for one throughput benchmark group.
- `main.sla`: Sla companion for one throughput benchmark group.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/274_build_benchmark_runner/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/274_build_benchmark_runner/main.sla --out /tmp/274_build_benchmark_runner.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/274_build_benchmark_runner/main.sla
```
