# 290 Ffi Callback Thunk

This slot keeps foreign-to-local callback bridging observable as one callback thunk layer.

- `main.rs`: Rust reference for one foreign-to-local callback thunk layer.
- `main.sla`: Sla companion for one callback thunk layer.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/290_ffi_callback_thunk/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/290_ffi_callback_thunk/main.sla --out /tmp/290_ffi_callback_thunk.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/290_ffi_callback_thunk/main.sla
```
