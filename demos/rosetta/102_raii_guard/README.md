# 102 Raii Guard

This directory now records the current RAII-guard gap honestly.

- `main.rs`: Rust reference for scoped mutex guard acquisition, early return, and guarded update behavior.
- `main.sla`: current Sla companion shape for the same observable intent, but the guarded update path no longer type-checks locally.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/102_raii_guard/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/102_raii_guard/main.sla --out /tmp/102_raii_guard.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/102_raii_guard/main.sla
```
