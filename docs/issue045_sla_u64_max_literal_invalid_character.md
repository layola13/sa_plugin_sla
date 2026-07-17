# issue045: explicit SLA `u64::MAX` literal reports `InvalidCharacter`

Date: 2026-07-17

Status: open

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

## Current Workaround

Construct the value through typed arithmetic that stays within the parser's
literal range:

```sla
let max: u64 = 0u64 - 1u64;
```

This allows the music implementation to continue without changing compiler
source.

## Proposed Resolution

Inspect the suffix before parsing the literal payload. Explicit `u64` and
`usize` literals can parse through `u64` and retain their bit pattern in the
existing `i64` AST payload, while unsuffixed and signed literals continue to
use checked `i64` parsing.

The regression should cover both generated-SA and direct-SAB output. During
the abandoned local experiment, parsing succeeded but unsigned division of
the resulting value behaved as signed division, so unsigned binary operation
selection also needs verification before closing this issue.
