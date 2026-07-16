# issue037: sla_music_cli byte writer loop local is released twice in generated SA

Date: 2026-07-16

Status: open

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

- Add a focused compiler fixture with a loop-local scalar assigned into a
  loop-carried scalar before the back edge.
- Ensure assignment lowering and scope cleanup agree on ownership of the
  loop-local value and emit exactly one release.
- Pass the focused generated-SA fixture.
- Pass the downstream `sla_music_cli` command above without a source
  workaround.
- Confirm direct SAB behavior for the focused fixture.
