# 013 Array Sum

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/13_array_sum/main.rs`.
- `main.sla`: uses a Sla array literal and the same `values.iter().sum()` call shape.

Rust/Sla comparison:

- Rust: `let values = [1, 2, 3, 4];` creates a fixed array.
- Sla: `let values = [1, 2, 3, 4];` creates the same fixed array.
- Rust: `values.iter().sum()` builds an iterator and sums the elements.
- Sla: `values.iter().sum()` lowers to `sa_std/array.sa` and `sa_std/core/iter.sa` macros: `ARRAY_AS_SLICE_U64`, `ITER_FROM_SLICE`, and `ITER_SUM_U64`.
- Rust output: `println!("{sum}");`.
- Sla output: validates the sum and prints `10` through `sa_std/io/print.sai`.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/13_array_sum/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/13_array_sum/main.sla --out /tmp/13_array_sum.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/13_array_sum/main.sla
```
