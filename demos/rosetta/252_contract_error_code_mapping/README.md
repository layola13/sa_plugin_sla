# 252 Contract Error Code Mapping

This slot keeps error-surface translation observable as two contract errors mapped into exported numeric codes.

- `main.rs`: Rust reference for mapping two errors into numeric codes.
- `main.sla`: Sla companion for mapping two errors into numeric codes.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/252_contract_error_code_mapping/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/252_contract_error_code_mapping/main.sla --out /tmp/252_contract_error_code_mapping.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/252_contract_error_code_mapping/main.sla
```
