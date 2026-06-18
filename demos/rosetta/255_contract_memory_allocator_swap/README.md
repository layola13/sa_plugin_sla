# 255 Contract Memory Allocator Swap

This slot keeps allocator selection observable as one alternate allocator chosen through the contract layer.

- `main.rs`: Rust reference for one alternate allocator selected through the contract layer.
- `main.sla`: Sla companion for one alternate allocator selected through the contract layer.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/255_contract_memory_allocator_swap/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/255_contract_memory_allocator_swap/main.sla --out /tmp/255_contract_memory_allocator_swap.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/255_contract_memory_allocator_swap/main.sla
```
