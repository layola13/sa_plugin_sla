# 009 Async Await

This directory pairs a Rust async/await reference with a Sla companion.

- `main.rs`: Rust async/await with `SystemTime`, `Instant`, and a real `thread::sleep` delay.
- `main.sla`: Sla native async/await using `sa_std/time.sai` for unix time, monotonic time, and real sleep.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/09_async_await/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/09_async_await/main.sla --out /tmp/09_async_await.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/09_async_await/main.sla
```
