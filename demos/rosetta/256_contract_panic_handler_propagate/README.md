# 256 Contract Panic Handler Propagate

This slot keeps panic propagation observable as both local and host handler hops.

- `main.rs`: Rust reference for the local and host panic-handler hops.
- `main.sla`: Sla companion for the local and host panic-handler hops.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/256_contract_panic_handler_propagate/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/256_contract_panic_handler_propagate/main.sla --out /tmp/256_contract_panic_handler_propagate.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/256_contract_panic_handler_propagate/main.sla
```
