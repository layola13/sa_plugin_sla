# 245 Contract Generic Monomorph Share

This slot keeps shared generic contract instantiation observable across both integer and boolean call paths.

- `main.rs`: Rust reference for shared generic instantiation across call paths.
- `main.sla`: Sla companion for shared generic instantiation across call paths.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/245_contract_generic_monomorph_share/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/245_contract_generic_monomorph_share/main.sla --out /tmp/245_contract_generic_monomorph_share.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/245_contract_generic_monomorph_share/main.sla
```
