# 261 Build Rs Codegen Saasm

This slot keeps Rust-side SA-ASM code generation observable as one emitted module.

- `main.rs`: Rust reference for one emitted SA-ASM module.
- `main.sla`: Sla companion for one emitted SA-ASM module.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/261_build_rs_codegen_saasm/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/261_build_rs_codegen_saasm/main.sla --out /tmp/261_build_rs_codegen_saasm.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/261_build_rs_codegen_saasm/main.sla
```
