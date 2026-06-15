# 134 Join All Futures

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/134_join_all_futures/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/134_join_all_futures/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/134_join_all_futures/main.sla --out /tmp/134_join_all_futures.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/134_join_all_futures/main.sla
```
