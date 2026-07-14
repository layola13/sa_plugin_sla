# issue009: SA codegen missed literal types inside nested imported macros

## Summary

The SA-text backend could type-check a nested imported macro call but then fail
during code generation when the imported macro received a string literal
argument.

Observed in `sla_music_cli` while generating normalized SLA text:

```sla
byte_writer_push_str(&out, STR_PTR("track "), STR_LEN("track "));
```

The direct SAB backend passed, but SA-text failed in `genImportedMacroArg`
because `resolvedTypeForExpr` could not recover a type for the string literal
inside `STR_PTR`.

## Fix

`resolvedTypeForExpr` now mirrors the type checker's basic literal fallback and
also recovers return types for function calls, imported function signatures, and
expression-output imported macros such as `_PTR`, `_LEN`, `_ADD`, `_NULL`, and
typed pointer reads.

The type checker now also assigns concrete return types to the same std pointer
facade macros so locals initialized from `PTR_BYTE_ADD(...)` are not left as
`infer` in later imported macro calls.

## Regression

Added:

```text
tests/test_unit_str_ptr_literal_arg_sa.sla
tests/test_unit_ptr_byte_add_read_type_sa.sla
```
