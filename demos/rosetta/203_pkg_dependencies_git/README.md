# 203 Pkg Dependencies Git

This slot keeps git-backed dependency selection observable as one pinned remote package.

- `main.rs`: Rust reference for one pinned git dependency.
- `main.sla`: Sla companion for one pinned git dependency.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/203_pkg_dependencies_git/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/203_pkg_dependencies_git/main.sla --out /tmp/203_pkg_dependencies_git.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/203_pkg_dependencies_git/main.sla
```
