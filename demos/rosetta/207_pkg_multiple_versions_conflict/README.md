# 207 Pkg Multiple Versions Conflict

This slot keeps conflicting version requirements observable as a reported mismatch.

- `main.rs`: Rust reference for conflicting version requirements.
- `main.sla`: Sla companion for conflicting version requirements.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/207_pkg_multiple_versions_conflict/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/207_pkg_multiple_versions_conflict/main.sla --out /tmp/207_pkg_multiple_versions_conflict.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/207_pkg_multiple_versions_conflict/main.sla
```
