# issue006: direct SAB double-releases imported macro move arguments

Status: fixed/verified for the imported-macro move-argument double-release
surface.

## Summary

Direct SAB lowered imported macros with value arguments as release-after-call
temps even when the imported macro body consumed the placeholder with a move
prefix.

The observed case was:

```sla
let status = FS_READ_BUFFER_FREE(buffer);
```

`FS_READ_BUFFER_FREE` expands to a direct call equivalent to:

```sa
call @sa_fs_read_buffer_free(^buffer)
```

The generated SAB moved the loaded buffer temp into the extern call and then
emitted a second `release` for the same temp, causing strict SAB validation to
fail with `UseAfterMove`.

## Fix

Direct imported macro lowering now treats `SLA_FS_BUFFER_FREE` argument `0` as
consumed by the direct macro emission and suppresses the extra release for that
materialized value.

## Regression

Added:

```text
tests/test_unit_imported_macro_move_arg_free.sla
```

The test reads an existing source file with `sa_fs_read_file` and frees the
buffer with `FS_READ_BUFFER_FREE(buffer)` under strict SAB.
