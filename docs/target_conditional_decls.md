# Target-Conditional Declarations: Materialization Specification

Status: normative. Origin: the C-upper ruling of the wasm32 usize
consultation (2026-11-07), which resolved how declarations whose C ABI
width depends on the compilation target are written in SLA sources and
in hand-written SA std units, without giving the SA base (grammar, SAB
encoding, parser, checker) any conditional semantics.

## 1. Problem

A declaration sometimes has to name a C type whose width is a property
of the target, not of the language. The canonical case is libc
`size_t`: 64-bit on native targets, 32-bit on wasm32 (wasi-libc). A
single concrete spelling is wrong on one of the targets — writing
`len: u64` for `mmap` makes every wasm32 call site pass an `i64` where
the callee takes an `i32`, and the wasm validator rejects the module.

The fix is an upper-layer spelling: the source carries one variant per
target, and a materialization step reduces the source to the single
concrete variant for the compilation target before any backend sees
it.

## 2. Spelling

A conditional block is a run of whole comment lines:

```
// @target-begin
// @target native
<native variant lines>
// @target wasm32
<wasm32 variant lines>
// @target-end
```

- `@target-begin` opens a block; `@target-end` closes it. Blocks do
  not nest.
- Inside a block, `// @target <name>` opens the section for target
  `<name>`. The defined target names are exactly `native` and
  `wasm32`.
- Marker lines are recognized after trimming leading and trailing
  whitespace, and must be the whole line. Ordinary comments that merely
  mention the markers mid-line are not markers.
- A block may appear anywhere a comment may appear: around extern
  declarations, around call sites, around constants — the mechanism is
  text-level and layer-agnostic.
- Inside a block, outside any section, only blank lines may appear.

The conditional form is valid input ONLY where an upper-layer
processor materializes it (the SLA front end, the sa_std assembly
points). A hand-written `.sa` file compiled directly for one target
uses that target's concrete spelling, not the conditional form.

## 3. Materialization semantics

Materialization is a pure function
`materialize(source, target) -> source`:

1. Lines outside any block pass through unchanged.
2. At `@target-end`, exactly one section for the requested target must
   have appeared in the block; its lines are emitted and all other
   sections' lines and all marker lines are dropped.
3. The output contains no markers: after materialization the text is
   ordinary SLA/SA source.

Selection is loud, never a fallback. Each of these is a hard error:

| Condition                                             | Error                    |
|-------------------------------------------------------|--------------------------|
| Block has no section for the requested target         | MissingTargetVariant     |
| Same target section appears twice in one block        | DuplicateTargetVariant   |
| Section names an unknown target                       | UnknownTargetName        |
| The selected section has no content lines             | EmptyTargetSection       |
| Section header outside a block                        | TargetSectionOutsideBlock|
| Non-blank content inside a block but outside a section| ContentOutsideTargetSection|
| `@target-begin` inside a block                        | NestedTargetBlock        |
| `@target-end` without a block                         | EndWithoutTargetBlock    |
| End of input inside a block                           | UnterminatedTargetBlock  |

Files that contain no markers are returned unchanged (identity fast
path); a stray section or end marker in an otherwise markerless file
still enters the state machine and fails loudly as above.

## 4. Materialization points

The same specification is implemented at, and only at, these
upper-layer points:

1. **SLA front end** (`sa_plugin_sla`, `src/decl_materialize.zig`):
   every SLA source (root file and every transitively loaded module)
   is materialized with the compilation's declaration target before
   import expansion and parsing. `build-wasm` compiles with target
   `wasm32`; all other commands use `native`. The target participates
   in the compilation freshness digest, so cached artifacts never leak
   across targets. The SA base never sees the conditional spelling.
2. **sa_std assembly** (`sci`, `tools/decl_materialize.zig` wired in
   `build.zig`): SA-implemented std units that carry conditional
   blocks are materialized for the archive's target before the host
   assembler runs. A unit without blocks is assembled in place.
3. **Rust SLA implementation**: must implement this same specification
   and pass the golden corpus below before its conditional-declaration
   support is considered conformant.

## 5. Authoring rules for conditional declarations

- Only audited C-boundary declarations use the conditional form. A
  value that is genuinely 64-bit on every target (a protocol field, a
  file offset, a counter) keeps a plain `u64` declaration; do not
  conditionalize it.
- Target-varying constants (such as syscall flag words whose numbering
  differs per libc) ride the same mechanism as conditional call-site
  lines; never "fix" a constant by unconditionally switching it to one
  target's value.
- When a published signature stays wide (for example an exported
  `(u64, u64)` function) while an extern it calls is narrow on some
  target, the conversion at the internal call site is written
  explicitly in the target's section together with a bounds check that
  fails loudly (a panic), never a silent truncation.
- Call sites are never narrowed implicitly by any tool. If a call does
  not typecheck against the materialized declaration, the source is
  wrong for that target and must say so in its own conditional form.

## 6. Golden corpus

`tests/decl_target/` holds input/expected pairs; the conformance rule
is byte-for-byte equality of `materialize(input, target)` with the
expected file for each target:

- `pair1_conditional.sla` with `pair1_conditional.native.expected` and
  `pair1_conditional.wasm32.expected` — extern width variants plus a
  conditional call-site line carrying a target flag constant.
- `pair2_plain.sla` — no markers; identity for both targets (the file
  itself is the expected output).
- `neg1_missing_variant.sla` — materializing for `wasm32` must fail
  with MissingTargetVariant; for `native` it succeeds.
- `neg
...[truncated 615 chars]
