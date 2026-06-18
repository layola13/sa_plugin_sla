# 260 Contract Deprecated Warning

This slot keeps the deprecated-warning observable as a single counted entry.

- `main.rs`: Rust reference for the deprecated-entry warning path.
- `main.sla`: Sla companion for the deprecated-entry warning path.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/260_contract_deprecated_warning/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/260_contract_deprecated_warning/main.sla --out /tmp/260_contract_deprecated_warning.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/260_contract_deprecated_warning/main.sla
```
