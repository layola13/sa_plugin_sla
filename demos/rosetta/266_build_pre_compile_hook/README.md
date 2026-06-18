# 266 Build Pre Compile Hook

This slot keeps pre-compile hook execution observable as one schema-check phase before code generation.

- `main.rs`: Rust reference for one schema-check phase before codegen.
- `main.sla`: Sla companion for one schema-check phase before code generation.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/266_build_pre_compile_hook/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/266_build_pre_compile_hook/main.sla --out /tmp/266_build_pre_compile_hook.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/266_build_pre_compile_hook/main.sla
```
