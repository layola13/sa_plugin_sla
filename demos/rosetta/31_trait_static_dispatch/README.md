# 031 Trait Static Dispatch

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/31_trait_static_dispatch/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/31_trait_static_dispatch/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/31_trait_static_dispatch/main.sla --out /tmp/31_trait_static_dispatch.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/31_trait_static_dispatch/main.sla
```
