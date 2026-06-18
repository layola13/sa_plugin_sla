# 271 Build Optimization Passes

This slot keeps optimizer scheduling observable as inline, dead-code-elimination, and constant-folding passes.

- `main.rs`: Rust reference for inline, DCE, and constant-folding passes.
- `main.sla`: Sla companion for inline, DCE, and constant-folding passes.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/271_build_optimization_passes/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/271_build_optimization_passes/main.sla --out /tmp/271_build_optimization_passes.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/271_build_optimization_passes/main.sla
```
