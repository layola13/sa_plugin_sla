# 297 Eco Game Engine Ecs

This slot keeps ECS composition observable as transform, velocity, and sprite component types.

- `main.rs`: Rust reference for transform, velocity, and sprite components.
- `main.sla`: Sla companion for transform, velocity, and sprite components.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/297_eco_game_engine_ecs/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/297_eco_game_engine_ecs/main.sla --out /tmp/297_eco_game_engine_ecs.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/297_eco_game_engine_ecs/main.sla
```
