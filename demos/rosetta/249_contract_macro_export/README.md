# 249 Contract Macro Export

This slot keeps contract macro export observable as one macro surfaced to downstream callers.

- `main.rs`: Rust reference for one macro exported to downstream callers.
- `main.sla`: Sla companion for one macro exported to downstream callers.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/249_contract_macro_export/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/249_contract_macro_export/main.sla --out /tmp/249_contract_macro_export.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/249_contract_macro_export/main.sla
```
