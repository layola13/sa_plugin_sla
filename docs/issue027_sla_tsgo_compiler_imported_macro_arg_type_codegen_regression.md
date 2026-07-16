# issue027: sla_tsgo compiler-importing tests fail SA codegen with importedMacroArgType

Date: 2026-07-15

## Summary

`sla_tsgo` compiler-importing tests type-check and pass under strict SAB, but the SA backend fails during codegen with:

```text
Codegen Error: failed to generate SA code: error.CodegenError
.../sa_plugin_sla/src/codegen.zig:9084:53 in importedMacroArgType
return self.resolvedTypeForExpr(arg) orelse return CodegenError.CodegenError;
```

The error has no SLA source location, making it hard to isolate the source expression. The stack usually continues through `genImportedMacroArg`, `genImportedMacroCall`, and either a branch condition or a while-body expression.

## Repro

From `/home/vscode/projects/mnt/sla_tsgo`:

```sh
SA_PLUGIN_DEV=1 sa sla check tests/test_real_ts_project_reference_flow.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_compiler_contract.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_compile_ts_to_js_text_contract.sla --test-backend sa --jobs 1 --trace-panic
```

Observed:

- `sa sla check tests/test_real_ts_project_reference_flow.sla` succeeds.
- strict SAB `tests/test_compiler_contract.sla` succeeds.
- SA backend codegen fails with the imported macro argument type stack above.

## Impact

This blocks using the SA backend as a secondary verifier for compiler-heavy `sla_tsgo` tests. The current project policy can continue using strict SAB, but the SA error needs a source span or a successful codegen path.

## Notes

During investigation, passing struct-field-derived path pointers through imported macro-heavy helpers such as path byte comparison and output path resolution made this error easier to trigger. The same source type-checks successfully, so the failure appears to be in backend type recovery for imported macro arguments rather than frontend typing.
