# 230 Mod Std Prelude

This slot keeps the std prelude surface observable as three imported symbols: `Option`, `Result`, and `println`.

- `main.rs`: Rust reference for `Option`, `Result`, and `println` from the prelude.
- `main.sla`: Sla companion for `Option`, `Result`, and `println` from the prelude.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/230_mod_std_prelude/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/230_mod_std_prelude/main.sla --out /tmp/230_mod_std_prelude.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/230_mod_std_prelude/main.sla
```
