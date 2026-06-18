# 242 Contract Opaque Struct

This slot keeps opaque-handle contracts observable as one public constructor returning an unreadable handle type.

- `main.rs`: Rust reference for one unreadable public handle constructor.
- `main.sla`: Sla companion for one unreadable public handle constructor.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/242_contract_opaque_struct/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/242_contract_opaque_struct/main.sla --out /tmp/242_contract_opaque_struct.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/242_contract_opaque_struct/main.sla
```
