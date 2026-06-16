# sa_plugin_sla progress

Update this file every time a compiler feature or demo milestone is completed and tested.

## Completed Features

- [done] Unified rosetta API-to-`sa_std` macro map added for `Vec`, `VecDeque`, `String`/`&str`, `Option`, `Result`, maps, interior mutability, guards, time, and async so shared gaps are handled by capability block instead of one demo at a time.
  - Verified with: `rg -n "VecDeque|Vec::|vec!|vec\(|String|&str|\.len\(|\.bytes\(|\.as_bytes\(|\.as_ptr\(|\.push\(|\.pop\(|\.remove\(|\.join\(|unwrap_or|unwrap_or_default|is_ok\(|is_err\(|HashMap|BTreeMap|Cell|RefCell|Mutex|RwLock|Duration|Instant|SystemTime|sleep|async|await" demos/rosetta -g 'main.rs'`
  - Recorded in: `docs/sa_std_macro_gap_audit.md`

- [done] Collection block A extended for Rust-style `VecDeque::new`, `.push_back(value)`, and `.pop_front() -> Option<T>` using `sa_std/vec_deque.sa` plus `sa_std/core/option.sa`; empty `VecDeque<infer>` now resolves from later `push_back` calls.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/89_job_queue/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/89_job_queue/main.sla --out /tmp/89_job_queue.sa`
  - Verified with: `rg -n "VEC_DEQUE|OPTION" /tmp/89_job_queue.sa`
  - Verified with: `sa test /tmp/89_job_queue.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/89_job_queue/main.sla --out demos/rosetta/89_job_queue/main.test.sa`
  - Verified with: `sa test demos/rosetta/89_job_queue/main.test.sa`

- [done] Demo `89_job_queue` manually rewritten from generated placeholder to Rust-equivalent queue semantics: create an empty `VecDeque`, push `5` and `7`, pop both front values through `Option.unwrap()`, print/assert `12`.
  - Verified with: `sa test demos/rosetta/89_job_queue/main.test.sa`

- [done] Rust-style `Vec<T>` baseline expanded for current rosetta 8-byte-slot paths: `Vec::new()` with later `push` inference, `push(value)` returning void, `pop() -> Option<T>`, `remove(index) -> T` with panic-on-OOB path, and `vec[index]` indexing through `sa_std/vec.sa` plus `sa_std/core/option.sa`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/86_cache_eviction/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/86_cache_eviction/main.sla --out /tmp/86_cache_eviction.sa`
  - Verified with: `rg -n "VEC_(NEW|PUSH|REMOVE|GET)|panic\(86\)" /tmp/86_cache_eviction.sa`
  - Verified with: `sa test /tmp/86_cache_eviction.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check tmp_vec_pop_smoke.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build tmp_vec_pop_smoke.sla --out /tmp/vec_pop_smoke.sa`
  - Verified with: `rg -n "VEC_POP|OPTION_(NEW|UNWRAP)" /tmp/vec_pop_smoke.sa`
  - Verified with: `sa test /tmp/vec_pop_smoke.sa`
  - Regression verified with: `sa test /tmp/32_trait_object_vector.sa`
  - Regression verified with: `sa test /tmp/89_job_queue.sa`

- [done] Demo `86_cache_eviction` manually rewritten from generated placeholder to Rust-equivalent vector semantics: build `vec(10, 20, 30)`, remove index `0`, then print/assert `cache[0] == 20`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/86_cache_eviction/main.sla --out demos/rosetta/86_cache_eviction/main.test.sa`
  - Verified with: `sa test demos/rosetta/86_cache_eviction/main.test.sa`

- [done] Rust-style `while let Some(binding) = option_expr { ... }` support added for `Option<T>` loops, preserving real Option tag checks and binding extraction instead of rewriting to fixed-count loops.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check tmp_while_let_empty_smoke.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build tmp_while_let_empty_smoke.sla --out /tmp/while_let_empty_smoke.sa`
  - Verified with: `sa test /tmp/while_let_empty_smoke.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check tmp_while_let_smoke.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build tmp_while_let_smoke.sla --out /tmp/while_let_smoke.sa`
  - Verified with: `rg -n "OPTION_IS_SOME|OPTION_GET|sa_vec_try_pop" /tmp/while_let_smoke.sa`
  - Verified with: `sa test /tmp/while_let_smoke.sa`

- [done] Rust-style `if let Some(binding) = option_expr` and chained `if let ... && let ...` support added for `Option<T>`, preserving left-to-right condition evaluation, then-scope bindings, and real `OPTION_IS_SOME` / `OPTION_GET` lowering.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build tmp_if_let_chain_smoke.sla --out /tmp/if_let_chain_smoke.sa`
  - Verified with: `sa test /tmp/if_let_chain_smoke.sa`

- [done] Demo `104_if_let_chains` manually rewritten from generated placeholder to Rust-equivalent Option chain semantics: create `Some(2)`, `Some(3)`, `Some(4)`, bind `x/y/z` through a chained `if let`, then print/assert `9`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build demos/rosetta/104_if_let_chains/main.sla --out demos/rosetta/104_if_let_chains/main.test.sa`
  - Verified with: `rg -n "OPTION_IS_SOME|OPTION_GET|sa_print|panic\(104\)" demos/rosetta/104_if_let_chains/main.test.sa`
  - Verified with: `sa test demos/rosetta/104_if_let_chains/main.test.sa`

