# 296 Eco Gpu Ptx Shader

This slot keeps PTX-style GPU integration observable as one compute kernel entry.

- `main.rs`: Rust reference for one PTX-style compute kernel entry.
- `main.sla`: Sla companion for one compute kernel entry.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/296_eco_gpu_ptx_shader/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/296_eco_gpu_ptx_shader/main.sla --out /tmp/296_eco_gpu_ptx_shader.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/296_eco_gpu_ptx_shader/main.sla
```
