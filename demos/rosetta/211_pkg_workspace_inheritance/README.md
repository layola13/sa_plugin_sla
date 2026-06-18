# 211 Pkg Workspace Inheritance

This slot keeps inherited workspace metadata observable as shared version and license fields.

- `main.rs`: Rust reference for inherited version and license metadata.
- `main.sla`: Sla companion for inherited version and license metadata.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/211_pkg_workspace_inheritance/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/211_pkg_workspace_inheritance/main.sla --out /tmp/211_pkg_workspace_inheritance.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/211_pkg_workspace_inheritance/main.sla
```
