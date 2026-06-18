# 121 Rwlock Reader Writer

This directory now records the current rwlock gap honestly.

- `main.rs`: Rust reference using `Arc<RwLock<i32>>`, a spawned reader, joined result, exclusive write, and final read.
- `main.sla`: Sla surrogate for the same observable flow, but the current checked path still leaves the shared `Arc` live at function exit.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/121_rwlock_reader_writer/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/121_rwlock_reader_writer/main.sla --out /tmp/121_rwlock_reader_writer.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/121_rwlock_reader_writer/main.sla
```
