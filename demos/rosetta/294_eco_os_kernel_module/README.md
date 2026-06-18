# 294 Eco Os Kernel Module

This slot keeps kernel-module integration observable as init and exit hooks.

- `main.rs`: Rust reference for kernel-module init and exit hooks.
- `main.sla`: Sla companion for init and exit hooks.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/294_eco_os_kernel_module/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/294_eco_os_kernel_module/main.sla --out /tmp/294_eco_os_kernel_module.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/294_eco_os_kernel_module/main.sla
```
