# issue024: sla_tsgo direct SAB struct-literal move handling

Date: 2026-07-15
Status: resolved for the original compile-contract blocker; parser residual also cleared project-side

## Context

`/home/vscode/projects/mnt/sla_tsgo/tests/test_compile_ts_to_js_text_contract.sla`
previously failed SAB verification before any TypeScript output assertion ran.
The generated code for `parsed_command_line_default()` stored fields from nested
copy structs and then fenced or released registers that SAB already considered
consumed.

The failing shape was observed in generated code similar to:

```text
load  r31067,r31060,40u,ty:5
store r31061,40u,r31067,ty:5
fence "^tmp_21670"
```

## Root cause

Direct SAB struct-literal generation did not consistently preserve source-level
move intent:

- Explicit `^value` fields could be planned as copies when the field type was a
  copy struct.
- Last-use copy-struct identifier fields were shallow-copied even when move
  elision was valid.
- Identifier moves could store a generated temporary and then mark or release
  the same source again.

This produced a post-store use of an already consumed register in sufficiently
large generated programs.

## Compiler changes

The fix is implemented in:

- `src/lowering_rules.zig`
- `src/sab_codegen.zig`

The direct SAB path now:

- Preserves explicit `^value` as a move even for copy-struct fields.
- Applies last-use move elision to eligible copy-struct identifier fields.
- Stores identifier move sources directly.
- Marks pending moved locals after struct construction without emitting a
  second use of the consumed store operand.

Focused compiler regressions cover explicit moved copy-struct fields and direct
SAB struct-literal transfer behavior.

## Verification

The original program-backed compile contract is now green:

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla test tests/test_compile_ts_to_js_text_contract.sla \
  --test-backend sab --jobs 1 --trace-panic
```

Result on 2026-07-15:

```text
17 passed; 0 failed; 0 skipped
```

Related green checks:

```text
test_emitter_js_text_contract.sla: 20/20
test_parsed_command_line_min.sla: 6/6
sa_plugin_sla test_unit_tsconfig_buffer_cleanup.sla: 5/5
sa_plugin_sla test_unit_unused_multi_param_return_const_direct.sla: 1/1
```

## Parser residual follow-up

The full parser contract previously reached runtime and passed 202/204 tests,
with two import-scanner assertions failing:

```text
parser scans import specifiers: panic code 459
parser scans side effect import but ignores attributes: panic code 462
```

This was cleared project-side on 2026-07-15. `parse_import_specifiers(...)` now
keeps scanner state in `ImportSpecifierConsumeResult` and explicitly consumes up
to the two retained import slots, avoiding the fragile struct-value merge across
the scan loop.

Reproduction:

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla test tests/test_parser_contract.sla \
  --test-backend sab --jobs 1 --trace-panic
```

Current result:

```text
204 passed; 0 failed; 0 skipped
```

The original issue024 `UseAfterMove` compile blocker is resolved, and the
downstream parser import-scan residual is no longer open.

## Project-side limitation

`mnt/sla_tsgo/members/module/src/resolver.sla` is still temporarily reduced:
URL resolution, node builtins, bare package/node_modules/hash resolution return
not-found or false, and some buffer helpers are absent. These reductions are
not part of the issue024 fix and must not be treated as completed TypeScript
module resolution.
