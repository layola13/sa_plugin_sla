# 289 Ffi Opaque Handle Passing

This slot keeps opaque foreign-handle passing observable as one round-trip transfer.

- `main.rs`: Rust reference for one opaque handle round-trip transfer.
- `main.sla`: Sla companion for one round-trip transfer.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/289_ffi_opaque_handle_passing/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/289_ffi_opaque_handle_passing/main.sla --out /tmp/289_ffi_opaque_handle_passing.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/289_ffi_opaque_handle_passing/main.sla
```
