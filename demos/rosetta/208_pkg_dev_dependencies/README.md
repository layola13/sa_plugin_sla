# 208 Pkg Dev Dependencies

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/208_pkg_dev_dependencies/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/208_pkg_dev_dependencies/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/208_pkg_dev_dependencies/main.sla --out /tmp/208_pkg_dev_dependencies.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/208_pkg_dev_dependencies/main.sla
```
