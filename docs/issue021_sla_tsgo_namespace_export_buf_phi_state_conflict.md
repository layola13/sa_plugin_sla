# issue021: direct SAB reports PhiStateConflict for ptr parameter consumed in early-return branches

Date: 2026-07-15

## Context

While expanding `/home/vscode/projects/mnt/sla_tsgo` emitter coverage for real
TypeScript-to-JavaScript text flows, `sa sla check` accepted the source and test
contracts, but direct SAB failed before executing the tests.

The affected code is in:

```text
/home/vscode/projects/mnt/sla_tsgo/members/emitter/src/emitter.sla
```

The current trigger is the namespace export rewrite helper chain around
`emit_js_rewrite_namespace_export_after_let`. The helper receives a `buf: ptr`
parameter and has an early-return branch that appends to the buffer, plus an
`else` branch that tail-calls the next helper with the same `buf`.

## Observed commands

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla check members/emitter/src/emitter.sla
SA_PLUGIN_DEV=1 sa sla check tests/test_emitter_js_text_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_emitter_js_text_contract.sla --test-backend sab
```

The two `check` commands pass. The direct SAB test fails with:

```text
error[PhiStateConflict]: incoming control-flow states do not agree
  register: buf
  state: expected Consumed, actual Active
{"trap":"PhiStateConflict","trap_code":1015,"file":".sla-cache/sab/test_emitter_js_text_contract-2d31e50c4ffa8aa6.sab","line":14108,...,"register":"buf","expected_mask_name":"Consumed","actual_mask_name":"Active",...}
```

Disassembly near the trap shows the conflict in the generated
`sla__emit_js_rewrite_namespace_export_after_let` function:

```text
call r7133,"@sla__emit_js_namespace_var_assignments","sla__emit_js_rewrite_namespace_export_after_let__param_0_buf, ..."
...
return_ r7137
label $L_ELSE_2257
...
call r7139,"@sla__emit_js_rewrite_namespace_export_after_var","sla__emit_js_rewrite_namespace_export_after_let__param_0_buf, ..."
...
return_ r7139
```

## Reduced source shape

The problematic shape is approximately:

```sla
fn rewrite_after_let(buf: ptr, off: int, src: ptr, src_len: int) -> Result {
    let check = skip_ws(src, src_len, 0);
    if keyword_at(src, src_len, check) {
        let stmt_end = statement_end(src, src_len, check);
        let o = off;
        o = append_range(buf, o, src, check, stmt_end);
        return result(true, o, stmt_end);
    } else {
        return rewrite_after_var(buf, off, src, src_len);
    };
}
```

Adding an explicit `else` does not avoid the conflict; SAB still appears to
merge parameter ownership state for `buf` across already-returning branches.

## Expected

For a `ptr` parameter used as an output buffer, passing it to helper calls in
mutually exclusive early-return branches should not require identical consumed
state at an internal merge point when both branches return.

The SA frontend type checker currently accepts the source.

## Workaround being attempted

The `sla_tsgo` emitter is being refactored to avoid passing the same `buf`
parameter through branch-tail helper chains. The likely workaround is to compute
the namespace export kind first, then consume/use `buf` in a simpler tail path.