- [done] Rust-style `let Some(binding) = option_expr else { ... };` support added for `Option<T>`, preserving Rust's success binding scope and requiring the else block to diverge.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build tmp_let_else_smoke.sla --out /tmp/let_else_smoke.sa`
  - Verified with: `sa test /tmp/let_else_smoke.sa`

- [done] Demo `105_let_else` manually rewritten from generated placeholder to Rust-equivalent Option let-else semantics: create `Some(5)`, bind `x` through `let Some(x) = value else { println("{}", 0); return 0; };`, then print/assert `5`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build demos/rosetta/105_let_else/main.sla --out demos/rosetta/105_let_else/main.test.sa`
  - Verified with: `rg -n "OPTION_IS_SOME|OPTION_GET|L_LET_ELSE|sa_print|panic\(105\)" demos/rosetta/105_let_else/main.test.sa`
  - Verified with: `sa test demos/rosetta/105_let_else/main.test.sa`

- [done] Rust-style `match Option<T>` support added for `Some(binding)` / `None` arms, including never-fallback branch typing when an arm terminates with `panic(...)`; string panic now lowers through `sa_std/core/panic.sa` `PANIC_MSG`.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build tmp_option_match_never_smoke.sla --out /tmp/option_match_never_smoke.sa`
  - Verified with: `rg -n "OPTION_IS_SOME|OPTION_GET|PANIC_MSG|panic_msg|L_OPTION_MATCH|unreachable" /tmp/option_match_never_smoke.sa`
  - Verified with: `sa test /tmp/option_match_never_smoke.sa`
  - Regression verified with: `sa test demos/rosetta/06_enum_and_match/main.test.sa`
  - Regression verified with: `sa test demos/rosetta/39_generic_enum_i32/main.test.sa`
  - Regression verified with: `sa test demos/rosetta/60_enum_branch/main.test.sa`

- [done] Demo `146_never_type_fallback` manually rewritten from generated placeholder to Rust-equivalent Option match semantics: `match Some(1)` returns the `Some` value and keeps the `None` arm as `panic("unreachable")`, then print/assert `1`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build demos/rosetta/146_never_type_fallback/main.sla --out demos/rosetta/146_never_type_fallback/main.test.sa`
  - Verified with: `rg -n "OPTION_IS_SOME|OPTION_GET|PANIC_MSG|panic_msg|L_OPTION_MATCH|unreachable|panic\(146\)" demos/rosetta/146_never_type_fallback/main.test.sa`
  - Verified with: `sa test demos/rosetta/146_never_type_fallback/main.test.sa`
  - Regression verified with: `sa test demos/rosetta/104_if_let_chains/main.test.sa`
  - Regression verified with: `sa test demos/rosetta/105_let_else/main.test.sa`
  - Regression verified with: `sa test demos/rosetta/136_executor_task_queue/main.test.sa`

- [done] Rust-style `Cell<T>` i32-path support added for `Cell::new(value)`, `.get()`, and `.set(value)` using `sa_std/core/cell.sa` `CELL_SET` / `CELL_GET`; `Cell::new` binds to an addressable stack slot so later `set` mutates the same cell.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build tmp_cell_smoke.sla --out /tmp/cell_smoke.sa`
  - Verified with: `rg -n "CELL_NEW|CELL_SET|CELL_GET|core/cell" /tmp/cell_smoke.sa`
  - Verified with: `sa test /tmp/cell_smoke.sa`

- [done] Demo `106_cell_interior_mut` manually rewritten from generated placeholder to Rust-equivalent `std::cell::Cell` semantics: create `Cell::new(10)`, read `first`, `set(20)`, read `second`, then print/assert `first + second == 30`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build demos/rosetta/106_cell_interior_mut/main.sla --out demos/rosetta/106_cell_interior_mut/main.test.sa`
  - Verified with: `rg -n "CELL_SET|CELL_GET|for|L_FOR|println|sa_print" demos/rosetta/106_cell_interior_mut/main.test.sa`
  - Verified with: `sa test demos/rosetta/106_cell_interior_mut/main.test.sa`

- [done] Rust-style `RefCell<T>` integer demo path added for `RefCell::new(value)`, `.borrow() -> &T`, `.borrow_mut() -> &T`, deref read/write through borrow handles, and compiler-owned lexical borrow release using `sa_std/core/refcell.sa` `REFCELL_U64_*` macros.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build tmp_refcell_smoke.sla --out /tmp/refcell_smoke.sa`
  - Verified with: `rg -n "REFCELL_U64_(NEW|TRY_BORROW|TRY_BORROW_MUT|RELEASE)" /tmp/refcell_smoke.sa`
  - Verified with: `sa test /tmp/refcell_smoke.sa`

