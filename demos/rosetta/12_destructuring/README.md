# 012 Destructuring

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/12_destructuring/main.rs`.
- `main.sla`: uses native Sla tuple destructuring.

Rust/Sla comparison:

- Rust: `let (x, y) = (2, 5);` destructures a tuple into two bindings.
- Sla: `let (x, y) = (2, 5);` performs the same tuple destructuring.
- Rust: `let sum = x + y;` computes `7`.
- Sla: `let sum = x + y;` computes the same value and the test asserts `7`.
- Rust output: `println!("{sum}");`.
- Sla output: validates the computed sum and prints `7` through `sa_std/io/print.sai`.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/12_destructuring/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/12_destructuring/main.sla --out /tmp/12_destructuring.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/12_destructuring/main.sla
```
