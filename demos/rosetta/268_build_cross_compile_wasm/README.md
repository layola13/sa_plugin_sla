# 268 Build Cross Compile Wasm

This slot keeps cross-compilation targeting observable as one Wasm target triple.

- `main.rs`: Rust reference for one Wasm target triple.
- `main.sla`: Sla companion for one Wasm target triple.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/268_build_cross_compile_wasm/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/268_build_cross_compile_wasm/main.sla --out /tmp/268_build_cross_compile_wasm.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/268_build_cross_compile_wasm/main.sla
```
