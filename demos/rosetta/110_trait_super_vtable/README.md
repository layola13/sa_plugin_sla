# 110 Trait Super Vtable

This directory now records the current super-trait vtable gap honestly.

- `main.rs`: Rust reference for a trait inheriting another trait and dispatching both methods.
- `main.sla`: current Sla companion shape for the same intent, but the shared super-trait dispatch path no longer type-checks locally.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/110_trait_super_vtable/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/110_trait_super_vtable/main.sla --out /tmp/110_trait_super_vtable.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/110_trait_super_vtable/main.sla
```
