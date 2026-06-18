# 214 Pkg Target Specific Deps

This slot keeps target-gated dependency selection observable across Linux and Wasm branches.

- `main.rs`: Rust reference for Linux and Wasm dependency branches.
- `main.sla`: Sla companion for Linux and Wasm dependency branches.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/214_pkg_target_specific_deps/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/214_pkg_target_specific_deps/main.sla --out /tmp/214_pkg_target_specific_deps.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/214_pkg_target_specific_deps/main.sla
```
