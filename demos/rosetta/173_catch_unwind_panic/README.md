# 173 Catch Unwind Panic

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/173_catch_unwind_panic/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/173_catch_unwind_panic/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/173_catch_unwind_panic/main.sla --out /tmp/173_catch_unwind_panic.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/173_catch_unwind_panic/main.sla
```
