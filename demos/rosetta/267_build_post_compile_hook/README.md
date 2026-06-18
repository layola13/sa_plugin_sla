# 267 Build Post Compile Hook

This slot keeps post-compile processing observable as one stripped binary artifact.

- `main.rs`: Rust reference for one stripped binary artifact.
- `main.sla`: Sla companion for one stripped binary artifact.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/267_build_post_compile_hook/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/267_build_post_compile_hook/main.sla --out /tmp/267_build_post_compile_hook.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/267_build_post_compile_hook/main.sla
```
