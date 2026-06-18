# 283 Ffi Link Dynamic C Lib

This slot keeps dynamic-library linkage observable as one runtime-resolved symbol import.

- `main.rs`: Rust reference for one runtime-resolved dynamic-library symbol.
- `main.sla`: Sla companion for one runtime-resolved dynamic-library symbol.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/283_ffi_link_dynamic_c_lib/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/283_ffi_link_dynamic_c_lib/main.sla --out /tmp/283_ffi_link_dynamic_c_lib.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/283_ffi_link_dynamic_c_lib/main.sla
```
