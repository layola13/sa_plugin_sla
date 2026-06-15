# 182 Mmap Memory Mapping

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/182_mmap_memory_mapping/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/182_mmap_memory_mapping/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/182_mmap_memory_mapping/main.sla --out /tmp/182_mmap_memory_mapping.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/182_mmap_memory_mapping/main.sla
```
