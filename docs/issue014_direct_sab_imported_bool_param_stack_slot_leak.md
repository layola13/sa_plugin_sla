# issue014: direct SAB test reports music_ir register leak

Status: resolved on 2026-07-14

## Symptom

`sla_music_cli/src/music_ir.sla` passes with the SA-text backend, but strict
direct SAB test execution fails before running the local music tests:

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla --test-backend sab --jobs 1 --trace-panic
```

Observed SAB failure:

```text
error[MemoryLeak]: live registers remain at function exit
  register: tmp_496
  state: Active
  file: .sla-cache/sab/music_ir-64b5e7bc69283fd5.sab
  line: 3408
```

## Narrowing

Earlier manual SAB build/disassembly appeared to map `tmp_496` to the imported
`music_ast.sla` helper `ast_template_new`:

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla sab build src/music_ir.sla --out /tmp/music_ir.sab
SA_PLUGIN_DEV=1 sa sla sab disasm /tmp/music_ir.sab --out /tmp/music_ir.sa
rg -n "tmp_496|r496|ast_template_new" /tmp/music_ir.sa
```

Relevant generated shape:

```text
func_decl $sla__ast_template_new
    stack_alloc r496,1u
    store r496,0u,r492,ty:1
    ...
    load r501,r496,0u,ty:1
```

The source helper is a pure constructor with a `bool` parameter:

```sla
fn ast_template_new(name: SourceSpan, early: bool, attrs: Vec<MusicAttr>, body: SourceSpan, span: SourceSpan) -> AstTemplateDecl {
    return AstTemplateDecl { name: name, early: early, attrs: attrs, body: body, span: span };
}
```

Further narrowing on 2026-07-14 showed this was not the only failing shape.
`stack_alloc` registers cannot be explicitly released:

```text
error[StackEscape]: stack allocation cannot be released explicitly
  register: end_slot
```

So the fix is not "emit release for all stack_alloc slots". Stack slots appear
to have automatic SAB lifetime; the problematic live register is instead a
direct SAB temporary in generated control flow.

Current direct-SAB observations:

- `SA_PLUGIN_DEV=1 sa sla test src/byte.sla --test-backend sab --jobs 1 --trace-panic`
  passes.
- `SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla --test-backend sa --jobs 1 --trace-panic`
  passes.
- Disabling direct Vec indexing falls back to the std-surface
  `vec_get_slice` / `SLICE_TRY_GET_TYPED_PTR` macro path, but that path still
  reports `tmp_496` as live.
- Re-enabling direct Vec indexing with an explicit bounds-check miss `panic`
  avoids the std macro path, but strict SAB then reports a live temporary in
  the direct Vec index loop path (`tmp_628` in the current build).
- A separate direct SAB cleanup gap was found and partially fixed locally:
  stack-local identifier loads used in binary expressions must be released,
  even though plain identifiers normally do not materialize a temporary.
- 2026-07-14 follow-up:
  - Entry materialization for primitive by-value parameters was narrowed so
    unborrowed/unassigned parameters such as `early: bool` no longer create a
    `stack_alloc` slot just to be read later.
  - A focused regression was added for borrowed Vec field indexing in a loop:
    `tests/test_unit_vec_index_assign.sla`, test
    `"borrowed vec struct field index read in loop"`.
  - Direct Vec indexing still triggers a SAB `PhiStateConflict` on the
    pointer/composite temporary created in the loop body, so the direct
    optimization is currently routed back through the standard surface path.
  - The standard surface path avoids that focused Phi conflict, but
    `sla_music_cli/src/music_ir.sla` still fails strict SAB on a loop-local
    temporary Slice allocation from `SLICE_TRY_GET_TYPED_PTR`:

```text
error[MemoryLeak]: live registers remain at function exit
  register: tmp_472
  state: Active
```

Relevant generated shape:

```text
alloc <slice_tmp>,16u
store <slice_tmp>,0u,<ptr>,ty:12
store <slice_tmp>,8u,<len>,ty:9
...
release <slice_tmp>
```

This keeps issue014 open: the remaining problem is SAB/control-flow state for
loop-local composite temporaries, whether they come from the direct Vec index
path or the std-surface Slice helper path.

The most useful current disassembly shape is in `music_ir_to_source_map_ir`.
The strict SAB failure is exposed around a loop that indexes MusicIR vectors
while building source-map entries. Direct Vec indexing currently generates:

```text
load <index>
load <vec_len>
op.ult <cond>,<index>,<vec_len>
release <vec_len>
br <cond>,<hit>,<hit>,<miss>
...
```

The temporary is visibly released in the disassembly, but the SAB verifier
still reports it live at function exit. This points at a verifier/codegen state
merge issue for direct SAB temporaries inside loop-carried branches, or at a
register identity reuse issue across the loop backedge.

## Resolution

The final reproducible leak shifted to `music_ir_add_note` after the Vec/Slice
and primitive stack-slot fixes:

```text
error[MemoryLeak]: live registers remain at function exit
  register: tmp_955
  state: Active
```

The root cause was direct SAB's all-scalar struct shallow-copy path for struct
literal fields. For a shape such as:

```sla
let note_source_span = span_new(source_start, source_end);
ir.notes.push(MusicIrNote { source_span: note_source_span, ... });
```

direct SAB created a shallow-copy allocation for the `SourceSpan` field but did
not consume the copied field register or release the moved source local. The
source local therefore remained active at function exit even though the field
value had been moved into the containing struct.

Fix:

- mark the copied shallow field value as transferred into the parent struct;
- release the moved source expression after the shallow copy has been created;
- extend `tests/test_unit_vec_push_call_result_struct.sla` with
  `"vec push consumes local struct field copies"`.

Verification:

```sh
cd /home/vscode/projects/sa_plugins/sa_plugin_sla
zig build -j1 --summary all
SA_PLUGIN_DEV=1 sa plugin install --dev .
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_push_call_result_struct.sla --test-backend sab --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_push_call_result_struct.sla --test-backend sa --jobs 1 --trace-panic

cd /home/vscode/projects/sla_music_cli
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla --test-backend sab --jobs 1 --trace-panic
```

Result: the focused compiler fixture passes SA/SAB 2/2, and
`src/music_ir.sla` strict direct SAB passes 4/4.

## Expected

Direct SAB should compile and run `src/music_ir.sla` without live-register
leaks. Compiler-created stack slots should keep their SAB-managed lifetime, and
scalar/vector-index temporaries created inside loop branches should be balanced
at branch joins and loop backedges. SA-text should remain green.

## Current Workaround

None needed for this issue. Keep the strict direct SAB music gate above as the
regression check.

Focused compiler regression that currently passes with the std-surface fallback:

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_index_assign.sla --test-backend sab --jobs 1 --trace-panic
```
