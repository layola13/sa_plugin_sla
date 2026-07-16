# issue037: sla_music_cli byte writer loop local is released twice in generated SA

Date: 2026-07-16

Status: fixed and verified

## Summary

The generated-SA backend fails while compiling the `sla_music_cli` test suite
because the loop-local `j` in `byte_writer_push_u64_dec` is released twice:

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__byte_writer_push_u64_dec(&writer: ptr, value: u64):
  line 41482 (expanded 1853):     !j
  register: j
  state: expected Consumed, actual Consumed
```

The failure reproduces twice on music commit
`ecea279f03c70de89fd77298431ee56275dcfd8f` with `sa 0.0.4`.

## Downstream Repro

From `/home/vscode/projects/sla_music_cli`:

```sh
SLA_KEEP_TEST_SA=1 SA_PLUGIN_DEV=1 \
  sa sla test src/music_lower.sla \
  --test-backend sa --jobs 1 --trace-panic
```

The source loop in `src/byte.sla` is:

```sla
let i: u64 = count;
while i > 0 {
    let j = i - 1;
    writer.bytes.push(digits[j]);
    i = j;
}
```

## Generated SA

The generated loop body consumes `j` while copying it into `i`, then emits a
second cleanup for the same local before jumping back to the loop head:

```sa
!i
i = add j, 0
!j
!j
jmp L_WHILE_HEAD_39
```

The first `!j` is sufficient after the scalar copy. The second `!j` causes the
reported `UseAfterMove` with `Consumed/Consumed` state.

## Current Assessment

This is a loop-local cleanup/codegen ownership defect. It is distinct from
issue034/issue035, which concern pointer-backed aggregate field bases. A
scalar local used as the right-hand side of an assignment is consumed by the
assignment lowering and then released again by loop-body scope cleanup.

The music project can temporarily express the countdown without a separate
`j` local, but equivalent valid SLA should compile without a double release.

## Required Closure

- [x] Add a focused compiler fixture with a loop-local scalar assigned into a
  loop-carried scalar before the back edge.
- [x] Ensure assignment lowering and scope cleanup agree on ownership of the
  loop-local value and emit exactly one release.
- [x] Pass the focused generated-SA fixture.
- [x] Pass the downstream `sla_music_cli` command above without a source
  workaround.
- [x] Confirm direct SAB behavior for the focused fixture.

## Resolution

`src/codegen.zig` now tracks top-level locals declared inside loop bodies and
routes `break`/`continue` cleanup through the same loop-local cleanup path used
on natural backedges. Natural backedges use the normal `emitRelease` consumed
guard, while branch cleanup can still force primitive releases where the SA VM
expects an explicit cleanup on that edge.

Focused verification:

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_loop_body_local_cleanup.sla \
  --test-backend sa --jobs 1 --trace-panic

SA_PLUGIN_DEV=1 sa sla test tests/test_unit_loop_body_local_cleanup.sla \
  --jobs 1 --trace-panic
```

Downstream verification from `/home/vscode/projects/sla_music_cli`:

```sh
SA_PLUGIN_DEV=1 sa sla test src/byte.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test src/music_lower.sla --test-backend sa --jobs 1 --trace-panic
```
