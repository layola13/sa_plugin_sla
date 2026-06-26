# SLA FAQ

> Snapshot: 2026-06-22. This FAQ describes the current `sa_plugin_sla`
> implementation and intended direction. When source and older design notes
> disagree, the current compiler implementation is the stronger signal.

## A. Language Positioning And Design Goals

**1. What is SLA's core design goal? Where should it beat Rust / C / Zig / Go?**

SLA is a statically typed frontend for SA. Its main goal is to make SA's
ownership, cleanup, branch-merge, and low-level safety rules usable from a
higher-level language. It should beat C/Zig in compiler-managed cleanup safety,
beat raw SA in ergonomics, and be simpler than Rust for data-oriented systems
that do not need Rust's full lifetime surface.

**2. Which values does SLA emphasize most?**

The priority order is: simple semantics, predictable lowering to SA, explicit
data layout, static type checking, compiler-managed cleanup, and practical
systems/ECS ergonomics. It is not meant to hide all costs like a dynamic
scripting language.

**3. Is SLA a systems language, data-oriented language, engine language, or general language?**

SLA should remain a general SA frontend with strong data-oriented and systems
programming bias. It must not hard-code ECS or game-engine keywords into the
compiler.

**4. What mental model should users have?**

Think "Rust-like syntax + Zig/C-style directness + SA ownership underneath".
Variables are simple, control flow is direct, but the compiler still tracks
resources and emits releases.

**5. What non-mainstream design point is worth keeping?**

SLA keeps variables mutable by default and prefers explicit data movement over a
large borrow-checker vocabulary. That is intentional, but the compiler still
needs strong resource tracking.

## B. Variables, Assignment, And Value Semantics

**6. Does default mutability mean rebinding, field mutation, or both?**

For `let`, it means the local binding may be assigned again and owned aggregate
fields/elements may be updated when the value is available. `const` is the
immutable-binding form.

**7. Is `x = ...` always legal after `let x = ...`?**

It is legal when `x` is a mutable local and the right-hand side type matches.
It is not legal for `const`, missing bindings, or values whose ownership state
has already been consumed.

**8. Are function parameters passed by value by default?**

Yes. A parameter written as `x: T` is an owned/value parameter. Borrowed
parameters are written with `&`, such as `x: &T`.

**9. After passing by value, is the caller's value still usable?**

For scalar/copy-like values, yes. For owned heap/resource values, passing by
value should be treated as ownership transfer unless the API is explicitly a
borrow. Use return values or `&T` APIs for state that must remain available.

**10. Does SLA have move semantics?**

Yes. The compiler models owned values and cleanup, and `^expr` is the explicit
move operator in the language surface.

**11. Do small structs such as `Entity` have automatic copy semantics?**

Scalar fields and field reads are copy-like. Small plain-data structs can opt in
with `@derive(copy)`, which makes `let b = a;` and plain by-value calls generate
an independent field-wise copy instead of transferring the original binding.

**12. What does `let b = a;` mean?**

It is type-dependent. Primitive values are copied. Owned resource/container
values should be treated as moved/ownership-transferred unless the specific type
or API provides clone/copy behavior.

**13. Are built-in scalars copy values?**

Yes: integers, floats, and booleans are copy-like values.

**14. Can the original object still be used after reading a struct field?**

For normal field reads, yes. This is covered by current tests such as struct
field copy not moving the owner.

**15. In `world.entities = allocator;`, is `world` a local copy or caller state?**

If `world` was passed as `world: World`, it is the function's local owned value.
To update the caller, return the updated world or use a borrow-based API.

**16. Does SLA distinguish binding mutability and object-content mutability?**

Partially. `const` protects rebinding. Object/content mutation is mainly
controlled by ownership/borrow state and the type's APIs, not by a Rust-like
`mut` split.

**17. Is multiple assignment such as `a, b = b, a` supported?**

No stable language-level multiple assignment is documented. Use temporaries.

**18. Is field destructuring assignment such as `{x, y} = point` supported?**

