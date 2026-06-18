# 264 Build Env Var Injection

This slot keeps build-environment configuration observable as one injected profile variable.

- `main.rs`: Rust reference for one injected build profile variable.
- `main.sla`: Sla companion for one injected build profile variable.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/264_build_env_var_injection/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/264_build_env_var_injection/main.sla --out /tmp/264_build_env_var_injection.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/264_build_env_var_injection/main.sla
```
