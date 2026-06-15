# 005 Struct

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/05_struct/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/05_struct/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/05_struct/main.sla --out /tmp/05_struct.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/05_struct/main.sla
```
