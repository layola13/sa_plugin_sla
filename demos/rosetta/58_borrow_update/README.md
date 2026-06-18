# 058 Borrow Update

This directory now records the current borrow-update surrogate honestly.

- `main.rs`: Rust reference using a real `&mut i32` borrow passed into `bump(...)`.
- `main.sla`: Sla surrogate that preserves the same final value observable through `Cell<i32>` interior mutation.
