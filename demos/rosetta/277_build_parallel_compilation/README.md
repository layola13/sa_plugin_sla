# 277 Build Parallel Compilation

This slot keeps parallel code generation observable as parser, checker, optimizer, and emitter units running concurrently.

- `main.rs`: Rust reference for parser/checker/optimizer/emitter units in parallel.
- `main.sla`: Sla companion for parser, checker, optimizer, and emitter units running concurrently.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/277_build_parallel_compilation/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/277_build_parallel_compilation/main.sla --out /tmp/277_build_parallel_compilation.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/277_build_parallel_compilation/main.sla
```
