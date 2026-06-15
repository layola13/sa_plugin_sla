# 218 Pkg Metadata Custom

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/218_pkg_metadata_custom/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/218_pkg_metadata_custom/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/218_pkg_metadata_custom/main.sla --out /tmp/218_pkg_metadata_custom.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/218_pkg_metadata_custom/main.sla
```
