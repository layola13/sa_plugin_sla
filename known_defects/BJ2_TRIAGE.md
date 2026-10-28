# BJ-2 triage — `-> &ptr` extern results as `ptr` arguments

BG line, 2026-10-28. Assignment was triage only (no fix this batch).

## Verdict: compiler defect (sa_plugin_sla type_checker), not std

Probe matrix (all with `@import "sa_std/string.sa"` + `env.sai`,
run via `sa sla test --test-backend sab`; the failure is a checker
error so it surfaces identically on every compile path once the
file's macros resolve):

| shape | result |
|---|---|
| (a) `take_ptr(sa_env_buffer_data(buf))` — user fn, direct | **FAIL** `checkExpr failed at call take_ptr` (TypeMismatch) |
| (b) `let p: ptr = sa_env_buffer_data(buf); take_ptr(p)` | OK |
| (c) `sa_env_get(sa_env_buffer_data(buf), 0)` — extern callee | OK |
| (d) `fn get_data(..) -> ptr { return sa_env_buffer_data(buf); }` | OK |
| (e) `let p = sa_env_buffer_data(buf); take_ptr(p)` — untyped let | **FAIL** (inferred type stays &ptr) |
| (f) callee in an imported .sla unit | **FAIL** (not unit-dependent) |

So the `&ptr` → `ptr` coercion exists in the checker at typed-let
assignment, at return position, and at extern-call arguments, but
is missing at **user-function call arguments** — an inconsistency
in type_checker.zig's call checking (error raised at
type_checker.zig:3150). The four `.sai` declarations
(`sa_env_buffer_data`, `sa_fs_read_buffer_data`, `sa_json_string_ptr`,
`sa_json_buffer_data`, all `-> &ptr`) are semantically right: the
returned value is a plain data pointer and the typed-let
materialization used across the std tree (e.g.
sa_std/http_proxy.sla:1225) is a no-op retype. Changing the
declarations to `-> ptr` would hide this instance and leave the
gap for every other `&ptr`-typed value.

Fix sketch (for whoever picks it up): in the call-argument
compatibility check, accept an argument of type `&ptr` (borrow of
raw_ptr) where the parameter type is `ptr`, mirroring the
assignment/return coercion; add a corpus test from
`repro_bj2_ptr_coercion.sla` in this directory (fails before,
passes after). Also worth checking sibling coercions at the same
site (&u64 → u64 must NOT be added blindly — only the pointer
case is justified by the ABI identity).

Side observation (not part of BJ-2): `sa sla check` reported OK
for the repro file while `STR_PTR` was still unresolvable (missing
string.sa import) — the check verb does not verify test bodies as
deeply as the test path; the UndefinedVariable only surfaced
under `sa sla test`.
