# 287 Ffi Zig Export Integration

This slot keeps Zig export integration observable as one symbol surfaced to foreign callers.

- `main.rs`: Rust reference for one Zig-exported symbol visible to foreign callers.
- `main.sla`: Sla companion for one symbol surfaced to foreign callers.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/287_ffi_zig_export_integration/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/287_ffi_zig_export_integration/main.sla --out /tmp/287_ffi_zig_export_integration.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/287_ffi_zig_export_integration/main.sla
```
