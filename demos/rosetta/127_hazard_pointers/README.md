# 127 Hazard Pointers

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/127_hazard_pointers/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/127_hazard_pointers/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/127_hazard_pointers/main.sla --out /tmp/127_hazard_pointers.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/127_hazard_pointers/main.sla
```
