# issue004: plain by-value call args did not consume owned identifiers

## Symptom

A plain by-value function call could type-check, but the source binding stayed
active afterward. That made the cleanup pass emit a release for a value that had
already been moved into the call.

Observed failure:

- `UseAfterMove` / cleanup mismatch in call-heavy SLA code
- regression reproduced by `tests/test_unit_plain_call_arg_consumes_owned_binding.sla`

## Root Cause

`checkCallArgsAgainstSignature` validated plain call arguments, but it never
marked owned identifier arguments as consumed.

The same omission existed on direct closure and function-pointer call paths that
reuse the plain-call matcher.

## Fix

- Added `consumePlainCallArgIfOwned` for plain by-value parameters.
- Wired consumption into signature, closure, fn_ptr, and fallback call checks.
- Only non-Copy, non-borrow-like identifier arguments are consumed.

## Regression

- `tests/test_unit_plain_call_arg_consumes_owned_binding.sla`

## Verification

```sh
zig build
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_plain_call_arg_consumes_owned_binding.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_plain_call_arg_consumes_owned_binding.sla --test-backend sab --jobs 1 --trace-panic
```

## 2026-07-14 Follow-up

Reverified after the call-arg cleanup consolidation:

```sh
zig build -j1 --summary all
SA_PLUGIN_DEV=1 sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_plain_call_arg_consumes_owned_binding.sla --test-backend sa --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_plain_call_arg_consumes_owned_binding.sla --test-backend sab --jobs 1 --trace-panic
```

Both backends pass. The final SA-text fix records ownership-transfer call
arguments in emitter cleanup state; the direct SAB fix also records ABI-inferred
`^` call operands as consumed so local tail cleanup does not release them again.