Tuple destructuring exists. Struct-pattern destructuring is not a mature
general feature yet.

**18a. Does SLA support the blank identifier `_` in bindings and destructuring?**

Yes. `_` is treated as a discard sink: it does not introduce a symbol, and if
the discarded value carries ownership, the compiler lowers it as an immediate
cleanup/disposal path.

**18b. Does SLA support `using` static extensions?**

Yes. `using module_path;` enables method-style calls for public functions from
that module within the current scope. The compiler resolves direct fields and
local functions first, then consults the active `using` set. Ambiguous matches
are reported as hard errors rather than guessed at runtime.

**18c. Does SLA support `type` aliases with `&`-style struct flattening?**

Yes, as a frontend-only aliasing surface for flat data layouts. A declaration
like `type BulletData = Transform & Velocity & { damage: i32 };` is expanded in
the frontend into a flattened field layout so the resulting value behaves like a
single plain struct. The alias exists for compile-time readability; it does not
introduce runtime wrapper layers.

**18d. Does SLA support a restricted `@overload` block for operators?**

Yes. `@overload Type { fn +(self: Type, other: Type) -> Type { ... } }`
is supported for `+`, `-`, `*`, and `/` on explicit target types. The frontend
lowers the operator to a static function call during type checking, so there is
no runtime dispatch penalty. If no overload matches, the compiler falls back to
the existing built-in numeric operator rules. Bare `overload` is not a valid
declaration form.

**19. Is there `const`, `final`, or `readonly`?**

`const` exists for top-level and local immutable bindings. `final` and
`readonly` are not current language keywords.

**20. Does the compiler optimize value-in/value-out updates into in-place mutation?**

Do not rely on that as a semantic guarantee. The compiler and SA backend may
optimize, but APIs should express ownership or borrowing directly.

## C. Basic Types And Literals

**21. Which numeric types exist? Is there `usize/isize`?**

Current primitive types include `i8/i16/i32/i64/isize`,
`u8/u16/u32/u64/usize`, `f32/f64`, plus aliases `int` -> `i64` and
`float` -> `f64`.

**22. Are numeric conversions explicit?**

Use explicit `as` casts. Do not depend on implicit truncation or promotion.

**23. Is `bool` only `true` / `false`?**

Yes at the SLA level. It lowers to SA integer representation internally.

**24. Is there a string type? Is it UTF-8?**

There are string facilities through SA std (`String`, `str`/slice-style APIs).
String literals are emitted as UTF-8 constants.

**25. What type is a string literal?**

It depends on context: the compiler can lower it to an owned/string or borrowed
string representation for supported std calls. Treat it as UTF-8 text, not as a
general null-terminated C string.

**26. Is there `char`?**

There is no first-class `char` primitive in the SLA AST today. Character
helpers may exist in `sa_std`, but that is library surface, not core syntax.

**27. Is there `null`, `nil`, or `none`?**

No general null/nil value. Use `Option<T>`/`None` for absence. Raw pointers are
low-level and should not become normal application null handling.

**28. Are tuples supported?**

Yes. Tuple types and tuple destructuring are supported.

**28a. Are slice rest patterns and struct update syntax supported?**

Yes. `[a, b, ..rest]` slice destructuring and `Struct { field: expr, ..base }`
struct updates are supported and lower directly in the frontend.

**28b. Is `using` compatible with the data-oriented style?**

Yes. It is an explicit opt-in layer for ergonomic method-style calls over
plain module functions, so it keeps the call graph static and preserves the
frontend-only lowering model.

**28c. Does SLA support `<=>` three-way comparison?**

Yes. `<=>` returns the SLA std `Ordering` facade from `sla_std/cmp.sla`, not a
new compiler-owned enum. Import `sla_std/cmp.sla` when user code wants methods
such as `Ordering::less()`, `ordering.is_lt()`, or `ordering_value(ordering)`.
The compiler only parses/type-checks the operator and lowers it to the existing
`sa_std/cmp.sa` ordering values `-1`, `0`, and `1`.

