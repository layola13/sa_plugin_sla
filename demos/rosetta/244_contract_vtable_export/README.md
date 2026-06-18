# 244 Contract Vtable Export

This slot keeps trait-style contract export observable as two vtable slots: `init` and `run`.

- `main.rs`: Rust reference for the `init` and `run` vtable slots.
- `main.sla`: Sla companion for the `init` and `run` vtable slots.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/244_contract_vtable_export/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/244_contract_vtable_export/main.sla --out /tmp/244_contract_vtable_export.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/244_contract_vtable_export/main.sla
```
