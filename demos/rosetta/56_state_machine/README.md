# 056 State Machine

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/56_state_machine/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/56_state_machine/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/56_state_machine/main.sla --out /tmp/56_state_machine.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/56_state_machine/main.sla
```
