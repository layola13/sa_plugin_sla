# 015 String Bytes

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/15_string_bytes/main.rs`.
- `main.sla`: uses a string literal and the same `word.len()` method-call shape.

Rust/Sla comparison:

- Rust: `let word = "rust";` creates a string slice value.
- Sla: `let word = "rust";` lowers the string literal to an SA UTF-8 constant pointer.
- Rust: `word.len()` returns the byte length `4`.
- Sla: `word.len()` lowers through the local `len` function and returns the same byte length `4` for this UTF-8 literal.
- Rust output: `println!("{}", word.len());`.
- Sla output: validates the length and prints `4` through `sa_std/io/print.sai`.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/15_string_bytes/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/15_string_bytes/main.sla --out /tmp/15_string_bytes.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/15_string_bytes/main.sla
```
