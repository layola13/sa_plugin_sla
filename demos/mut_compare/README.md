# SLA vs Rust `&mut` — Comparison Demos

Two demos for the 2026-11-20 ruling that SLA has no `&mut` by deliberate
design, not by omission: `&T` covers read and write, and the SA Referee
judges `Locked_Read` / `Locked_Mut` from the actual load/store instructions.
Cell / RefCell are only for genuinely shared interior state, never a
toll-booth for borrow mutation.

| Demo | What it shows |
|---|---|
| [01_borrow_read_write](./01_borrow_read_write/README.md) | One `&i32` signature for read and write; Rust needs `&i32` + `&mut i32`. Prints `100`, `110`. |
| [02_spawn_boundary](./02_spawn_boundary/README.md) | Borrows must not cross a task boundary (`go` and `thread::spawn` closure both rejected at check); the sanctioned crossing is ownership transfer through channels. Prints `50`. |

Commands (from the `sa_plugin_sla` repo root):

```bash
SA_PLUGIN_DEV=1 sa sla check demos/mut_compare/01_borrow_read_write/main.sla
SA_PLUGIN_DEV=1 sa sla test demos/mut_compare/01_borrow_read_write/main.sla
SA_PLUGIN_DEV=1 sa sla build-exe demos/mut_compare/01_borrow_read_write/main.sla -o /tmp/mut01 && /tmp/mut01
SA_PLUGIN_DEV=1 sa sla check demos/mut_compare/02_spawn_boundary/main.sla
SA_PLUGIN_DEV=1 sa sla build-exe demos/mut_compare/02_spawn_boundary/main.sla -o /tmp/mut02 && /tmp/mut02
```

Companion sala page: `09_rust_compare/11_mut_borrow_compare.html`
("No &mut by Design"), in both language trees.

## Rust implementation parity

The two defects behind these demos existed in the Rust implementation too,
because the Rust parser/checker were ported from Zig including the bugs —
and both were fixed there by the same shapes:

| Defect | Zig plugin | Rust `layola13/sla` |
|---|---|---|
| Prefix `*`/`&`/`^` operands parsed at precedence 6, so `*value = *value + 10` parsed as `*(value + 10)` | `1d3b850c` (`src/parser.zig`, 6 -> 8) | `26b5137f` (`crates/sla-parser/src/prefix.rs`, `parse_expr(6)` -> `(8)`) |
| `thread::spawn` closure borrowing an enclosing-scope place was accepted | `2b65a1dd` (`src/type_checker.zig`, `checkSpawnClosureBorrowEscape`) | `b06c05ee` (`crates/sla-checker/src/check_spawn_guard.rs` + hook in `leaf_thread_spawn`) |

Regression tests are byte-identical on both sides:
`corpus/tests/test_unit_deref_binop_operand.sla` (3 @test),
`corpus/tests/test_error_spawn_closure_borrow_arg.sla`,
`corpus/tests/test_error_spawn_closure_borrow_capture.sla`.
The `neg_spawn_closure_indirect_borrow.sla` file in demo 02 (`let r = &number;`
then `spawn(^|| modify(r))`) is rejected with `error.BorrowEscape` by both
implementations. `await` still parses its operand at precedence 6 in both —
deliberately untouched, it needs its own ruling.

Run the same files through the Rust binary
(`cargo build --release -p sla-cli` in `layola13/sla`, then
`./target/release/sla check <file.sla>` /
`./target/release/sla test tests/<file> --test-backend sa`):
demo 01 checks and tests green, both spawn negatives reject with
`BorrowEscape`, demo 02 and the p3/p4/p5 probes check green.
