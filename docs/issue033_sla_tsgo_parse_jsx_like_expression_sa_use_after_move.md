# issue033: sla_tsgo parse_jsx_like_expression fails SA with UseAfterMove

Date: 2026-07-16

## Summary

After issue032's repeated lexical `let` register isolation fix, the
`sla_tsgo` compile-to-JS contract advances to a separate SA verifier failure:

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__parse_jsx_like_expression(^p: ptr) -> ptr:
  line 58994 (expanded 19148): tmp_5862 = load tmp_5839+0 as ptr
  register: tmp_5839
  expected Consumed, actual Consumed
```

The source function is:

```text
/home/vscode/projects/mnt/sla_tsgo/members/ast/src/parser.sla:338
fn parse_jsx_like_expression(p: Parser) -> Parser
```

It repeatedly reassigns the pointer-backed `Parser` aggregate `p2` across
nested conditionals, recursive JSX parsing, loop backedges, and early returns.

## Repro

From `/home/vscode/projects/mnt/sla_tsgo` after installing the current plugin
in dev mode:

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_compile_ts_to_js_text_contract.sla \
  --test-backend sa --jobs 1 --trace-panic
```

## Current Assessment

This is not issue032's repeated source-name register collision. The failing
register is a generated temporary holding a pointer-backed aggregate copy or
slot load, and the verifier observes a load after that temporary has already
been consumed. The likely surface is SA-text aggregate reassignment/value
copy lifecycle across the nested branch and recursive-call paths in
`parse_jsx_like_expression`.

## Required Closure

- Derive a focused plugin fixture from the `p2` branch/reassignment shape.
- Identify the exact generated temporary producer and the path that consumes
  it before the later field load.
- Fix the shared aggregate call/reassignment lifecycle decision where
  possible, keeping SA register emission local to `src/codegen.zig`.
- Verify only the focused fixture and downstream compile-to-JS SA contract
  serially. Do not run a full test suite.
