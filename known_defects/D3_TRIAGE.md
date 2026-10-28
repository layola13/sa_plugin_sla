# BM-D3 — direct `sa_print_bytes` calls trap CapabilityMismatch: TRIAGE

BG line, 2026-10-28. Verdict: **compiler defect (SA-text
extern-call lowering)**; the std declaration is correct. No fix
attempted (triage-only per assignment). Repro:
`repro_d3_print_bytes.sla` in this directory.

## Evidence (measured)

- Declaration (sci `sa_std/io/print.sai:3`, duplicated in
  `io.sai:25`): `@extern sa_print_bytes(&msg: ptr, len: u64)`.
  Hand-written SA call sites honor it: `io.sa:11/15`
  `call @sa_print_bytes(&%msg, %len)`.
- Direct SLA calls, all argument forms:
  - string literal `sa_print_bytes("hello", 5)`: SA backend
    **CapabilityMismatch 1013**; SAB passes.
  - ptr variable (STR_PTR of a format String): SA backend
    **CapabilityMismatch 1013** — not literal-specific.
  - `println("hello")`: passes both backends (compiler builtin
    with its own emission, which includes the borrow form).
- Emitted SA for a helper fn: `call @sa_print_bytes(p, tmp_0)` —
  the borrow prefix required by the &msg contract is missing.

## Adjudication

- **Owner: sa_plugin_sla's SA-text extern-call lowering.** When
  an extern parameter carries the `&` capability in its .sai
  declaration, a plain pointer argument must be emitted as
  `&arg`. The emitter passes the register plain, and the sci
  referee correctly rejects it. The SAB emitter passes the same
  source (it has an extern-borrow operand path,
  `externBorrowCallOperand` in sab_codegen.zig) — the asymmetry
  is part of the defect record.
- **Not a std problem**: changing the .sai to drop `&` would
  contradict io.sa's hand-written calls and the actual borrow
  semantics of the C ABI function.
- Relation to the registered resp_send_v2 CapabilityMismatch:
  same contract mechanism, different owner — that one is a std
  macro body missing `&%body` (sci text); this one is the SLA
  compiler's extern-argument emission. BM's "same family" guess
  is half right.
- Scope honesty: most &-param externs are reached from SLA via
  std wrappers/macros that already satisfy the contract, which
  is why this stayed invisible; the two proven failing shapes
  are direct calls with literal and ptr-variable arguments.
  Fix sketch: in the SA-text extern payload call emission, when
  the .sai param is borrow-capability and the lowered argument
  is a plain register, emit `&reg` — mirroring the SAB path;
  corpus test from the repro (must pass both backends; SAB
  already passes, so it guards the SA fix directly).
