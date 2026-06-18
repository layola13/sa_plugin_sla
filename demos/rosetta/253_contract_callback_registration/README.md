# 253 Contract Callback Registration

This slot keeps callback registration observable as one host callback bound through the contract surface.

- `main.rs`: Rust reference for one host callback registered through the contract layer.
- `main.sla`: Sla companion for one host callback registered through the contract layer.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/253_contract_callback_registration/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/253_contract_callback_registration/main.sla --out /tmp/253_contract_callback_registration.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/253_contract_callback_registration/main.sla
```