- [done] Demo `107_refcell_dynamic_borrow` manually rewritten from generated placeholder to Rust-equivalent `std::cell::RefCell` semantics: shared borrow prints/reads `7`, mutable borrow writes `9`, direct later borrow prints `9`, and the test asserts `7 + 9 == 16`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build demos/rosetta/107_refcell_dynamic_borrow/main.sla --out demos/rosetta/107_refcell_dynamic_borrow/main.test.sa`
  - Verified with: `rg -n "REFCELL_U64_(NEW|TRY_BORROW|TRY_BORROW_MUT|RELEASE)|sa_print|panic\(107\)" demos/rosetta/107_refcell_dynamic_borrow/main.test.sa`
  - Verified with: `sa test demos/rosetta/107_refcell_dynamic_borrow/main.test.sa`

- [done] Trait supertrait declaration syntax (`trait B: A { ... }`, with `+`-separated supertraits parsed and validated) added for the static dispatch path used by current demos.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla`
  - Regression verified with: `sa test demos/rosetta/07_trait_vtable/main.test.sa`
  - Regression verified with: `sa test demos/rosetta/31_trait_static_dispatch/main.test.sa`

- [done] Demo `110_trait_super_vtable` manually rewritten from generated placeholder to Rust-equivalent supertrait/static-dispatch semantics: `Item { value: 7 }`, `impl A` returns `7`, `impl B` returns `8`, then print/assert `15`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build demos/rosetta/110_trait_super_vtable/main.sla --out demos/rosetta/110_trait_super_vtable/main.test.sa`
  - Verified with: `rg -n "Item_a|Item_b|sa_print|panic\(110\)" demos/rosetta/110_trait_super_vtable/main.test.sa`
  - Verified with: `sa test demos/rosetta/110_trait_super_vtable/main.test.sa`

- [done] Rust-style extern C ABI definition/call surface added for `@no_mangle pub extern "C" fn ...` and `unsafe { ... }` expression blocks; extern/no-mangle functions lower to unmangled SA symbols and calls preserve the raw symbol.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build tmp_extern_c_abi_smoke.sla --out /tmp/extern_c_abi_smoke.sa`
  - Verified with: `rg -n "@add_pair|sla__add_pair|call @add_pair|extern_smoke" /tmp/extern_c_abi_smoke.sa`
  - Verified with: `sa test /tmp/extern_c_abi_smoke.sa`
  - Regression verified with: `sa test demos/rosetta/42_export_visibility/main.test.sa`
  - Regression verified with: `sa test demos/rosetta/110_trait_super_vtable/main.test.sa`

- [done] Demo `111_extern_c_abi` manually rewritten from generated placeholder to Rust-equivalent extern C ABI semantics: define unmangled `add_pair(i32, i32) -> i32`, call it through `unsafe { add_pair(11, 12) }`, then print/assert `23`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build demos/rosetta/111_extern_c_abi/main.sla --out demos/rosetta/111_extern_c_abi/main.test.sa`
  - Verified with: `rg -n "@add_pair|sla__add_pair|call @add_pair|sa_print|panic\(111\)" demos/rosetta/111_extern_c_abi/main.test.sa`
  - Verified with: `sa test demos/rosetta/111_extern_c_abi/main.test.sa`

- [done] Rust-style raw pointer arithmetic baseline added for arrays: `[T; N].as_ptr() -> *T`, raw pointer `.add(index) -> *T`, and `unsafe { *ptr }` now lower to thin SA pointer math (`mul` byte offset + `ptr_add` + typed `load`) instead of placeholder arithmetic.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build tmp_raw_ptr_smoke.sla --out /tmp/raw_ptr_smoke.sa`
  - Verified with: `rg -n "ptr_add|mul .* 4|load .* as i32" /tmp/raw_ptr_smoke.sa`
  - Verified with: `sa test /tmp/raw_ptr_smoke.sa`
  - Regression verified with: `sa test demos/rosetta/13_array_sum/main.test.sa`
  - Regression verified with: `sa test demos/rosetta/111_extern_c_abi/main.test.sa`

- [done] Demo `112_raw_pointer_arithmetic` manually rewritten from generated placeholder to Rust-equivalent raw pointer semantics: create `[1, 2, 3, 4]`, compute `unsafe { *data.as_ptr().add(2) }`, then print/assert `3`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla build demos/rosetta/112_raw_pointer_arithmetic/main.sla --out demos/rosetta/112_raw_pointer_arithmetic/main.test.sa`
  - Verified with: `rg -n "ptr_add|mul .* 4|load .* as i32|panic\(112\)" demos/rosetta/112_raw_pointer_arithmetic/main.test.sa`
  - Verified with: `sa test demos/rosetta/112_raw_pointer_arithmetic/main.test.sa`

- [done] Async function tail expressions now lower to ready futures containing the tail value, so `async fn task_one() -> i32 { 1 }` returns `Future<Output = 1>` instead of defaulting to `0`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/136_executor_task_queue/main.sla --out /tmp/136_executor_task_queue.sa`
  - Verified with: generated SA showing `EXPAND FUTURE_READY_STATE_NEW ..., 1/2/3` for the three task functions.
  - Regression verified with: `sa test /tmp/75_async_bridge.sa`

