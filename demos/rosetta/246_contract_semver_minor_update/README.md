# 246 Contract Semver Minor Update

This slot keeps backward-compatible contract growth observable as one added field in a minor version update.

- `main.rs`: Rust reference for a backward-compatible added field.
- `main.sla`: Sla companion for a backward-compatible added field.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/246_contract_semver_minor_update/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/246_contract_semver_minor_update/main.sla --out /tmp/246_contract_semver_minor_update.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/246_contract_semver_minor_update/main.sla
```
