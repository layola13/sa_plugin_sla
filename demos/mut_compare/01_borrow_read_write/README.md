# 01 Borrow: Read and Write Through One Borrow Type

Rust splits borrows in the type system: `read(&i32)` vs `modify(&mut i32)`.
SLA has only `&i32` for both. The SA Referee judges `Locked_Read` /
`Locked_Mut` from the actual load/store instructions, so a function
signature does not change when its implementation starts writing — and the
direct translation of the Rust `&mut` example needs no `Cell` / `RefCell`.

- `main.rs`: Rust reference. Two signatures, `&i32` and `&mut i32`.
- `main.sla`: SLA companion. One signature, `&i32`, for both `read` and
  `modify`. Also covers `modify_binop` (`*value = *value + 10`), the
  dereference-plus-binary-operator form whose parse was fixed in
  sa_plugin_sla `1d3b850c` (before that fix the checker rejected it).

Verified 2026-11-20 on sa 0.1.9 + sa_plugin_sla 2b65a1dd (box bd00ae7b9304):

```bash
SA_PLUGIN_DEV=1 sa sla check demos/mut_compare/01_borrow_read_write/main.sla
SA_PLUGIN_DEV=1 sa sla test demos/mut_compare/01_borrow_read_write/main.sla
SA_PLUGIN_DEV=1 sa sla build-exe demos/mut_compare/01_borrow_read_write/main.sla -o /tmp/mut01 && /tmp/mut01
# prints 100 then 110, exit code 0
```

Expected output of the binary: `100` on the first line (read), `110` on the
second line (after modify). The Rust reference prints the same two lines.
