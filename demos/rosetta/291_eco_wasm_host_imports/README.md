# 291 Eco Wasm Host Imports

This slot keeps Wasm host integration observable as imported log and clock functions.

- `main.rs`: Rust reference for imported log and clock host functions.
- `main.sla`: Sla companion for imported log and clock host functions.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/291_eco_wasm_host_imports/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/291_eco_wasm_host_imports/main.sla --out /tmp/291_eco_wasm_host_imports.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/291_eco_wasm_host_imports/main.sla
```
