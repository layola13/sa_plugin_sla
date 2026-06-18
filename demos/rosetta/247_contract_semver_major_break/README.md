# 247 Contract Semver Major Break

This slot keeps breaking contract evolution observable as one removed required field.

- `main.rs`: Rust reference for a removed required field.
- `main.sla`: Sla companion for a removed required field.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/247_contract_semver_major_break/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/247_contract_semver_major_break/main.sla --out /tmp/247_contract_semver_major_break.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/247_contract_semver_major_break/main.sla
```