**29. Are arrays and `Vec` separate?**

Yes. Fixed arrays are value-like fixed-size aggregates. `Vec<T>` is a dynamic
std container.

**30. Are fixed arrays `[T; N]` supported?**

Yes, fixed-length array types and array literals are supported.

## D. Struct, Enum, Union, And ADT

**31. Are structs pure data? Is there field privacy?**

Structs are primarily data layouts. Public/private support is still coarse; do
not rely on Rust-style per-field privacy as a stable feature.

**32. Does SLA have enum? C-style or Rust-style ADT?**

SLA has `enum` with payload-capable variants and pattern matching. It is closer
to Rust ADTs than to plain C enums.

**33. Does `match` destructure enums?**

Yes. `match`, `if let`, `while let`, and `let ... else` support enum patterns
for common forms including `Some`, `None`, `Ok`, and `Err`.

**34. Is there `union` or tagged union?**

The parser accepts `union` syntax, but the robust, user-facing model should be
considered less mature than `struct` and `enum`.

**35. Do struct fields have default values?**

No general default-field syntax. Use constructor/helper functions.

**36. Are anonymous structs or tuple structs supported?**

No stable anonymous struct or tuple-struct surface is documented.

**37. Are recursive types supported?**

Use indirection such as `Box<T>`, `Rc<T>`, `Arc<T>`, raw pointers, or container
handles. Direct infinitely-sized recursive structs are not valid.

**38. Is derive supported for `eq/hash/copy/debug`?**

Yes for the current plain-data struct surface: `@derive(copy, eq, ord, hash,
debug)` is semantically expanded by the compiler. `copy` performs field-wise
copy for derived structs, `eq` enables `==`/`!=`, `ord` enables lexicographic
ordering operators, `hash(value)` returns a `u64`, and `debug(value)` returns a
`String` debug rendering. Unknown derive names remain accepted as neutral
annotations unless their semantics are used.

**39. Is operator overloading supported?**

Yes, in the restricted frontend form `@overload Type { fn +(self: Type, other: Type) -> Type { ... } }`.
It is limited to `+ - * /` and lowers to static function calls during type
checking, so there is no runtime dispatch penalty. Bare `overload` is not a
valid declaration form.

**40. What is the current recommended `Entity` style without derive/copy?**

Prefer `@derive(copy, eq, ord, hash, debug)` for small value-like structs such as
`Entity`. Without derive, use explicit constructors and helper functions for
equality/hash/order.

## E. Functions, Methods, And Calling Convention

**41. Are functions only top-level? What does `impl` support?**

Top-level functions exist, and `impl Type { fn ... }` methods are supported.
Trait impls are also represented in the AST and type checker.

**42. Are methods semantically different from free functions?**

Mostly no. Methods lower through static resolution/UFCS-style calls; they are
not classic object-oriented virtual methods unless using the dyn trait path.

**43. Can method receivers distinguish value/reference/read-only?**

Receivers can be value, `&self`, or `^self`-style move/borrow forms. There is
no separate `view` keyword today.

**44. Is function overloading supported?**

No general overload-by-signature support. Use distinct names or generics.

**45. Are default, named, or variadic parameters supported?**

No stable default/named/variadic function parameter feature.

**46. Can functions return multiple values?**

Yes, by returning tuples. Tuple return/destructuring is a language-level feature.

**47. Is recursion supported? Is there tail-call optimization?**

Recursion is allowed when the generated SA verifies. Tail-call optimization is
not a language guarantee.

**48. Are functions first-class?**

Function pointer types such as `fn(i32) -> i32` are supported and tested for
storing/passing/calling function values.

**49. Is `fn(Entity) -> i64` a function pointer or closure type?**

It is a function pointer type. Closures use closure literal syntax and are
handled separately.

**50. Are lambdas/closures supported? Can they capture?**

