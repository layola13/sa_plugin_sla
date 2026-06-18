# 259 Contract Static Init Order

This slot keeps static initialization order observable as two staged ready flags.

- `main.rs`: Rust reference for the config-loaded and service-started stages.
- `main.sla`: Sla companion for the config-loaded and service-started stages.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/259_contract_static_init_order/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/259_contract_static_init_order/main.sla --out /tmp/259_contract_static_init_order.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/259_contract_static_init_order/main.sla
```
