# 096 Task Orchestrator

This directory now records the current task-orchestrator gap honestly.

- `main.rs`: Rust reference for the dependency-and-retry adjusted task score semantics used by this slot.
- `main.sla`: current Sla companion shape for the same scoring intent, but the checked path still leaves `task` live at function exit locally.