Closure literals like `|x| x + 1` are supported for several inline/std patterns.
Simple capture support exists in codegen paths, but escaping heap-allocated
closures should still be treated as limited.

**51. Are inline hints, generic specialization, or constexpr supported?**

Generic specialization/monomorphization is central. `inline` is parsed. A
general `constexpr` execution model is not part of current SLA.

**52. Is function visibility supported?**

`pub`, `extern`, ABI forms, and `@no_mangle` exist in the parser/compiler
surface. Fine-grained module visibility is still evolving.

## F. Control Flow

**53. Which control-flow constructs exist?**

Current syntax includes `if`, `else`, `while`, `while let`, `for`, ranges,
`break`, `continue`, `switch`, `match`, `if let`, `let ... else`, `return`,
`async`/`await`, `unsafe`, and inline `asm!` support.

**54. Was `break` missing in older examples?**

No. `break;` and `continue;` are implemented. Older ECS examples avoided them
because the feature was not always available or trusted at the time.

**55. Is reassignment of loop variables legal/common?**

Yes for mutable locals. It is common in low-level/data-oriented code, though
`for` and `break` should be preferred when clearer.

**56. Is there `for in`? Index or iterator based?**

Yes. `for i in 0..n` is range/index based. There is also work toward a generic
for-in protocol for containers.

**57. Are range expressions such as `0..n` supported?**

Yes for `for` loops.

**58. Is `if` a statement or expression?**

The AST models `if` as an expression, and codegen can materialize values from
branches. In everyday style it is often used as a statement/block.

**59. Is `match` a statement or expression?**

It is represented as an expression-like AST node with block arms. Prefer simple
return/assignment patterns until all expression contexts are thoroughly tested.

**60. Is there `switch` syntax?**

Yes. `switch` exists for simpler literal/equality branch ladders; `match` is
for enum/pattern cases.

**61. Is there `defer` or `scope(exit)`?**

No user-facing `defer`. Cleanup is compiler-managed through scope exits and SA
release insertion.

**62. Are labeled breaks supported?**

No stable labeled `break outer` feature is documented.

## G. Containers, Indexing, And Iteration

**63. What is `Vec<T>` semantically?**

`Vec<T>` is a dynamic array from the SA std surface, backed by heap/runtime
storage and exposed through methods/macros lowered by the compiler.

**64. What does `let b = a;` mean for `Vec<T>`?**

Treat it as ownership transfer unless explicitly cloning. Do not assume deep
copy or cheap shared aliasing.

**65. What does `values[i]` return?**

For reads, it yields a value loaded from the indexed slot. For aggregate or
borrowed cases, the compiler has specialized paths for field/index access.

**66. What is `values[i] = x`?**

It writes `x` into the indexed container slot through the `Vec`/array lowering.
Tests cover scalar and struct slot updates.

**67. What type does `len(values)` return?**

Length APIs are index-sized integer values (`usize`/SA-sized integer in current
facades). Cast explicitly when comparing with `i64` counters.

**68. Which standard containers exist?**

Current std/compiler support includes `Vec`, fixed arrays, `Slice`, `String`/
string views, `HashMap`, `HashSet`, `BTreeMap`, `BTreeSet`, `VecDeque`, `Box`,
`Rc`, `Arc`, `Cell`, `RefCell`, `Mutex`, `RwLock`, and atomics. Do not assume
`LinkedList` unless it appears in active `sa_std`.

**69. Are slice/span/view types supported?**

Slice support exists through `[T]`/`Slice<T>`-style types and array/string view
lowering. A separate `view` keyword is not implemented.

**70. Is a slice a value or a borrow?**

It should be treated as a non-owning view/borrow-like value. Keep the owner
alive while using the slice.

**71. Is there a standard iteration protocol?**

Range `for` is stable. Generic/container `for in` support exists in tests, but
the protocol surface is still less mature than direct indexing or explicit
container methods.

**72. Are generators or lazy iterators supported?**

No general generator feature. Some iterator-like chains are lowered for arrays,
vectors, strings, and std patterns, but eager/direct APIs are the safer model.

