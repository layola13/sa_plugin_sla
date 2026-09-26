# issue026: `sa sla check` accepts pointer-add forms that `build/test` reject or lower incorrectly

Date: 2026-07-15
Status: Fixed/verified for the current compiler repro

## Summary

While wiring source-map/output-path skeleton support in `mnt/sla_tsgo`, two related pointer helper forms behaved differently across SLA commands/backends:

1. `sa sla check` accepted `ptr_add` used directly inside a struct literal field and as a `let` initializer.
2. `sa sla build` / `sa sla test --test-backend sab` rejected those same forms during parse/import expansion, or later trapped when the `SLA_PTR_ADD` macro was used.

The project-side workaround was to allocate/copy basename slices instead of returning a pointer-offset slice.

## Repro Shape

This form passed `check` but failed `build` parsing:

```sla
return SourceMapSlice { ptr: ptr_add source, start, len: source_len - start };
```

`build` reported:

```text
found ',', expected colon
```

Moving it to a local still passed `check` but failed `build`:

```sla
let base = ptr_add source, start;
return SourceMapSlice { ptr: base, len: source_len - start };
```

`build` reported:

```text
found 'source', expected semicolon
```

Using the pointer helper macro avoided the parse error but triggered a SAB backend trap:

```sla
let base = source;
SLA_PTR_ADD(base, source, start);
return SourceMapSlice { ptr: base, len: source_len - start };
```

Trap:

```text
error[RegisterRedefinition]: register is already live
register: sla__source_map_base_name__param_0_source
```

## Expected

- `check`, `build`, and `test` should agree on whether `ptr_add` expression forms are legal.
- `SLA_PTR_ADD(out, base, offset)` should not redefine the input parameter register when `out` is a distinct local.

## Resolution

The two observed surfaces have different resolutions:

1. `ptr_add source, start` is SA instruction syntax, not an SLA expression.
   Current installed/dev `sa sla check` and `sa sla build` both reject the
   focused root-file repro at `source` with `expected semicolon`. The earlier
   command disagreement is not reproducible on the current frontend.
2. The legal imported macro form exposed a real direct-SAB bug. Raw `ptr`
   bindings are borrow-like, so `let base = source` can initially alias the
   source parameter register. Imported macro lowering previously treated the
   leading output argument like an ordinary value argument, causing
   `SLA_PTR_ADD(base, source, start)` to emit `ptr_add` into the live source
   parameter register.

`src/sab_codegen.zig` now gives non-expression imported-macro leading outputs
their own destination binding. The binding is installed only after all macro
arguments are lowered and the macro is emitted, preserving correct behavior
when an input and output spelling are the same. Added
`tests/test_unit_ptr_add_macro_output_direct.sla`.

## Verification

Focused serial verification only; no full test suite was run:

- `zig build --summary all`: 7/7 steps passed.
- Focused Zig regression
  `sla sab backend imported ptr add macro output does not redefine input param`:
  2/2 tests passed.
- Local SA-text fixture: 1/1 passed.
- Local strict direct SAB fixture with `SLA_SAB_NO_FALLBACK=1`: 1/1 passed.
- `SA_PLUGIN_DEV=1 sa plugin install --dev .` and
  `SA_PLUGIN_DEV=1 sa sla help`: passed.
- Installed/dev SA-text fixture: 1/1 passed.
- Installed/dev strict direct SAB fixture: 1/1 passed.
- Temporary invalid-syntax repro: installed/dev `check` and `build` both
  rejected `let base = ptr_add source, start;` at the same token.

## Impact

Low for current `sla_tsgo` source-map work because it has a source-level workaround. Medium generally: returning pointer slices into existing buffers is a common compiler/runtime pattern, and command/backend disagreement makes `check` an unreliable preflight for this class of code.

## Current Workaround

The allocation/copy workaround is no longer required for the legal
`SLA_PTR_ADD(out, base, offset)` form. Direct SA instruction syntax such as
`ptr_add source, start` remains invalid in SLA source.