- [done] Demo `136_executor_task_queue` manually rewritten from generated placeholder to Rust-equivalent async queue semantics: create `vec(task_one(), task_two(), task_three())`, repeatedly `pop()` with `while let Some(task)`, await each task, accumulate `6`, and print/assert the result.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/136_executor_task_queue/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/136_executor_task_queue/main.sla --out /tmp/136_executor_task_queue.sa`
  - Verified with: `rg -n "sa_vec_try_pop|OPTION_(IS_SOME|GET|NEW)|FUTURE_READY|VEC_PUSH" /tmp/136_executor_task_queue.sa`
  - Verified with: `sa test /tmp/136_executor_task_queue.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/136_executor_task_queue/main.sla --out demos/rosetta/136_executor_task_queue/main.test.sa`
  - Verified with: `sa test demos/rosetta/136_executor_task_queue/main.test.sa`
  - Regression verified with: `sa test /tmp/86_cache_eviction.sa`
  - Regression verified with: `sa test /tmp/while_let_smoke.sa`

- [done] Cross-demo `sa_std` macro/lowering audit expanded across all rosetta Rust references, grouped by reusable capability blocks (`Vec`, `String`, `Option`/`Result`, maps, atomics, sync, async/time, IO/raw pointers, patterns) to avoid one-demo-at-a-time macro discovery.
  - Verified with: `rg --files demos/rosetta -g 'main.rs' | sort | wc -l` (`301` files)
  - Verified with: grouped `rg` scans over every `demos/rosetta/*/main.rs` and current `/home/vscode/.sa/std` macro families.
  - Recorded in: `docs/sa_std_macro_gap_audit.md`

- [done] Rust-style `AtomicI32` and `Ordering::*` lowering now uses real `sa_std/sync/atomic.sa` macros for `AtomicI32::new`, `.load`, `.store`, `.fetch_add`, and `.compare_exchange`; `Result.is_ok/is_err` is supported for atomic compare-exchange results.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/76_lockfree_counter/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/76_lockfree_counter/main.sla --out demos/rosetta/76_lockfree_counter/main.test.sa`
  - Verified with: `sa test demos/rosetta/76_lockfree_counter/main.test.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/108_atomic_spin_lock/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/108_atomic_spin_lock/main.sla --out demos/rosetta/108_atomic_spin_lock/main.test.sa`
  - Verified with: `sa test demos/rosetta/108_atomic_spin_lock/main.test.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/109_atomic_fetch_add/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/109_atomic_fetch_add/main.sla --out demos/rosetta/109_atomic_fetch_add/main.test.sa`
  - Verified with: `sa test demos/rosetta/109_atomic_fetch_add/main.test.sa`

- [done] Demo `76_lockfree_counter` manually rewritten from generated placeholder to Rust-equivalent atomic semantics: initialize `AtomicI32(1)`, `fetch_add(2, SeqCst)`, then `load(SeqCst)` and print/assert `3`.
  - Verified with: `sa test demos/rosetta/76_lockfree_counter/main.test.sa`

- [done] Demo `108_atomic_spin_lock` manually rewritten from generated placeholder to Rust-equivalent spin-lock semantics using `compare_exchange(..., Acquire, Relaxed).is_err()` in a `while` loop, then `store(0, Release)` and print/assert `1`.
  - Verified with: `sa test demos/rosetta/108_atomic_spin_lock/main.test.sa`

- [done] Demo `109_atomic_fetch_add` manually rewritten from generated placeholder to Rust-equivalent atomic fetch-add semantics: old value `5`, loaded value `8`, print/assert `13`.
  - Verified with: `sa test demos/rosetta/109_atomic_fetch_add/main.test.sa`

- [done] `while` statement support in lexer/parser/AST/type checker/codegen/monomorphizer.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/21_while_loop/main.sla --compile-only`

- [done] `impl` associated functions and `Type::function(...)` call syntax.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/17_associated_fn/main.sla --compile-only`

- [done] Rust-style primitive spellings in Sla codegen paths used by demos (`i32`, `i64`, `u32`, `u64`, `usize`, `f32`, `f64`, etc.).
  - Verified with: early rosetta demos using typed arrays, tuples, methods, and formatting.

- [done] `println(...)` top-level lowering using `sa_std` print/fmt surface.
  - Verified with: rosetta demos using printed integer output.

- [done] `?` lowering now avoids illegal stack-escape in result propagation paths.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/19_result_question/main.sla`

- [done] Tail expression parsing inside `{ ... }` blocks when the final expression omits `;`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/19_result_question/main.sla`

- [done] Typed `if` expression value flow for branch-tail expressions.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/19_result_question/main.sla`

- [done] Non-void function tail expressions now lower to real returns when the final statement is an expression.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/24_factorial/main.sla`

- [done] `if` value expressions now merge branch results through storage instead of cross-branch phi temporaries, fixing recursive tail-expression cases.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/25_fibonacci/main.sla`

- [done] Preserve associated-call target metadata for `Type::function(...)` syntax so built-in typed paths can distinguish `Box::new(...)`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/20_boxed_value/main.sla`

- [done] `Box::new(...)` lowering wired to `sa_std/core/mem.sa` `BOX_NEW`, with `println("{}", value)` support for `Box<primitive>`.
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/20_boxed_value/main.sla`

- [done] `break` / `continue` statement support through lexer/parser/AST/type checker/codegen for loop control.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/22_break_continue/main.sla`

- [done] Borrowed function parameters now lower to SA `&name: ptr`, borrowed returns lower to `-> &ptr`, and borrowed primitive locals get real storage slots before reference-taking.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/26_reference_return/main.sla`

- [done] Top-level `const` declarations now parse as program declarations, type-check in a shared global scope, and lower array literals into SA static data.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/29_const_data/main.sla`

- [done] `match` now works as a value expression, with branch result storage/merge and case-binding cleanup before merge.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/30_manual_guard_branch/main.sla`

- [done] Minimal trait static-dispatch surface: parse `trait`, parse `impl Trait for Type`, accept bounded generic syntax `T: Trait`, support explicit generic function calls like `f<Type>(...)`, and monomorphize the resulting concrete call path.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/31_trait_static_dispatch/main.sla`

- [done] Borrowed receiver field access and borrowed-argument call checking/codegen were corrected so `&self` methods and borrowed receiver method calls type-check and lower correctly.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/16_methods/main.sla`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/31_trait_static_dispatch/main.sla`

- [done] Tuple struct declarations, constructor calls like `Type(value)`, and tuple-style field access like `.0` are now supported.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test tmp_tuple_struct_test.sla`

- [done] Trait object dynamic method calls on `dyn Trait` receivers now type-check and lower through `sa_std/core/trait_object.sa` `DYN_CALL`.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test tmp_dyn_method_call_smoke.sla`

- [done] Borrowed concrete values can now coerce to borrowed trait objects (`&Concrete -> &dyn Trait`) with generated vtable constants and fat-pointer materialization at call sites.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/07_trait_vtable/main.sla`

- [done] Builtin `vec(...)` construction now lowers to `sa_std/vec.sa`, `Vec<T>`/`Box<T>`/`dyn` generic types pass through monomorphization correctly, and `Box<Concrete>` can coerce into `Box<dyn Trait>` by materializing a trait-object fat pointer from the boxed concrete payload.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test tmp_vec_dyn_map_sum_smoke.sla`

- [done] `Vec<T>.iter().map(<closure>).sum()` now lowers for 8-byte vector element paths used by current demos, including `Vec<Box<dyn Trait>>` dynamic dispatch in the mapping closure.
  - Verified with: `zig build`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test tmp_vec_dyn_map_sum_smoke.sla`
  - Verified with: `SA_PLUGIN_DEV=1 sa sla test demos/rosetta/32_trait_object_vector/main.sla`

- [done] Array `[T; N].into_iter().map(<closure>).sum()` now type-checks and lowers with per-element mapped accumulation, matching the Rust iterator chain used by current demos.
  - Verified with: `zig build local-cli -- sla check demos/rosetta/33_iterator_map/main.sla`
  - Verified with: `zig build local-cli -- sla build demos/rosetta/33_iterator_map/main.sla --out /tmp/33_iterator_map.sa`
  - Verified with: `sa test /tmp/33_iterator_map.sa`

- [done] Array `[T; N].into_iter().filter(<predicate>).sum()` now type-checks and lowers with per-element predicate evaluation and conditional accumulation, matching the Rust iterator chain used by current demos.
  - Verified with: `zig build local-cli -- sla check demos/rosetta/34_iterator_filter/main.sla`
  - Verified with: `zig build local-cli -- sla build demos/rosetta/34_iterator_filter/main.sla --out /tmp/34_iterator_filter.sa`
  - Verified with: `sa test /tmp/34_iterator_filter.sa`

- [done] String literals now lower as `Slice` views compatible with `sa_std/string.sa` macros, so `word.len()` and iterator folds over string arrays use real `STRING_LEN` semantics instead of raw-byte-pointer stand-ins.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/15_string_bytes/main.sla --out /tmp/15_string_bytes.sa`
  - Verified with: `sa test /tmp/15_string_bytes.sa`

- [done] Array `[T; N].into_iter().fold(init, |acc, item| ...)` now type-checks and lowers with two-parameter closure evaluation and accumulator-typed literal coercion matching the Rust fold shape used by current demos.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/35_iterator_fold/main.sla --out /tmp/35_iterator_fold.sa`
  - Verified with: `sa test /tmp/35_iterator_fold.sa`

- [done] Rust-style `expr as Type` casts now parse, monomorphize, type-check for numeric primitive casts, and lower to native SA `as` casts. This covers tuple-struct field widening like `u8 -> i32` used by current demos.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/36_tuple_struct/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/36_tuple_struct/main.sla --out /tmp/36_tuple_struct.sa`
  - Verified with: `sa test /tmp/36_tuple_struct.sa`

- [done] Tuple enum variants now parse and lower in declarations, literals, and `match` patterns using Rust-style `Enum::Variant(T)` / `Enum::Variant(v)` syntax, while preserving existing struct-style enum variants.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/39_generic_enum_i32/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/39_generic_enum_i32/main.sla --out /tmp/39_generic_enum_i32.sa`
  - Verified with: `sa test /tmp/39_generic_enum_i32.sa`

- [done] Generic enums now monomorphize into concrete enum declarations, and typed enum literals in `let` / `const` contexts specialize to the matching concrete enum so `match` bindings receive concrete field types.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/39_generic_enum_i32/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/39_generic_enum_i32/main.sla --out /tmp/39_generic_enum_i32.sa`
  - Verified with: `sa test /tmp/39_generic_enum_i32.sa`

- [done] Field assignment codegen now emits real stores for `target.field = value` on struct and tuple receivers, including borrowed method receivers used by stateful `impl` methods.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/40_impl_block_state/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/40_impl_block_state/main.sla --out /tmp/40_impl_block_state.sa`
  - Verified with: `sa test /tmp/40_impl_block_state.sa`

- [done] Rust-style `mod name { ... }` declarations now parse in Sla and are flattened into namespaced functions, and `module::function(...)` path calls now resolve to those flattened functions. This covers the current demo shape with nested module function export syntax `pub fn`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/41_module_imports/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/41_module_imports/main.sla --out /tmp/41_module_imports.sa`
  - Verified with: `sa test /tmp/41_module_imports.sa`

- [done] `pub fn` now parses into function visibility metadata, and user-defined function symbols are lowered through stable internal SA names during codegen so source-level names like `exported_value` remain callable without colliding with backend symbol parsing.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/42_export_visibility/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/42_export_visibility/main.sla --out /tmp/42_export_visibility.sa`
  - Verified with: `sa test /tmp/42_export_visibility.sa`
  - Regression verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/41_module_imports/main.sla --out /tmp/41_module_imports.sa`
  - Regression verified with: `sa test /tmp/41_module_imports.sa`
  - Regression verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/40_impl_block_state/main.sla --out /tmp/40_impl_block_state.sa`
  - Regression verified with: `sa test /tmp/40_impl_block_state.sa`

- [done] Rust-style slice type syntax `[T]` in type position now lowers to Sla `Slice<T>` metadata, borrowed array arguments can coerce to borrowed slices for calls like `f(&array)`, `copied()` is accepted on slice iterators for copyable element paths, and slice `iter().copied().sum()` now lowers through runtime-length slice loops.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/44_slice_iteration/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/44_slice_iteration/main.sla --out /tmp/44_slice_iteration.sa`
  - Verified with: `sa test /tmp/44_slice_iteration.sa`

- [done] Closure parameter type annotations can now be omitted in contextual iterator paths like `map/filter/fold`, so Rust-style closures such as `|x| x * 2` type-check from the surrounding call context instead of requiring explicit `|x: i32|`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/49_pipeline_map/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/49_pipeline_map/main.sla --out /tmp/49_pipeline_map.sa`
  - Verified with: `sa test /tmp/49_pipeline_map.sa`

- [done] Rust-style `Option<T>` and `Result<T, E>` now use the `sa_std` option/result macro surface for `Some(...)`, `None`, `Ok(...)`, `Err(...)`, `.unwrap()`, `.unwrap_or(...)`, and postfix `?`, instead of demo-local fake structs/enums.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/46_option_default/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/46_option_default/main.sla --out /tmp/46_option_default.sa`
  - Verified with: `sa test /tmp/46_option_default.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/50_error_chain/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/50_error_chain/main.sla --out /tmp/50_error_chain.sa`
  - Verified with: `sa test /tmp/50_error_chain.sa`

- [done] `Option<T>.map(|x| ...)` now contextually infers closure parameter types and lowers to real Option tag/value control flow, preserving Rust-style `Some(3).map(|x| x + 5).unwrap_or(0)` semantics.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/18_option_map/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/18_option_map/main.sla --out /tmp/18_option_map.sa`
  - Verified with: `sa test /tmp/18_option_map.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/19_result_question/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/19_result_question/main.sla --out /tmp/19_result_question.sa`
  - Verified with: `sa test /tmp/19_result_question.sa`

- [done] Generic function calls now infer type arguments from call-site argument types for Rust-style calls such as `pair_sum(11, 31)` without explicit `<i32>`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/48_generic_pair/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/48_generic_pair/main.sla --out /tmp/48_generic_pair.sa`
  - Verified with: `sa test /tmp/48_generic_pair.sa`

- [done] Rust-style `Rc<T>` construction, cloning, and dereference now type-check and lower through `sa_std/core/rc.sa` macros (`RC_NEW`, `RC_CLONE`, `RC_GET`) for `Rc::new(...)`, `.clone()`, and `*rc`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/51_refcount/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/51_refcount/main.sla --out /tmp/51_refcount.sa`
  - Verified with: `sa test /tmp/51_refcount.sa`

- [done] Rust-style `VecDeque<T>` construction from array literals, `rotate_left(count)`, and indexing now type-check and lower through `sa_std/vec_deque.sa`; `rotate_left` uses pop-front/push-back lowering to preserve Rust rotation semantics.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/52_queue_rotate/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/52_queue_rotate/main.sla --out /tmp/52_queue_rotate.sa`
  - Verified with: `sa test /tmp/52_queue_rotate.sa`

- [done] Rust-style `HashMap<K, V>` construction, insertion, lookup, and `Option<&V>.copied().unwrap_or_default()` now type-check and lower through `sa_std/hashmap.sa` plus thin generated SA macros over `MAP_*` and `OPTION_*`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/53_cache_hits/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/53_cache_hits/main.sla --out /tmp/53_cache_hits.sa`
  - Verified with: `sa test /tmp/53_cache_hits.sa`

- [done] Rust-style integer literal suffixes used by current demos, repeat array expressions like `[0u8; 4]`, and `[u8; N].fill(value)` now parse/type-check/lower with byte-fill semantics through a thin generated SA macro over `sa_std/core/mem.sa` `sa_mem_set`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/54_mem_fill/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/54_mem_fill/main.sla --out /tmp/54_mem_fill.sa`
  - Verified with: `sa test /tmp/54_mem_fill.sa`

- [done] Array indexing codegen now releases address-computation temporaries after loads, fixing verifier leaks exposed by repeated `data[i]` checks.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/54_mem_fill/main.sla --out /tmp/54_mem_fill.sa`
  - Verified with: `sa test /tmp/54_mem_fill.sa`

- [done] Rust-style `Self` inside `impl` methods, `Type::associated_fn(...)` calls for user impl methods, chainable by-value `self` builder methods, and string-slice printing/comparison now lower through existing `sa_std/string.sa` macros (`STRING_PTR`, `STRING_LEN`, `STR_EQ`).
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/55_builder_pattern/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/55_builder_pattern/main.sla --out /tmp/55_builder_pattern.sa`
  - Verified with: `sa test /tmp/55_builder_pattern.sa`
  - Regression verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/17_associated_fn/main.sla`
  - Regression verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/17_associated_fn/main.sla --out /tmp/17_associated_fn.sa`
  - Regression verified with: `sa test /tmp/17_associated_fn.sa`

- [done] Rust-style `for item in array` iteration and `+=` assignment now parse, type-check, and lower with per-element array loads while preserving existing `start..end` range-for behavior.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/57_event_loop/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/57_event_loop/main.sla --out /tmp/57_event_loop.sa`
  - Verified with: `sa test /tmp/57_event_loop.sa`
  - Regression verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/02_mutability/main.sla --out /tmp/02_mutability.sa`
  - Regression verified with: `sa test /tmp/02_mutability.sa`

- [done] Rust-style `thread::spawn(|| ...)` for zero-argument closures now lowers through real SA pthread externs, generated `@ffi_wrapper` spawn bridges, generated worker vtables, and `JoinHandle<T>.join() -> Result<T, i32>` so `.unwrap()` reuses `sa_std/core/result.sa` `RESULT_UNWRAP`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/61_thread_pool/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/61_thread_pool/main.sla --out /tmp/61_thread_pool.sa`
  - Verified with: `sa test /tmp/61_thread_pool.sa`

- [done] Top-level `println(...)` codegen now emits its required `sa_std/io/print.sai` and `sa_std/fmt.sai` imports so demos can use the language macro surface without hand-declaring print externs.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/61_thread_pool/main.sla --out /tmp/61_thread_pool.sa`
  - Verified with: `sa test /tmp/61_thread_pool.sa`

- [done] Rust-style `mpsc::channel()` destructuring plus `Sender<T>.send(value).unwrap()` and `Receiver<T>.recv().unwrap()` now type-check and lower through `sa_std/sync/mpsc.sa` (`MPSC_NEW`, `MPSC_SEND`, `MPSC_RECV`, `MPSC_FREE`) with `Result` wrapping delegated to `sa_std/core/result.sa`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/62_channel_pingpong/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/62_channel_pingpong/main.sla --out /tmp/62_channel_pingpong.sa`
  - Verified with: `sa test /tmp/62_channel_pingpong.sa`

- [done] Rust-style `HashMap<K, V>` indexing expression `map[key]` now type-checks as `V` and lowers through `sa_std/hashmap.sa` `MAP_GET`, including a panic path for missing keys to match Rust `Index` semantics.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/63_router_table/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/63_router_table/main.sla --out /tmp/63_router_table.sa`
  - Verified with: `sa test /tmp/63_router_table.sa`

- [done] Array `.len()` now type-checks its receiver and lowers to the compile-time array length instead of string length macros, while `len` returns Rust-style `usize` metadata.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/64_file_manifest/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/64_file_manifest/main.sla --out /tmp/64_file_manifest.sa`
  - Verified with: `sa test /tmp/64_file_manifest.sa`

- [done] String literal `let` bindings now construct the `Slice` directly in the destination binding, avoiding stack-slice moves while preserving `sa_std/string.sa` slice semantics.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/15_string_bytes/main.sla --out /tmp/15_string_bytes.sa`
  - Verified with: `sa test /tmp/15_string_bytes.sa`

- [done] `Vec<T>.into_iter().sum()` now uses the actual vector element size during pointer stepping instead of assuming 8-byte elements, preserving `Vec<i32>` iteration semantics.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/66_actor_mailbox/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/66_actor_mailbox/main.sla --out /tmp/66_actor_mailbox.sa`
  - Verified with: `sa test /tmp/66_actor_mailbox.sa`

- [done] `sa_std/string_format.sa` now provides `FORMAT_BEGIN`, `FORMAT_PUSH_*`, `FORMAT_AS_STR`, and `FORMAT_FREE` macros so Sla `format(...)` lowers through `sa_std` instead of implementing formatting in Zig.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla check demos/rosetta/69_serializer/main.sla`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/69_serializer/main.sla --out /tmp/69_serializer.sa`
  - Verified with: `sa test /tmp/69_serializer.sa`

- [done] String literal Slice lowering now uses escaped UTF-8 byte length instead of source spelling length, fixing literals such as `"{\"id\":7}"`.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/69_serializer/main.sla --out /tmp/69_serializer.sa`
  - Verified with: `sa test /tmp/69_serializer.sa`

- [done] Full rosetta `sa_std` macro/lowering gap audit added at `docs/sa_std_macro_gap_audit.md`, covering the shared Vec/String/collections/concurrency/io/pattern gaps across all 300 Rust references.
  - Evidence: scanned `300` `demos/rosetta/*/main.rs` files and current `/home/vscode/.sa/std` macro surface.
  - Next implementation priority: broad receiver-typed `.len()` lowering, then `VecDeque`, `BTreeMap`, `AtomicI32`, and pattern sugar blocks.

- [done] Receiver-typed `.len()` lowering now routes through existing `sa_std` macros for `Vec`, `VecDeque`, `HashMap`, and `BTreeMap`, while preserving array compile-time length and string/slice length paths.
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/64_file_manifest/main.sla --out /tmp/64_file_manifest.sa`
  - Verified with: `sa test /tmp/64_file_manifest.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/15_string_bytes/main.sla --out /tmp/15_string_bytes.sa`
  - Verified with: `sa test /tmp/15_string_bytes.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/52_queue_rotate/main.sla --out /tmp/52_queue_rotate.sa`
  - Verified with: `sa test /tmp/52_queue_rotate.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/66_actor_mailbox/main.sla --out /tmp/66_actor_mailbox.sa`
  - Verified with: `sa test /tmp/66_actor_mailbox.sa`
  - Verified with: `zig build -Doptimize=ReleaseSmall local-cli -- sla build demos/rosetta/63_router_table/main.sla --out /tmp/63_router_table.sa`
  - Verified with: `sa test /tmp/63_router_table.sa`

