# 248 Contract Ffi Boundary Trust

This slot keeps foreign-boundary validation observable as both pointer and length checks crossing the ABI edge.

- `main.rs`: Rust reference for pointer and length checks across the ABI edge.
- `main.sla`: Sla companion for pointer and length checks across the ABI edge.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/248_contract_ffi_boundary_trust/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/248_contract_ffi_boundary_trust/main.sla --out /tmp/248_contract_ffi_boundary_trust.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/248_contract_ffi_boundary_trust/main.sla
```
