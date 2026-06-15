# 062 Channel Pingpong

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/62_channel_pingpong/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/62_channel_pingpong/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/62_channel_pingpong/main.sla --out /tmp/62_channel_pingpong.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/62_channel_pingpong/main.sla
```
