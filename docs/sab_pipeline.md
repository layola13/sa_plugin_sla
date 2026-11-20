# SLA Direct SAB Output Pipeline

> This is the English counterpart of the Chinese document [SLA 直接输出 SAB 管线](./sab_pipeline_cn.md).

> The normative specification for the SAB format is the sala repository's [SAB Format Whitepaper (Specification)](https://github.com/layola13/sala/blob/main/content/03_sa_asm/08_sab_whitepaper.html) (round-trip L1/L2 layering, prohibition of SAB downgrade to text, version-compatibility policy); this document records only this plugin's pipeline, coverage, and error boundaries.

## Goals

SAB is SA's binary IR file format — not a compressed `.sa` text archive, nor a container that puts `.sa` source into a section. This plugin currently maintains two parallel mainlines:

- `sa sla build`: continues to output `.sa` text, serving debugging and the existing text pipeline.
- `sa sla sab ...` / `sa slab ...`: outputs SAB bytes directly from the SLA frontend, so the SA compiler reads the `.sab` and proceeds into the verifier/backend/linker.

It is forbidden to implement the SAB mainline as `sla -> sa text -> sab`. The current `compileSlaFileToSab` path is:

```text
SLA source
  -> source_expand
  -> parser AST
  -> SLA import expansion
  -> monomorphizer
  -> type checker
  -> sab_codegen.generate
  -> SAB binary bytes
```

This path does not call `compileSlaToSaString`, does not write temporary `.sa` files, and does not reparse through the SA text flattener.

## Prerequisites and Installation Order

The SAB mainline depends on the SA compiler side already supporting `.sab` input. In the development environment, build/install SA from the `sci` repository first, then install the SLA plugin:

```bash
cd /home/vscode/projects/sci
./tools/install.sh --no-shell

cd /home/vscode/projects/sa_plugins/sa_plugin_sla
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla
```

`sa build` / `sa build-exe` / `sa run` / `sa test` on the SA side recognize `.sab` input and skip the `.sa` text flattener, passing the SAB-decoded structured instructions directly to the verifier/backend. The SLA plugin's `build-exe` and `sab workspace` both rely on this to hand the `.sla-cache/sab/...` managed files to the SA compiler as stable input.

After installation, use the following commands to confirm that the dev plugin and the current capability surface are loaded:

```bash
SA_PLUGIN_DEV=1 sa plugin list
SA_PLUGIN_DEV=1 sa sla help
SA_PLUGIN_DEV=1 sa sla skills --json
```

`sa sla skills --json` must output JSON; if it outputs text, the host did not forward JSON mode to the plugin, or an old plugin / old SA binary was loaded.

## CLI Behavior

### `sa sla init` / `sa sla skills`

```bash
sa sla init [path]
sa sla skills [--json]
```

- `init` creates a minimal SLA binary project: `sa.mod`, `src/main.sla`, `.gitignore`.
- `.gitignore` includes `.sla-cache/` by default, to avoid committing managed SAB and subsequent incremental cache artifacts into the repository.
- `skills --json` outputs the plugin capability JSON; text mode generates `.codex/skills/sla/SKILL.md` and `.claude/skills/sla/SKILL.md` in the current directory.

### `sa sla sab build`

```bash
sa sla sab build [file] [-p <package>] [--out <file.sab>]
sa slab build [file] [-p <package>] [--out <file.sab>]
```

The default behavior is managed caching; no user-visible `.sab` is generated next to the source:

```text
.sla-cache/sab/<stem>-<source-path-hash>.sab
```

This path is retained stably for reuse in subsequent incremental compiles. When `--out` / `-o` is passed, an additional user-specified `.sab` is written, while the managed SAB in `.sla-cache/sab/` is still retained.

### `sa sla sab workspace`

```bash
sa sla sab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe-options...]
sa slab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe-options...]
```

