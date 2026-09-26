# issue033: sla_tsgo parse_jsx_like_expression fails SA with UseAfterMove

Date: 2026-07-16

Status: fixed and verified

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

## Root Cause

This is not issue032's repeated source-name register collision. The repeated
`let after_lt` declarations receive generated lexical binding names such as
`tmp_5839`. SA-text field lowering treated every `tmp_*` field base as a
temporary expression result, so reading `after_lt.current_kind` emitted
`!tmp_5839`. The branch then reused the live aggregate binding in
`advance(after_lt)`, causing `UseAfterMove`.

Assigned/addressable identifier loads can also produce genuine `tmp_*`
temporaries, so removing temporary cleanup globally would leak those values.
The release decision must distinguish a generated register that is the
resolved lexical binding from a genuine loaded expression temporary.

## Required Closure

- [x] Derive a focused plugin fixture from the repeated aggregate field-read
  and whole-value reuse shape.
- [x] Distinguish resolved lexical bindings from genuine temporary field
  bases.
- [x] Keep tuple, ManuallyDrop, and ordinary struct field cleanup behavior
  aligned.
- [x] Verify the focused fixture in local and installed SA/strict-SAB modes.
- [x] Confirm the downstream compile-to-JS SA contract advances beyond
  `parse_jsx_like_expression`.

## Resolution

`src/lowering_rules.zig` now owns `fieldBaseResultNeedsRelease()`. The shared
rule preserves a temporary-looking register when it is the resolved binding
for the identifier expression, while retaining cleanup for genuine generated
temporaries. `src/codegen.zig` supplies the emitter-local register and lexical
binding facts at all three field-release sites.

`tests/test_unit_sa_assigned_ptr_aggregate_slot.sla` now includes two sibling
`let after_lt` declarations. Before the fix, the new test reproduced:

```text
error[UseAfterMove]
in @sla__rebind_repeated_aggregate_field_reuse(^parser: ptr) -> ptr
tmp_208 = load tmp_192+0 as ptr
register tmp_192
expected Consumed, actual Consumed
```

Focused serial verification:

- Shared lowering-rule Zig test: 1/1.
- `zig build -j1 --summary all`: 7/7.
- Local SA and strict SAB fixture: 3/3 each.
- Official dev install/help.
- Installed/dev SA and strict SAB fixture: 3/3 each.
- Downstream compile-to-JS SA contract advanced past
  `parse_jsx_like_expression` and now stops at the independent issue036
  `emit_js_skip_class_member_modifiers` `PhiStateConflict`.

No full compiler or downstream test suite was run.
