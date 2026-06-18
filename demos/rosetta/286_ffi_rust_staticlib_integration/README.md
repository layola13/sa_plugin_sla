# 286 Ffi Rust Staticlib Integration

This slot keeps Rust staticlib export integration observable as one exposed symbol.

- `main.rs`: Rust reference for one exposed symbol from a Rust staticlib.
- `main.sla`: Sla companion for one exposed symbol from a Rust staticlib.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/286_ffi_rust_staticlib_integration/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/286_ffi_rust_staticlib_integration/main.sla --out /tmp/286_ffi_rust_staticlib_integration.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/286_ffi_rust_staticlib_integration/main.sla
```