## Manually Rewritten Demos

- [done] `06_enum_and_match`
- [done] `07_trait_vtable`
- [done] `10_generics_monomorph`
- [done] `11_tuples`
- [done] `13_array_sum`
- [done] `14_slice_window`
- [done] `15_string_bytes`
- [done] `16_methods`
- [done] `17_associated_fn`
- [done] `18_option_map`
- [done] `19_result_question`
- [done] `20_boxed_value`
- [done] `22_break_continue`
- [done] `24_factorial`
- [done] `25_fibonacci`
- [done] `23_nested_loops`
- [done] `26_reference_return`
- [done] `27_move_semantics`
- [done] `28_borrow_chains`
- [done] `29_const_data`
- [done] `30_manual_guard_branch`
- [done] `31_trait_static_dispatch`
- [done] `32_trait_object_vector`
- [done] `33_iterator_map`
- [done] `34_iterator_filter`
- [done] `35_iterator_fold`
- [done] `36_tuple_struct`
- [done] `37_newtype`
- [done] `38_generic_struct_i32`
- [done] `39_generic_enum_i32`
- [done] `40_impl_block_state`
- [done] `41_module_imports`
- [done] `42_export_visibility`
- [done] `43_tagged_union`
- [done] `44_slice_iteration`
- [done] `45_config_merge`
- [done] `46_option_default`
- [done] `47_tuple_swap`
- [done] `48_generic_pair`
- [done] `49_pipeline_map`
- [done] `50_error_chain`
- [done] `51_refcount`
- [done] `52_queue_rotate`
- [done] `53_cache_hits`
- [done] `54_mem_fill`
- [done] `55_builder_pattern`
- [done] `56_state_machine`
- [done] `57_event_loop`
- [done] `58_borrow_update`
- [done] `59_method_counter`
- [done] `60_enum_branch`
- [done] `61_thread_pool`
- [done] `62_channel_pingpong`
- [done] `63_router_table`
- [done] `64_file_manifest`
- [done] `65_job_scheduler`
- [done] `66_actor_mailbox`
- [done] `67_resource_pool`
- [done] `68_parser_tokens`
- [done] `69_serializer`
- [done] `70_integration_service`
- [done] `71_pipeline_stage`
- [done] `72_graph_walk`
- [done] `73_scene_nodes`
- [done] `74_component_store`
- [done] `104_if_let_chains`
- [done] `105_let_else`
- [done] `146_never_type_fallback`

## Pending Next

- [pending] `while let` / `if let` / `let else` for Result/custom enum patterns; `while let Some(...)`, chained `if let Some(...)`, `let Some(...) else`, and `match Option<T>` for Option are done.
- [pending] direct reuse path for imported `sa_std` macros where Sla demos need them
