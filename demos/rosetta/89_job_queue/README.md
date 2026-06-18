# 089 Job Queue

This slot models a job queue that drains work in FIFO order.

- `main.rs`: Rust reference for the queue pop semantics.
- `main.sla`: Sla companion for the queue pop semantics.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/89_job_queue/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/89_job_queue/main.sla --out /tmp/89_job_queue.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/89_job_queue/main.sla
```
