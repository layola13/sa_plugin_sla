# 014 Slice Window

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/14_slice_window/main.rs`.
- `main.sla`: uses Sla array range slicing and the same `values[1..3].iter().sum()` call shape.

Rust/Sla comparison:

- Rust: `let values = [1, 2, 3, 4];` creates a fixed array.
- Sla: `let values = [1, 2, 3, 4];` creates the same fixed array.
- Rust: `values[1..3]` creates a two-element slice window over elements `2` and `3`.
- Sla: `values[1..3]` lowers to a pointer window at the same start offset and type-checks as a two-element window.
- Rust: `.iter().sum()` sums the window to `5`.
- Sla: `.iter().sum()` lowers the two-slot window through `ARRAY_AS_SLICE_U64`, `ITER_FROM_SLICE`, and `ITER_SUM_U64`, then asserts `5`.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/14_slice_window/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/14_slice_window/main.sla --out /tmp/14_slice_window.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/14_slice_window/main.sla
```