**73. Are `remove`, `insert`, `swap`, and `sort` built-in or std library?**

They are library/compiler-lowered container methods, not core language syntax.
Use the current `sa_std` surface as the source of truth.

**74. Recommended `Vec<Entity>` contains/dedup/sort style?**

Until `Entity` derives are finished, use explicit helper equality/order
functions or component-specific loops. Use std helpers when the element type has
the required scalar/key support.

## H. Memory Model And Resource Management

**75. Does SLA have GC?**

No tracing GC is part of SLA. It relies on ownership, compiler-inserted cleanup,
and SA/runtime container destructors.

**76. How are heap objects like `Vec`, `String`, and maps managed?**

Their storage is managed by std/runtime APIs. The SLA compiler tracks values and
emits releases/cleanup so SA verification can prove resources are not leaked.

**77. Is there RAII/drop?**

There is compiler-managed cleanup on scope exit, similar in goal to RAII, but
there is no stable user-defined `Drop` trait surface.

**78. Are resources automatically freed at scope exit?**

The compiler is designed to emit the needed releases for active owned values at
scope exits, branches, early returns, and loop boundaries.

**79. Can users define custom destructors?**

Not as a stable language `Drop` trait. Use explicit cleanup functions or
std/container APIs; generated SA may call runtime release hooks internally.

**80. How does SLA prevent use-after-free/double-free/dangling references?**

The compiler tracks ownership states and emits SA that the SA verifier checks.
Borrowed values and smart pointers have extra compiler/runtime rules. `unsafe`
and raw pointers reduce those guarantees.

## I. References, Aliasing, And Borrowing

**81. Does SLA have references?**

Yes. `&T` is a borrow type and `&expr` creates a borrow expression.

**82. Can a struct field be borrowed without copying the whole struct?**

Yes, field borrow and nested smart-pointer field borrow paths are implemented
and covered by regression tests.

**83. Are multiple writable aliases allowed?**

They should not be assumed freely allowed. Owned values, borrows, RefCell-like
runtime checks, and SA verification constrain aliasing.

**84. If aliases exist, how are races/aliasing bugs avoided?**

Single-threaded alias safety is enforced through ownership/borrow tracking and
runtime checks for interior mutability types. Thread safety depends on explicit
sync primitives such as `Mutex`, `RwLock`, atomics, `Arc`, etc.

**85. Should future SLA distinguish read-only `view` and writable `ref`?**

It is possible, but not urgent. Today `&T` is the real primitive. Adding
`ref/view` only makes sense if the compiler enforces their semantics, not as
ECS-specific keywords.

**86. Are pointers supported?**

Yes. `*T` exists for pointer types, and `unsafe` exists for operations outside
the ordinary safe surface.

**87. Is manual heap allocation possible?**

Yes through std/runtime types such as `Box<T>` and lower-level allocation APIs
where exposed. Prefer `Box`, `Vec`, `Rc`, `Arc`, or arena-style APIs over raw
pointers when possible.

## J. Error Handling And Panic Model

**88. What does `panic(...)` do?**

It lowers to SA panic behavior. In tests it fails the current test unless the
test is marked `@should_panic`; in normal execution it aborts the current run.

**89. Are `Option` and `Result` available?**

Yes. They are supported through std/compiler-lowered patterns and methods.

**90. If no `Option`/`Result`, what should be used?**

Use `Option`/`Result` where absence or failure is expected. Use `panic` for
violated invariants. Avoid placeholder values for new APIs.

**91. Is `try`/`?` supported?**

Postfix `?` is supported for `Option`/`Result`-style propagation.

**92. Are exceptions supported?**

No general exception mechanism. Limited panic-catching paths exist for std
patterns, but exceptions are not the normal error model.

**93. Is `panic(9400)` official style or personal style?**

Numeric panic codes are common in current tests because they are compact and
easy to identify. Production-facing code should prefer clearer error values or
message-capable panic paths when available.

