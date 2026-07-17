# issue046: SLA unsigned binary operations lower as signed operations

Date: 2026-07-17

Status: open

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
