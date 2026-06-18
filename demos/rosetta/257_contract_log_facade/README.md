# 257 Contract Log Facade

This slot keeps the contract logging surface observable as three enabled levels: info, warn, and error.

- `main.rs`: Rust reference for the info/warn/error logging surface.
- `main.sla`: Sla companion for the info/warn/error logging surface.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/257_contract_log_facade/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/257_contract_log_facade/main.sla --out /tmp/257_contract_log_facade.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/257_contract_log_facade/main.sla
```
