# issue046: SLA unsigned binary operations lower as signed operations

Date: 2026-07-17

Status: fixed/verified

## Summary

Ordinary SLA binary expressions do not select unsigned comparison, division,
remainder, or right-shift instructions from their resolved operand types.

This surfaced while implementing checked MIDI note end-tick arithmetic in
`/home/vscode/projects/sla_music_cli`. A parsed `u64::MAX` experiment failed:

```sla
let max: u64 = 18446744073709551615u64;
if max / 2u64 != 9223372036854775807u64 { panic(33201); };
```

The generated-SA test reached the assertion but panicked because division used
signed semantics.

## Root Cause Evidence

The generated-SA emitter's `binaryOpName` receives only an `is_float` flag.
For every integer type it emits:

```text
div rem slt sle sgt sge shr
```

The direct-SAB emitter's `opKindForBinary` similarly emits:

```text
sdiv srem slt sle sgt sge ashr
```

even when the type checker resolved the operands as `u8`, `u16`, `u32`,
`u64`, or `usize`.

## Impact

Unsigned arithmetic and ordering above `i64::MAX` can produce incorrect
results in both fallback and direct backends. This also prevents application
code from implementing overflow checks with ordinary `u64` comparisons.

## Current Workaround

Music imports `sa_std/num.sa` and calls `NUM_U64_CHECKED_ADD`, whose verified
SA macro body uses the native `ult` instruction. This keeps the music
implementation moving without changing compiler source.

## Proposed Resolution

- Select `udiv`, `urem`, `ult`, `ule`, `ugt`, `uge`, and `lshr` when the
  resolved integer operand type is unsigned.
- Share the signed/unsigned operation selection between generated-SA and
  direct-SAB lowering.
- Add focused parity regressions for high-bit `u64` values under both backends.

## Resolution

Shared scalar binary lowering now selects signed, unsigned, and floating-point
opcodes from resolved operand types. Generated-SA and direct SAB both consume
that shared operation plan, while async continuation comparisons keep their
explicit signed condition helper.

The focused regression `tests/test_unit_unsigned_binary_ops.sla` covers high-bit
`u64` division, remainder, ordering, and right shift without depending on the
separate `u64::MAX` literal parser blocker tracked as issue045.

During direct-SAB verification, the fixture also exposed a SAB encoding edge:
large nonnegative integer literals such as `9223372036854775807u64` could still
be emitted as signed immediates and trip SCI's signed LEB128 reader. Direct SAB
now emits typed unsigned integer literals, and nonnegative immediates that need
the 64-bit signed-LEB sign-extension byte, as `imm_u64`.

## Verification

Serial focused gates passed on 2026-07-17:

- `zig test src/lowering_rules.zig --test-filter "shared scalar binary plan selects unsigned high bit operations"`: 1/1.
- `zig build -j1 --summary all`: 7/7.
- Local generated-SA fixture: `./zig-out/bin/sla-local-cli sla test tests/test_unit_unsigned_binary_ops.sla --test-backend sa --jobs 1 --trace-panic`: 1/1.
- Local strict direct-SAB fixture: `SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_unsigned_binary_ops.sla --test-backend sab --jobs 1 --trace-panic --no-incremental`: 1/1.
- Generated-SA inspection contains `udiv`, `urem`, `ule`, `ult`, `uge`, `ugt`, and `lshr`.
- Direct-SAB disassembly contains `op.udiv`, `op.urem`, `op.ule`, `op.ult`, `op.uge`, `op.ugt`, and `op.lshr`, and the high-bit literal disassembles as `9223372036854775807u`.
- Official dev gate: `SA_PLUGIN_DEV=1 sa plugin install --dev .` and `SA_PLUGIN_DEV=1 sa sla help`.
- Installed/dev generated-SA fixture: 1/1.
- Installed/dev strict direct-SAB fixture: 1/1.

No full test suite was run.