**94. Are `assert_eq`, `assert_ne`, or `assert_panics` built in?**

`@test` and `@should_panic` exist. A polished SLA assertion helper surface is
still a priority gap; many current tests use `if !cond { panic(code); }`.

## K. Generics, Constraints, And Interfaces

**95. Does SLA support generics?**

Yes. Generic structs, enums, functions, and impls are supported and
monomorphized.

**96. Are traits/interfaces supported?**

Yes, `trait` and `impl Trait for Type` are represented and checked. Static
dispatch is the primary model; dyn trait support exists for selected paths.

**97. What is the interface constraint syntax and dispatch model?**

Current syntax supports trait declarations, supertraits, and impls. Dispatch is
primarily static/monomorphized; `dyn Trait` paths lower through runtime fat
pointer/vtable support where implemented.

**98. Are generics monomorphized or dictionary-passed?**

Monomorphized. Concrete instantiations generate specialized layouts/functions.

**99. Are associated types, const generics, or `where` clauses supported?**

No full Rust-style associated types, generic const parameters, or `where`
clauses. Fixed arrays `[T; N]` exist, but that is not the same as const
generics.

**100. What is the ideal abstraction path if generics/traits are not enough?**

Keep the compiler language-general: improve derive/codegen macros, static trait
dispatch, container stdlib, and hygienic source generation. Do not hard-code ECS
or engine concepts into the compiler.

## L. Compilation, SAB, CLI, And Workspace Builds

**101. Does SLA compile to `.sa` first and then convert to SAB?**

No. `sa sla build` remains the `.sa` text mainline. `sa sla sab build`,
`sa sla sab workspace`, `sa slab build`, and `sa slab workspace` use the direct
SAB mainline: SLA source expansion, parsing, import expansion, monomorphization,
type checking, then `sab_codegen.generate`. The SAB path must not be implemented
as `sla -> sa -> sab`.

**102. Where does `sa sla sab build` write output by default?**

By default it writes a compiler-managed SAB artifact under `.sla-cache/sab/`.
It does not place SAB output in `.zig-cache/`, and it does not write a sibling
`.sab` next to the source unless requested.

**103. How do I write a visible `.sab` file?**

Use `sa sla sab build <file.sla> --out <file.sab>` or `-o <file.sab>`. Workspace
builds use `--sab-out <file.sab>` for an extra inspection artifact, and
`--emit-sab` for a sibling `.sab`. The managed `.sla-cache/sab/...` artifact is
still written so later incremental builds can reuse a stable input path.

**104. How does SAB workspace build work?**

`sa sla sab workspace` resolves the current `sa.mod` workspace, selects the
default member or `-p/--package`, writes managed SAB under `.sla-cache/sab/`,
then delegates to `sa build-exe <managed.sab> ...`. Extra `sa build-exe` options
after the SLA options are passed through.

**105. What are `sa sla init` and `sa sla skills` for?**

`sa sla init [path]` scaffolds a minimal SLA binary project with `sa.mod`,
`src/main.sla`, and `.gitignore` entries including `.sla-cache/`. `sa sla skills
[--json]` lists the plugin capability surface; text mode also writes Codex and
Claude agent skill files into the current directory, matching the `sa skills`
style.

**106. Should SAB changes be verified with full test suites?**

No, not by default. Prefer focused commands and filtered unit tests with
`timeout 120s` for test or CLI execution. Build commands such as `zig build
--summary all` do not need the timeout wrapper.

**107. What backend does `sa sla test` use by default?**

`sa sla test` defaults to `--test-backend auto`, which tries direct SLA-to-SAB
first and passes the managed `.sla-cache/sab/...` artifact to `sa test`. If the
direct SAB backend returns `UnsupportedSabDirectFeature`, auto mode falls back
to the legacy `.test.sa` test path so existing test suites can keep running
while SAB coverage expands. Use `--test-backend sab` to require SAB with no
fallback, or `--test-backend sa` to force the old `.sa` text test backend.
