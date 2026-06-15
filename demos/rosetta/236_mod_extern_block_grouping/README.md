# 236 Mod Extern Block Grouping

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/236_mod_extern_block_grouping/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/236_mod_extern_block_grouping/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/236_mod_extern_block_grouping/main.sla --out /tmp/236_mod_extern_block_grouping.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/236_mod_extern_block_grouping/main.sla
```
