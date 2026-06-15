# 011 Tuples

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/11_tuples/main.rs`.
- `main.sla`: uses native Sla tuple literals and numeric tuple fields.

Rust/Sla comparison:

- Rust: `let pair = (3, 4);` creates a tuple value.
- Sla: `let pair = (3, 4);` creates the same two-field tuple value.
- Rust: `pair.0` and `pair.1` read tuple fields.
- Sla: `pair.0` and `pair.1` lower to field loads at tuple offsets.
- Rust output: `println!("({}, {})", pair.0, pair.1);`.
- Sla output: validates both fields and prints `(3, 4)` through `sa_std/io/print.sai`.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/11_tuples/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/11_tuples/main.sla --out /tmp/11_tuples.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/11_tuples/main.sla
```
