# 285 Ffi Objective C Framework

This slot keeps Objective-C framework linkage observable as one imported `Foundation`-style framework.

- `main.rs`: Rust reference for one imported `Foundation`-style framework.
- `main.sla`: Sla companion for one imported `Foundation`-style framework.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/285_ffi_objective_c_framework/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/285_ffi_objective_c_framework/main.sla --out /tmp/285_ffi_objective_c_framework.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/285_ffi_objective_c_framework/main.sla
```
