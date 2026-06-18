# 272 Build Sanitizer Flags

This slot keeps sanitizer configuration observable as address and undefined-behavior flags enabled together.

- `main.rs`: Rust reference for address and UB sanitizers enabled together.
- `main.sla`: Sla companion for address and UB sanitizers enabled together.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/272_build_sanitizer_flags/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/272_build_sanitizer_flags/main.sla --out /tmp/272_build_sanitizer_flags.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/272_build_sanitizer_flags/main.sla
```
