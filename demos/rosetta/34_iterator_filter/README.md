# 034 Iterator Filter

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/34_iterator_filter/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/34_iterator_filter/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/34_iterator_filter/main.sla --out /tmp/34_iterator_filter.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/34_iterator_filter/main.sla
```
