# 128 Rcu Read Copy Update

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/128_rcu_read_copy_update/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/128_rcu_read_copy_update/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/128_rcu_read_copy_update/main.sla --out /tmp/128_rcu_read_copy_update.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/128_rcu_read_copy_update/main.sla
```
