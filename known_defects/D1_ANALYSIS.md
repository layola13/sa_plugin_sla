# BM-D1 — macro call nested as a macro argument traps SAB-direct

BG line, 2026-10-28. Status: **characterized, not fixed** (same
open locus as defect 3 α; see below). Repro:
`repro_d1_nested_macro_arg.sla` in this directory.

## Established facts (measured, current BG plugin build)

Probe matrix, all `sa sla test`, MimeType/mime_fill shape from
slanginx's webpath.sla:

| variant | SAB | SA |
|---|---|---|
| dst bound to a local first (`let dst = PTR_BYTE_ADD(..); PTR_COPY_BYTES(dst, ..)`) | pass | pass |
| dst = `&out.bytes` directly | pass | pass |
| dst = `PTR_BYTE_ADD(&out.bytes, 0)` nested inline | **UseAfterMove 1009** (tmp_45) | pass |
| same, unit imported via subdirectory path | **UseAfterMove 1009** | pass |
| same, fn in the SAME file as the test | **UseAfterMove 1009** | pass |

- The trigger is the **nesting form**, not the imported-unit
  position (BM's report framed it as imported-unit because that is
  where slanginx's mime_fill lives; the self-contained repro traps
  identically). In-std uses pass because they pass plain
  identifiers (`dns.sla:851 PTR_COPY_BYTES(dst, src, n)`) or a
  direct address-of (`net_info.sla:217 PTR_COPY_BYTES(&want, ..)`).
- BM's observed signature was UnknownRegister 1007 ("callee is
  not declared", sab line 121 / source line 741); the current
  build reports UseAfterMove 1009 for the same construct. Treat
  these as one family with build-dependent surface signatures:
  SAB-direct std-macro fragment argument binding misregisters the
  inner expansion's temp (compare defect 3 α's AS_STR borrow
  accounting and residual 11's cross-unit SAB 1007s).
- Mechanism sketch: PTR_COPY_BYTES is lowered by sab_codegen via
  emitStdMacroFragment (its body is `call @sa_mem_copy(&%dst,
  &%src, %n)`). The inner PTR_BYTE_ADD is a statement macro: it
  materializes its result into a temp register as a side effect.
  When that temp is produced while evaluating the OUTER macro's
  argument list, the fragment binder appears to treat the temp as
  consumed by the outer call's capability accounting (the `&%dst`
  parameter form), and the referee then reports the temp as used
  after move; in BM's build the same misbinding surfaced as an
  undeclared callee register instead.
- Fix locus candidates (shared with defect 3 α — one discrimination
  experiment serves both): sab_codegen's macro-argument
  materialization must bind a nested macro expansion's result as a
  fresh value register owned by the argument slot, and the
  fragment's `&%param` capability form must not consume it. Not
  attempted here: the fragment machinery is shared by every std
  macro, and a blind change risks the whole corpus (the house
  rule is name-set parity on the macro-heavy families first).
- Workarounds (verified): bind the inner result to a named local
  before the outer macro call; pass `&field` directly when the
  address is a plain field address; byte loop via PTR_BYTE_AT
  (slanginx's shipped workaround — can be reverted when this is
  fixed).