Workspace mode resolves `sa.mod` from the current directory, selects the default member or the member specified by `-p/--package`, directly generates the managed SAB into `.sla-cache/sab/`, then calls `sa build-exe <managed.sab> ...`.

- By default, no `.sab` is dropped next to the source.
- `--sab-out <file.sab>` additionally writes a specified SAB file.
- `--emit-sab` additionally writes a sibling `.sab` for manual inspection.
- The input passed to `sa build-exe` is the stable `.sla-cache/sab/...` path, facilitating SA incremental cache hits.

`sa sla build-exe <file.sla>` also follows the same direct SAB managed path: it first generates `.sla-cache/sab/...`, then calls `sa build-exe <managed.sab> ...`. It no longer generates temporary `.sa` text as an intermediate mainline.

### `sa sla test`

```bash
sa sla test [file] [-p <package>] [--test-backend auto|sab|sa] [sa-test-options...]
```

The default `auto` backend follows the SAB mainline: the SLA frontend generates `.sla-cache/sab/...`, then calls `sa test <managed.sab> ...`. Direct AST-to-SAB is the only emission path; if it encounters an SLA feature not yet covered, `sab_codegen` returns `UnsupportedSabDirectFeature`, reports a loud error, and fails compilation — it does not switch to any text or compatibility path (the in-memory SA-compatible fallback was removed on 2026-09-28, commit `e96e6b39`; for the governance position prohibiting SAB downgrade to text, see [SAB Format Whitepaper](https://github.com/layola13/sala/blob/main/content/03_sa_asm/08_sab_whitepaper.html) §4.2). SCI's general SAB v4 encoder covers SA `InstKind` / `OpKind` / operand tags and preserves backend metadata such as function registers, native registers, package identity, and upstream location; v4 no longer stores the full `.sa` raw_text for each instruction.

- `--test-backend sab`: force the SAB mainline; suitable for verifying that the old `.test.sa` backend is not used.
- `--test-backend sa`: force the old `.test.sa` text test path.
- `--emit-sab`: additionally write a sibling `.sab` for manual inspection; the managed SAB remains in `.sla-cache/sab/`.

### `sa sla sab disasm`

```bash
sa sla sab disasm <file.sab> [--out <file.sa>]
sa slab disasm <file.sab> [--out <file.sa>]
```

Disassembly is for debugging/inspection only and is not part of the compilation mainline.

## SAB v4 Layout

```text
magic:          4 bytes = "SAB\0"
version_major:  u8 = 4
version_minor:  u8 = 0
section_count:  uleb128

section*:
  id:           uleb128
  len:          uleb128
  payload:      len bytes
```

Current sections:

- `1 symbol_pool`: symbol names, function names, labels, short text tokens. The instruction stream references symbol ids.
- `2 function_sigs`: function signatures, parameter capabilities, parameter types, return types, function kind, parameter registers, function register sets.
- `3 const_decls`: constant declarations and structured literals.
- `4 instructions`: instruction kind, source line, op kind, atomic metadata, operands.

A full `.sa` source section is not allowed. The v4 instruction payload does not write raw instruction text; it keeps only the necessary structured operands and short operand strings, such as call body operands, atomic expected/new operands, and const literal text. `sab disasm` is a debug disassembler and is not part of the compilation mainline.

## Currently Supported Subset

The direct SAB backend currently covers:

- Functions and `@test` declarations.
- Basic type mapping for `i*` / `u*` / `int` / `bool` / `void` / pointer/borrow.
- Parameters, `let`, `return`, expression statements.
- Phase 1 scalar `var`: `var x: T` directly generates `stack_alloc`, whole-value assignment generates `store`, reads generate `load`; supports current i32/bool scalar slots and reads after branch merges.
- Identifier assignment and basic `while` loops.
- Integer and boolean literals, identifiers, binary arithmetic/comparison/bitwise operations.
- Direct function calls using symbols already resolved by the type checker, supporting ordinary multi-argument calls.
- Generic layout lowering for plain struct literals, field access, and struct returns.
- Language-level function pointer values and calls: named functions / generic specializations used as `fn(...) -> T` values generate structured vtable consts; calls through function pointer parameters and local variables directly generate `load` + `call_indirect`.
- Ordinary closure binding and calls: `let f = |x| ...; f(arg)` is generated in direct SAB with an inlined closure body + parameter register mapping; supports capturing outer local values and current one-/two-argument closure smoke tests, without entering fallback.
- First batch of std surface metadata bridging: `sla_std/std_surface.sla_meta` uses data to describe how associated functions, methods, and indexing sugar expand into imported SA macro fragments, and filters/merges SAB modules by the dependency functions actually used. `sab_codegen.zig` only reads rules, resolves imports, expands macro fragments, and merges structured SAB; it does not hard-code `Vec`, `thread`, ECS, or business-library semantics.
- Basic control flow from `if/else` to `br` / label / `jmp` / merge.
- Chained `if let` / value-producing `if let`: the shared `planLetPattern()` classifies Option/Result/user-enum tag checks; SAB only handles the concrete `br` / label / result-slot merge / cleanup emission; rosetta `104_if_let_chains` strict direct-SAB no-fallback has passed.
- Array-to-slice borrow `&[T; N] -> &[T]` for ordinary planned static calls: the shared `CallArgMaterializationKind.array_to_slice_borrow` handles semantic classification; SAB only handles stack `Slice`/`SLICE_NEW` materialization and temporary backing array cleanup; `tests/test_unit_array_to_slice_call.sla` local/host SA-text and strict direct-SAB no-fallback have passed.
- `panic(code)`.
- In-function `reg_ids` metadata and local releases before void/test returns, satisfying the SA verifier's scope and leak checks.

Silent fallback has been reduced to zero and is expressly forbidden: uncovered SLA features explicitly return `UnsupportedSabDirectFeature` and fail compilation, with no compatibility path to continue. Going forward, these coverage gaps must be removed through general direct lowering or general SAB macro/stdlib representations; ordinary code semantics must not be hard-coded in the compiler by `Vec`, `thread`, ECS, or business-library names.

The current priority is to keep expanding the std surface metadata, exportable closure/function-object lowering, the shared lowering rules/plan layer, and SAB macro representations — rather than copying legacy library branches from the text codegen into `sab_codegen.zig`. The target shape is `SLA AST/typecheck -> shared lowering rules/plan -> {SA text emitter, SAB structured emitter}`. The compiler may understand language constructs, type information, imported macro signatures, and the SAB instruction format; ordinary library names, container algorithms, thread APIs, and ECS rules should remain at the std / plugin / project layer. The focused zero-arg `thread::spawn(^|| ...)` capturing closure, ordinary planned call array-to-slice borrow, and `/home/vscode/projects/sla_ecs/lib/parallel.sla` no-fallback path have all passed; the remaining work is to generalize entry-function/function-object lowering and continue refining the shared plan layer for result destinations, remaining call materialization, and macro argument address semantics — rather than writing `thread` or other library-specific branches in the SAB backend.

To investigate direct SAB gaps, use:

```bash
SA_PLUGIN_DEV=1 sa sla test <file.sla> --test-backend sab --filter "..."
```

A direct lowering failure reports an error immediately (historically there was a `SLA_SAB_NO_FALLBACK` switch controlling whether to enter the compatibility fallback; the fallback was removed with the 2026-09-28 governance decision, and this environment variable is no longer read by the source code).

## Verification Record

The most recent narrow verifications all avoided full test suites:

- SCI build: `zig build -Doptimize=Debug`, passed; SAB focused Zig tests `zig test src/sab.zig --test-filter sab` passed, covering every SA `InstKind` / `OpKind` / operand tag with decoded instruction `raw_text` empty.
- SCI structured backend regression: `zig test src/emit_llvm_llvmc.zig --test-filter "assignOperand resolves localized const vtable slots"` passed, covering function-pointer/vtable const address lowering when v4 SAB has no raw_text.
- SCI call/interp regression: `zig test src/interp.zig --test-filter call` passed, covering structured `parseInstructionCall`.
- Direct regressions: `zig build test -Dtest-filter="sla sab backend lowers plain structs directly" --summary all`, `zig build test -Dtest-filter="sla sab backend lowers function pointers directly" --summary all`, and `zig build test -Dtest-filter="sla sab backend lowers multi-argument calls directly" --summary all` all passed, and these tests use `allow_fallback = false`.
- Direct function-pointer CLI regression: `./zig-out/bin/sla-local-cli sla test tests/test_unit_fn_ptr_value.sla --filter "function pointer can be passed as argument" --test-backend sab --jobs 1 --trace-panic`, `--filter "generic function specialization can be passed as argument"`, and `--filter "function pointer survives struct return"` passed, with only `sab direct codegen` appearing in the profile.
- Direct std surface regression: `zig build test -Dtest-filter="sla sab backend lowers imported std surface metadata directly" --summary all` passed; `SLA_SAB_NO_FALLBACK=1 SLA_PROFILE=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_fn_ptr_value.sla --filter "function pointer survives vec push through function" --test-backend sab --jobs 1 --trace-panic` passed, confirming this case did not use fallback and that the decoded instructions' `raw_text` is empty. Currently `sab direct codegen` on this path takes about 7.4s, with the bottleneck coming from the full encode/decode/verify merge of std import/macro fragments; going forward, the SCI bridge should add a filtered verified-SAB-fragment interface rather than falling back to raw text or directly splicing an unverified `FlattenResult`.
- Direct closure regression: `zig build test -Dtest-filter="sla sab backend lowers closure calls directly" --summary all` passed; `SLA_SAB_NO_FALLBACK=1 SLA_PROFILE=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_closures.sla --test-backend sab --jobs 1 --trace-panic` passed, with `sab direct codegen` at about 2-8ms.
- Direct var/control-flow regression: `zig build test -Dtest-filter="sla sab backend lowers var scalar slots directly" --summary all` passed; `SLA_SAB_NO_FALLBACK=1 SLA_PROFILE=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_var_phase1.sla --test-backend sab --jobs 1 --trace-panic` passed, covering scalar `var` stack slots, assignment, reads after if-branch merges, and basic while. This round also fixed direct SAB branch-condition cleanup: temporary conditions are released separately in then/else or loop body/exit, and local/parameter conditions are not erroneously consumed.
- Direct no-fallback update: `tests/test_unit_fn_ptr_value.sla --filter "thread closure captures function pointer callee"` and `/home/vscode/projects/sla_ecs/lib/parallel.sla` have passed no-fallback verification. Ordinary closure calls, the focused zero-arg escaping thread closure, captured function-pointer callees, and the corresponding spawn wrappers are covered; the remaining gap is to generalize this entry-function/function-object lowering to more exported closure shapes and to move call/argument materialization rules up into the shared lowering plan layer — this cannot be solved by writing `thread` special cases in the compiler.
- SAB end-to-end: after `SA_PLUGIN_DEV=1 sa sla sab build tests/test_unit_fn_ptr_value.sla --out /tmp/test_unit_fn_ptr_value_v4.sab`, `/home/vscode/projects/sci/zig-out/bin/sa test /tmp/test_unit_fn_ptr_value_v4.sab --compile-only` passed; `test_unit_spaceship_cmp.sla` and `test_unit_using_static_extension.sla` passed as well.
- Performance spot checks: for the same `test_unit_fn_ptr_value`, `sa test <v4.sab> --compile-only` took about 3.31s-4.39s versus about 11.31s for the raw `.sa` path; the SA backend consuming SAB is clearly faster. SAB generation by the `sa sla sab build` frontend is still slower than `sa sla build`, measured this round at about 3.66s vs 0.12s; the remaining bottleneck is the SA-compatible flatten/verify/encode and cache writing during the SLA->SAB generation stage.
- Plugin build: `zig build`, passed.
- Default managed SAB: `timeout 120s ./zig-out/bin/sla-local-cli sla sab build tests/test_sab_direct.sla`, output `.sla-cache/sab/test_sab_direct-...sab`.
- Explicit file output: `timeout 120s ./zig-out/bin/sla-local-cli sla sab build tests/test_sab_direct.sla --out /tmp/sla_direct_out.sab`; the magic of `/tmp/sla_direct_out.sab` is `53 41 42 00`.
- Workspace: `PATH=/home/vscode/projects/sci/zig-out/bin:$PATH timeout 120s .../sla-local-cli sla sab workspace --sab-out /tmp/sla_workspace_app.sab -o /tmp/sla_workspace_app`, which generated the workspace `.sla-cache/sab/...sab`, `/tmp/sla_workspace_app.sab`, and an executable.
- Host SA installation verification: `/home/vscode/projects/sci/tools/install.sh --no-shell`, followed by `SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla`.
- Host plugin capability verification: `SA_PLUGIN_DEV=1 sa sla help` shows `init` / `skills` / `sab workspace --sab-out`; `SA_PLUGIN_DEV=1 sa sla skills --json` outputs JSON; `SA_PLUGIN_DEV=1 sa sla init /tmp/sa_host_sla_init` generates `sa.mod` and `src/main.sla`.
- Host SAB verification: `SA_PLUGIN_DEV=1 sa sla sab build tests/test_sab_direct.sla` outputs `.sla-cache/sab/test_sab_direct-...sab`.
- Default test-backend verification: `timeout 120s ./zig-out/bin/sla-local-cli sla test tests/test_sab_direct.sla --filter "direct sab add"` passed; `timeout 120s ./zig-out/bin/sla-local-cli sla test tests/test_unit_fn_ptr_value.sla --filter "function pointer can be stored and called"` passed and preserved SAB `call_indirect`.
- Installed-plugin verification: `timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_sab_direct.sla --filter "direct sab add"` passed; `timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_unit_fn_ptr_value.sla --filter "function pointer can be stored and called"` passed. `sa plugin install --dev` produced no output and timed out at this round's 5-minute cap; because the manifest/lock had not changed, the installed `current` and `0.1.0` shared libraries were updated with the build artifact `zig-out/lib/libsla.so`, and the hashes were confirmed to match.
- ECS performance verification: `timeout 120s env SA_PLUGIN_DEV=1 sa sla test /home/vscode/projects/sla_ecs/lib/parallel_table_erased.sla --filter "table erased readonly parallel runner executes no conflict systems on threads"` passed, at about 19.30s after installation with MaxRSS about 153MB. The local profile shows parse 0.62s, import expand 1.58s, SA-compatible flatten 4.04s, SAB encode 5.22s, and `sa test <managed.sab>` alone about 13.50s; the 2-3s target has not yet been reached, with the remaining bottleneck in SAB fallback flatten/encode and the SA-side test compile/link/incremental behavior.
- Filtered Zig tests:
  - `timeout 120s zig test ... --test-filter "sla sab build defaults to managed sla cache"`
  - `timeout 120s zig test ... --test-filter "sla sab build emits direct SAB without SA source output"`
  - `timeout 120s zig build test -Dtest-filter="sla sab backend supports SA-compatible indirect call lowering"`
  - `timeout 120s zig build test -Dtest-filter="sla delegated SA commands default to jobs auto unless supplied"`
  - `timeout 120s zig build test -Dtest-filter="sla sab test managed path is scoped by test filter"`
  - `timeout 120s zig build test -Dtest-filter="sla test sab backend prunes unmatched tests before type checking"`

Full `sci` or plugin test suites were not run; full suites would cause unnecessary CPU/memory pressure.
