# issue040: sla_music_cli music_ir strict SAB stops at UnsupportedSabDirectFeature

Date: 2026-07-16

Status: fixed

## Summary

While closing issue034, the original `sla_music_cli/src/music_ir.sla` generated
SA backend repro passed, and the focused compiler Vec-element field fixture
also passed under strict direct SAB. The full downstream `music_ir.sla` strict
SAB path still fails differently:

```text
SAB Direct Error: direct SLA-to-SAB lowering failed without fallback: error.UnsupportedSabDirectFeature
```

This is not the issue034 generated-SA `UseAfterMove` on a consumed Vec element
field base.

## Repro

From `/home/vscode/projects/sla_music_cli`:

```sh
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 \
  sa sla test src/music_ir.sla --test-backend sab --jobs 1 --trace-panic
```

## Current Assessment

The first unsupported direct-SAB construct was the selection-sort comparison in
`music_patch_sort_hunks`:

```sla
if music_patch_hunk_less(&hunks[j], &hunks[best]) == true {
    best = j;
};
```

Direct SAB already had Vec `index_address` std-surface metadata, but
`genIndexAddress()` only allowed non-array container address lowering when the
element type was a smart pointer. `MusicPatchHunk` is a pointer-backed ordinary
struct, so `&hunks[j]` was rejected before the Vec address rule could lower it.
For borrowed call arguments, the lowered address must also load the element
object pointer from the Vec slot before emitting the borrow operand.

## Required Closure

- [x] Identify the first unsupported direct-SAB construct in `src/music_ir.sla`.
- [x] Add a focused compiler fixture for that unsupported surface.
- [x] Verify the focused fixture under strict direct SAB and generated SA.
- [x] Re-run the downstream `music_ir.sla` strict SAB command.

## Fix

- `src/sab_codegen.zig` now allows std-surface `index_address` lowering for
  `Vec<T>` even when `T` is an ordinary pointer-backed struct.
- Borrowed call arguments of the form `&vec[index]` now load the stored object
  pointer before emitting the borrow operand, matching the existing field
  projection behavior for pointer-backed struct values.
- `tests/test_unit_vec_index_assign.sla` adds
  `vec struct dynamic index borrow and swap`, a focused selection-sort style
  fixture covering `&values[j]`, `&values[best]`, and dynamic Vec struct
  element swaps.

## Verification

Serial focused verification only; no full test suite was run.

```sh
zig fmt --check src/sab_codegen.zig
git diff --check
zig build -j1 --summary all
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_vec_index_assign.sla --test-backend sab --jobs 1 --trace-panic --filter "vec struct dynamic index borrow and swap"
./zig-out/bin/sla-local-cli sla test tests/test_unit_vec_index_assign.sla --test-backend sa --jobs 1 --trace-panic --filter "vec struct dynamic index borrow and swap"
SA_PLUGIN_DEV=1 sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_vec_index_assign.sla --test-backend sab --jobs 1 --trace-panic --filter "vec struct dynamic index borrow and swap"
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_index_assign.sla --test-backend sa --jobs 1 --trace-panic --filter "vec struct dynamic index borrow and swap"
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test src/music_ir.sla --test-backend sab --jobs 1 --trace-panic
```

The downstream `music_ir.sla` strict SAB run passed 26/26.
