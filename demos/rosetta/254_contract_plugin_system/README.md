# 254 Contract Plugin System

This slot keeps plugin-contract discovery observable as two enabled plugins on the active surface.

- `main.rs`: Rust reference for two enabled plugins on the active surface.
- `main.sla`: Sla companion for two enabled plugins on the active surface.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/254_contract_plugin_system/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/254_contract_plugin_system/main.sla --out /tmp/254_contract_plugin_system.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/254_contract_plugin_system/main.sla
```
