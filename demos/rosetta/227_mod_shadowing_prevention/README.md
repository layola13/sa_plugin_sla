# 227 Mod Shadowing Prevention

This slot keeps module-name shadowing diagnostics observable as one rejected duplicate binding.

- `main.rs`: Rust reference for rejecting one duplicate module binding.
- `main.sla`: Sla companion for rejecting one duplicate module binding.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/227_mod_shadowing_prevention/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/227_mod_shadowing_prevention/main.sla --out /tmp/227_mod_shadowing_prevention.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/227_mod_shadowing_prevention/main.sla
```
