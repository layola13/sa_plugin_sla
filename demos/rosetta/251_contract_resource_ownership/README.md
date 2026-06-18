# 251 Contract Resource Ownership

This slot keeps ownership transfer across the contract boundary observable as one moved resource.

- `main.rs`: Rust reference for moving one resource across the boundary.
- `main.sla`: Sla companion for moving one resource across the boundary.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/251_contract_resource_ownership/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/251_contract_resource_ownership/main.sla --out /tmp/251_contract_resource_ownership.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/251_contract_resource_ownership/main.sla
```
