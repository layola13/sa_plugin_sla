# BM-D2 — bare string literal passed to a by-value `String` parameter

BG line, 2026-10-28. Status: **FIXED on the SA-text backend**
(codegen.zig, this commit); **characterized, not fixed, on the
SAB backend** (fragment out-param locus, below). Repro:
`repro_d2_string_literal_param.sla` in this directory (len,
byte-scan, and ip_addr_parse shapes).

## Symptoms (pre-fix, measured)

`ip_addr_parse("8.8.8.8")` in an @test (slanginx M0 D2):

| shape | SA backend | SAB backend |
|---|---|---|
| generic fn(String) + len() only | **CapabilityMismatch 1013** at the call site | test runs, **len reads wrong** (panic on value assert) |
| generic fn(String) + STR_PTR byte read | CapabilityMismatch 1013 | wrong value |
| ip_addr_parse("8.8.8.8") | CapabilityMismatch 1013 | wrong result; BM observed **SIGSEGV (signal 11)** inside ip.sla's scan loops |
| ip_addr_parse(format("8.8.8.8")) | pass | pass |

## Root cause

The two emitters mishandle the literal → owned-String
materialization in mirror-image ways:

- **SA-text (codegen.zig)**: the value construction was right
  (`genOwnedStringLiteral` → STRING_BUF_FROM_UTF8_UNCHECKED),
  but three hand-rolled call-arg branches (method call, plain
  call, str-associated call) passed the fresh StringBuf register
  PLAIN and freed it in the caller afterwards
  (`.release_after_call = true`). A by-value `String` parameter's
  contract is `(^s: ptr)` — the argument must be MOVED into the
  call (`^reg`, no caller cleanup), exactly as a `format(...)`
  result is passed (verified against emitted SA for variable /
  format / literal forms). Plain-pass + caller-free violates the
  contract: the referee traps CapabilityMismatch on SA.
- **SAB (sab_codegen.zig)**: no materialization exists at all.
  `planCallArgMaterialization` has no owned-string-literal kind,
  so the literal lowers through genExpr to a **Slice register**
  ({ptr, len}) which is passed where a StringBuf is expected.
  The callee reads StringBuf fields out of slice memory: wrong
  length, and in byte-scanning callees (STR_PTR + garbage length)
  wild reads → BM's segfault. This is the String-representation
  split (residual 11 / BB3) at the call boundary.

## Fix (SA-text, shipped in this commit)

In all three branches: for a non-borrow `String` parameter, emit
the materialized register as `^reg` and drop the caller release
(`.release_after_call = false`) — ownership moves to the callee.
The borrow-parameter arm is byte-identical to the previous
behavior (still open, see below).

Evidence (bidirectional, canonical invocation):
- New repro file: baseline plugin SA = CapabilityMismatch trap,
  SAB = 0/3; fixed plugin **SA = 3/3 pass**.
- BM matrix (g1/g2/ip1/ip2): fixed plugin SA all pass.
- String-family name sets (13 pre-existing files × both
  backends, baseline vs fixed): **identical** — the only diff
  lines are the new repro's own.
- The repro is filed here, not in tests/, because it still fails
  on SAB; promote it to the corpus when the SAB side lands.

## SAB side — attempted and reverted; locus characterized

A mirrored fix inside `genPlannedSabCallArg` (materialize via
STRING_BUF_FROM_UTF8_UNCHECKED fragment, or its expansion
STRING_BUF_NEW + STRING_BUF_PUSH_STR) produces a module where
the StringBuf register is **never assigned**: the fragment
emitter loses an out-parameter's assignment whenever the macro
body reaches the assigning instruction through a nested EXPAND
(`call r15, "@sa_vec_with_capacity"` lands in a fragment-internal
register; the caller's named register stays undeclared →
UnknownRegister 1007 at the call). Direct evidence in the
generated SAB disassembly. This is the same nested-fragment
register-bookkeeping family as defect 3 α and BM-D1 (nested
macro forms under SAB-direct), and it needs the same
discrimination experiment before a safe fix: how does
`emitStdMacroFragment` bind a fragment's out-parameter result
back to the caller's register when the expansion is nested —
and why does the genArrayIterCollectStringCall STRING_BUF_NEW
site survive it (different emission context: genExpr stream vs
call-arg text assembly)? The attempted SAB change was reverted;
nothing half-understood ships.

Also still open, same item: a bare literal passed to a
**borrow** (`&String`) parameter keeps the previous (broken)
plain-pass shape on the SA backend — the working form uses an
address temp (`tmp = ptr_add v, 0; call(&tmp)`), which the
literal branches do not yet mirror.
