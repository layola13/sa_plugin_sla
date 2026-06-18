# 250 Contract Const Export

This slot keeps exported contract constants observable as one published ABI version value.

- `main.rs`: Rust reference for one published ABI version constant.
- `main.sla`: Sla companion for one published ABI version constant.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/250_contract_const_export/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/250_contract_const_export/main.sla --out /tmp/250_contract_const_export.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/250_contract_const_export/main.sla
```
