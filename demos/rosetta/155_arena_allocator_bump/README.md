# 155 Arena Allocator Bump

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/155_arena_allocator_bump/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/155_arena_allocator_bump/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/155_arena_allocator_bump/main.sla --out /tmp/155_arena_allocator_bump.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/155_arena_allocator_bump/main.sla
```
