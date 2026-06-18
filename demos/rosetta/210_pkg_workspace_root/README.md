# 210 Pkg Workspace Root

This slot keeps workspace membership observable as one app member plus one library member.

- `main.rs`: Rust reference for one app member plus one library member.
- `main.sla`: Sla companion for one app member plus one library member.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/210_pkg_workspace_root/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/210_pkg_workspace_root/main.sla --out /tmp/210_pkg_workspace_root.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/210_pkg_workspace_root/main.sla
```
