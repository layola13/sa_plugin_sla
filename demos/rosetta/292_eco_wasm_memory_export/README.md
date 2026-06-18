# 292 Eco Wasm Memory Export

This slot keeps exported Wasm linear memory observable as one published memory surface.

- `main.rs`: Rust reference for one published linear-memory surface.
- `main.sla`: Sla companion for one published memory surface.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/292_eco_wasm_memory_export/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/292_eco_wasm_memory_export/main.sla --out /tmp/292_eco_wasm_memory_export.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/292_eco_wasm_memory_export/main.sla
```
