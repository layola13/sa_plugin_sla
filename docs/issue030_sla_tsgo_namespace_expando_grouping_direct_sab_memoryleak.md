# issue030: sla_tsgo namespace expando grouping direct-SAB MemoryLeak

Date: 2026-07-15

Status: fixed and reverified on 2026-07-16.

## Summary

While extending `mnt/sla_tsgo` declaration emit to group namespace-local function expando aliases, the focused declaration contracts pass under strict direct SAB, but the JS emitter contract that imports the same emitter module fails during SAB verification with a register-cleanup `MemoryLeak`.

This looks backend-owned rather than a declaration behavior assertion failure:

- `tests/test_emitter_contract.sla` passes with the new helper-level `.d.ts` behavior.
- `tests/test_compile_ts_to_js_text_contract.sla` passes with the new Program-backed `.d.ts` flow.
- `tests/test_compiler_contract.sla` passes.
- `tests/test_emitter_js_text_contract.sla` fails before test assertions with a SAB verifier `MemoryLeak`.

## Repro

From `/home/vscode/projects/mnt/sla_tsgo`:

```sh
timeout 45s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_emitter_js_text_contract.sla --test-backend sab --jobs 1 --trace-panic
```

Observed:

```text
error[MemoryLeak]: live registers remain at function exit
  register: tmp_7672
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/test_emitter_js_text_contract-2d31e50c4ffa8aa6.sab","line":22145,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"tmp_7672","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

The generated `.sab` file has fewer textual lines than the reported verifier line, so the current trap does not map cleanly back to source text.

## Passing adjacent gates

```sh
timeout 45s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_emitter_contract.sla --test-backend sab --jobs 1 --trace-panic
```

Result: `50 passed; 0 failed; 0 skipped`.

```sh
timeout 90s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_compile_ts_to_js_text_contract.sla --test-backend sab --jobs 1 --trace-panic
```

Result: `42 passed; 0 failed; 0 skipped`.

```sh
timeout 90s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_compiler_contract.sla --test-backend sab --jobs 1 --trace-panic
```

Result: `41 passed; 0 failed; 0 skipped`.

## Triggering code shape

The new `sla_tsgo` declaration path groups namespace-local expando assignments such as:

```ts
namespace N {
  export enum C { C }
  export function A(): string { return "A"; }
  A.a = C;
  A.b = C;
}
```

Expected skeleton output:

```ts
declare namespace N {enum C { C } function A(): string; namespace A { export { C as a }; export { C as b }; }}
```

Several source-level rewrites still reproduced the same `tmp_7672` leak in `test_emitter_js_text_contract.sla`, including:

- Avoiding `DtsExpandoParts` as a helper argument.
- Replacing a `while` grouping loop with single lookahead.
- Moving lookahead parsing into a smaller helper.
- Rewriting namespace-local parsing to scalar locals instead of using the top-level expando parser struct.

## Impact

This blocks using `tests/test_emitter_js_text_contract.sla` as a clean regression gate for the current `sla_tsgo` namespace-local expando grouping increment. The focused declaration gates are still green and prove the intended `.d.ts` behavior.

## Root cause

The failing register was not created by the namespace expando declaration grouping helper. Disassembling the generated SAB showed `tmp_7672` was the first argument temp for the final JS emitter test:

```text
call "@sla__js_text_check","tmp_7672, tmp_7673, tmp_7674, tmp_7676, tmp_7678"
```

That argument is a by-value raw `ptr` loaded from a local stack slot and passed into a `void` helper. Direct SAB correctly avoided releasing raw pointer values, but it also skipped consuming the stack-slot load temporary at the call site. For `void` calls the verifier does not infer that the callee's parameter cleanup consumes that caller-side temporary, so the temp remained `Active` at function exit.

## Fix

`src/sab_codegen.zig` now treats by-value raw `ptr` call arguments loaded from local stack slots as non-owning temporaries that must be consumed after the call with `move_`, not released and not propagated back to the source stack slot. Function-exit cleanup also consumes by-value raw `ptr` params rather than leaving direct parameter registers active.

Regression coverage was added to `tests/test_unit_ptr_value_arg_reuse.sla`:

- by-value `ptr` stack-slot params can still be reused after non-void calls;
- by-value `ptr` stack-slot temps are consumed after void calls;
- a `js_text_check`-style multi-argument text comparison void call consumes stack-slot pointer temps.

## Fixed verification

From `/home/vscode/projects/sa_plugins/sa_plugin_sla`:

```sh
timeout 45s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_ptr_value_arg_reuse.sla --test-backend sab --jobs 1 --trace-panic
zig build test -Dtest-filter="direct sab normal sig keeps by-value ptr params raw" --summary all
timeout 300s env SA_PLUGIN_DEV=1 sa plugin install --dev .
```

Results:

```text
test_unit_ptr_value_arg_reuse.sla: 4 passed; 0 failed; 0 skipped
zig build test filter: 2/2 tests passed
```

From `/home/vscode/projects/mnt/sla_tsgo` after installing the dev plugin:

```sh
timeout 45s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_emitter_js_text_contract.sla --test-backend sab --jobs 1 --trace-panic
timeout 90s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_emitter_contract.sla --test-backend sab --jobs 1 --trace-panic
timeout 90s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_compile_ts_to_js_text_contract.sla --test-backend sab --jobs 1 --trace-panic
timeout 90s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_compiler_contract.sla --test-backend sab --jobs 1 --trace-panic
```

Results:

```text
test_emitter_js_text_contract.sla: 23 passed; 0 failed; 0 skipped
test_emitter_contract.sla: 50 passed; 0 failed; 0 skipped
test_compile_ts_to_js_text_contract.sla: 42 passed; 0 failed; 0 skipped
test_compiler_contract.sla: 41 passed; 0 failed; 0 skipped
```
