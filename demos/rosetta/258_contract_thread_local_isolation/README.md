# 258 Contract Thread Local Isolation

This slot keeps thread-local isolation observable as two independent per-thread slots.

- `main.rs`: Rust reference for two isolated per-thread slots.
- `main.sla`: Sla companion for two isolated per-thread slots.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/258_contract_thread_local_isolation/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/258_contract_thread_local_isolation/main.sla --out /tmp/258_contract_thread_local_isolation.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/258_contract_thread_local_isolation/main.sla
```
