# 039 Generic Enum I32

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/39_generic_enum_i32/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/39_generic_enum_i32/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/39_generic_enum_i32/main.sla --out /tmp/39_generic_enum_i32.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/39_generic_enum_i32/main.sla
```
