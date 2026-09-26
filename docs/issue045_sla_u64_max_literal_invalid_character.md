# issue045: explicit SLA `u64::MAX` literal reports `InvalidCharacter`

Date: 2026-07-17

Status: fixed

## Summary

The SLA parser rejected decimal integer literals above `i64::MAX`, including
an explicitly suffixed `u64` literal:

```sla
let max: u64 = 18446744073709551615u64;
```

The failure surfaced while adding checked MIDI note end-tick arithmetic in
`/home/vscode/projects/sla_music_cli`.

## Reproduction

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla \
  --test-backend sa --jobs 1 --trace-panic
```

Parsing stops at the checked tick-range helper with:

```text
error.InvalidCharacter
```

## Root Cause

`parsePrefixExpr` parsed every integer token through `std.fmt.parseInt(i64, ...)`
before inspecting its suffix. The lexer retained `u64`, but the parser failed
before it could construct the existing cast node for that suffix.

## Resolution

`parsePrefixExpr` now identifies the integer suffix before parsing the numeric
payload. Explicit `u64` and `usize` literals parse through `u64` and preserve
their bit pattern in the existing `i64` AST literal payload; unsuffixed and
signed literals still use checked `i64` parsing.

Added `tests/test_unit_u64_max_literal.sla` to cover `18446744073709551615u64`
through unsigned division, modulo, comparison, and logical shift. This relies on
the issue046 unsigned binary lowering fix for generated-SA and direct-SAB
parity.

Focused serial verification passed:

- `zig test src/parser.zig --test-filter "parser accepts explicit u64 max literal suffix"` 1/1.
- `zig build -j1 --summary all` 7/7.
- local generated-SA fixture 1/1.
- local strict direct-SAB fixture 1/1.
- official dev plugin install and `SA_PLUGIN_DEV=1 sa sla help`.
- installed/dev generated-SA and strict direct-SAB fixture 1/1 each.

No full suite was run.

## Historical Workaround

Construct the value through typed arithmetic that stays within the parser's
literal range:

```sla
let max: u64 = 0u64 - 1u64;
```

This allows the music implementation to continue without changing compiler
source.
