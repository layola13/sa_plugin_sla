# 241 Contract Layout Stability

This slot keeps C-style contract layout stability observable as a two-field header with fixed field order.

- `main.rs`: Rust reference for the two-field header layout.
- `main.sla`: Sla companion for the two-field header layout.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/241_contract_layout_stability/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/241_contract_layout_stability/main.sla --out /tmp/241_contract_layout_stability.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/241_contract_layout_stability/main.sla
```
