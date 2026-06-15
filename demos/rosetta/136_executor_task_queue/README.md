# 136 Executor Task Queue

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/136_executor_task_queue/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/136_executor_task_queue/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/136_executor_task_queue/main.sla --out /tmp/136_executor_task_queue.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/136_executor_task_queue/main.sla
```
