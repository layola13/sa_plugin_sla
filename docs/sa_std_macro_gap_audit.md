# sa_std Macro / Sla Lowering Gap Audit

This audit is for the rosetta demos. It is not a batch conversion plan; demos still must be rewritten and verified manually. The purpose is to avoid discovering shared `sa_std` macro/lowering gaps one demo at a time.

## Scan Scope

- Rust references scanned: `demos/rosetta/*/main.rs` (`301` files, including `301_operator_overload_add`).
- Current `sa_std` macro surface scanned from `/home/vscode/.sa/std`.
- Current Sla lowering surface scanned in `src/type_checker.zig` and `src/codegen.zig`.

## Cross-Demo Demand Matrix

These buckets are extracted from every Rust reference demo. They are intentionally grouped by reusable `sa_std` macro families and Sla lowering surfaces, so implementation can be done by capability block instead of one-off demo fixes.

| Area | Rust demos requiring it | Existing macro families to reuse first | Primary action |
| --- | --- | --- | --- |
| `Vec<T>` / `vec![...]` | `32`, `61`, `66`, `86`, `90`, `136`, `168`, `184` | `VEC_NEW`, `VEC_PUSH`, `VEC_LEN`, `VEC_GET`, `VEC_REMOVE`, `VEC_TRY_POP`, `VEC_AS_SLICE`, `VEC_FREE`, `ITER_*` | Current `Vec::new`, `vec(...)`, `push`, `pop -> Option<T>`, `remove`, and indexing paths are covered for 8-byte-slot demo values; remaining grouped work is string `join`, more iterator collect shapes, and non-8-byte packed Vec storage if a demo demands it. |
| `VecDeque<T>` | `52`, `89` | `VEC_DEQUE_NEW`, `VEC_DEQUE_PUSH_BACK`, `VEC_DEQUE_TRY_POP_FRONT`, `VEC_DEQUE_ROTATE_LEFT`, `VEC_DEQUE_GET`, `VEC_DEQUE_LEN`, `VEC_DEQUE_FREE` | `52` mostly covered; add constructor + `push_back` + `pop_front -> Option<T>` before `89`. |
| String / `&str` / formatting | `09`, `15`, `35`, `64`, `68`, `69`, `78`, `83`, `87`, `88`, `90`, `99`, `112`, `141`, `147`, `158`, `165`, `167`, `171`, `172`, `184`, `185`, `190` | `STR_LEN`, `STRING_LEN`, `STRING_AS_STR`, `STRING_BUF_*`, `STR_EQ`, `FORMAT_*`, `SLICE_*` | Treat `String` and `&str` separately; add typed `.as_ptr()`, `.bytes()/as_bytes()`, `join`, `iter().collect::<String>()`, and avoid hardcoded string lengths. |
| `Option<T>` / `Result<T, E>` | `09`, `18`, `19`, `46`, `50`, `53`, `61`, `62`, `89`, `101`, `102`, `104`, `105`, `108`, `135`, `136`, `146`, `171`, `173`, `177`, `180`, `181`, `182`, `184` | `OPTION_*`, `RESULT_*`, especially `UNWRAP`, `UNWRAP_OR`, `UNWRAP_OR_DEFAULT`, `IS_OK`, `IS_ERR`, `BRANCH`, `MATCH_*` | Stop hand-writing unwrap branches; route all unwrap/default/is_ok/is_err/map/flatten paths through macros and add pattern sugar over the same tags. |
| `HashMap` / `BTreeMap` / sets | `53`, `63`, `81`; set-like pressure later | `MAP_*`, `BTREE_MAP_*`, `SET_*`, `BTREE_SET_*` | `HashMap` and `BTreeMap` current string-key/i32-value paths are covered, including `new`, `insert`, `get`, indexing, receiver-typed `.len()`, and lexical `MAP_FREE` / `BTREE_MAP_FREE`; set APIs remain a future grouped block. |
| Atomics | `76`, `108`, `109` | `ATOMIC_I32_INIT`, `LOAD`, `STORE`, `FETCH_ADD`, `COMPARE_EXCHANGE`, ordering args | Implement `AtomicI32` as a real atomic slot, not a plain integer; support `Ordering::{SeqCst,Acquire,Release,Relaxed}` expression lowering. |
| Cell / RefCell | `101`, `106`, `107`, `124`, `161` | `CELL_U64_*`, `CELL_*`, `REFCELL_U64_*`, `REFCELL_*` | `Cell::new/get/set` is done for the current i32 demo path; `RefCell::new/borrow/borrow_mut` plus lexical borrow release is done for the current integer demo path; broader guard/resource cleanup remains pending. |
| Mutex / RwLock / mpsc / threads | `61`, `62`, `102`, `121`, `124`, `130`, `184` | `MUTEX_*`, `RWLOCK_*`, `MPSC_*`, existing pthread spawn bridge | `Mutex<i32>::new`, `lock().unwrap()`, guard deref/update, and lexical unlock are done for `102`; remaining grouped work is `RwLock` guards and broader thread/sync shapes. |
| FS / file descriptors | `181`, `182`, plus FFI demos | `FS_OPEN_READ`, `FS_CLOSE`, `FS_READ*`, `FS_METADATA*` | Add `File::open(...).unwrap()`, `AsRawFd::as_raw_fd`, and lexical file close. Add a tiny `sa_std` helper only if `as_raw_fd` has no macro facade. |
| Time / sleep | `09`, async demos | `TIME_NOW_*`, `TIME_SLEEP_MS`, `TIME_DURATION_*`, `TIME_INSTANT_*` | Use `sa_std/time.sa` for `Duration`, `Instant`, `SystemTime`, and real delay; do not fake elapsed time. |
| Future / async / await | `09`, `75`, `133`, `134`, `135`, `136`, `140` | `FUTURE_*`, `POLL_*`, `WAKER_*`, `TIME_*`, `VEC_*` | Ready async fn tail expressions and direct `.await` over ready futures are covered for `75` and `136`; remaining grouped work is real time delay for `09`, join/select/stream/yield shapes for `133`-`135`/`140`. |
| Box / Rc / raw ownership | `20`, `32`, `51`, `151`, `153`, `154`, `159`, `160`, `178` | `BOX_*`, `RC_*`, `ARC_*`, `MANUALLY_DROP` may need facade | Existing `Box::new`/`Rc` paths are partial; add `into_raw/from_raw`, `mem::forget`, `ManuallyDrop` as ownership features, not print shortcuts. |
| Pointer / unsafe / FFI | `111`-`120`, `153`, `154`, `160`, `185`-`187` | `PTR_*`, `NONNULL_*`, `CSTR/CSTRING_*`, extern support | `111` extern C ABI definition/call is covered with `@no_mangle pub extern "C" fn` and `unsafe { ... }`; `112` array `.as_ptr()`, raw pointer `.add(index)`, and deref-read baseline are now covered through thin pointer lowering; `113` now has native `union` declarations, single-field union literals, and unsafe union field reads with offset-0 overlay layout; `114` now has `extern "C" fn(...)` function-pointer types and indirect callback calls lowered through the same vtable/call-indirect shape used in `~/projects/sci`; `120` volatile read now imports `sa_std/ptr.sa` and expands `PTR_READ_VOLATILE_I32`. Remaining work is repr attributes/layout controls and real foreign-library linking shapes. |
| Patterns | `06`, `30`, `39`, `43`, `56`, `60`, `101`, `104`, `105`, `135`, `136`, `146` | `OPTION_BRANCH`, `RESULT_BRANCH`, enum match lowering, `WHILE_LET` | `while let Some(x)`, chained `if let Some(...) && let ...`, `let Some(...) else`, and `match Option<T>` are covered for Option; remaining grouped work is Result/custom enum pattern sugar and match guards over actual tags. |
| Traits / supertraits | `07`, `31`, `110`, later trait-object demos | `DYN_CALL`, trait-object vtable helpers | Static trait methods and `trait B: A` declaration syntax are covered for `110`; dynamic supertrait vtables/upcasting remain pending. |

## Immediate Macro Reuse Rules

- `String` length and byte access must use `STR_LEN` / `STRING_LEN` / `STRING_BYTE_LEN` / `SLICE_GET_LEN`; never bake source spelling lengths into generated code except when forming static literals.
- `Option.unwrap_or` / `unwrap_or_default` must use `OPTION_UNWRAP_OR` / `OPTION_UNWRAP_OR_DEFAULT`; `Result` equivalents must use `RESULT_*` macros.
- Collection `len()` must dispatch by receiver type: array compile-time length, `Slice`/`&str` length macros, `String` via `FORMAT_AS_STR` or `STRING_BUF_AS_STR`, `Vec` via `VEC_LEN`, `VecDeque` via `VEC_DEQUE_LEN`, maps/sets via their own `*_LEN` macros.
- `VecDeque::pop_front()` and `Vec::pop()` lower to `Option<T>` using `OPTION_NEW_SOME` / `OPTION_NEW_NONE` around the underlying `TRY_*` macro result.
- Atomic methods must call `ATOMIC_*` macros even when single-threaded output would be the same.
- Lexical resource release should be compiler-owned cleanup, not a user-visible `drop` keyword.

## Unified Rust API To `sa_std` Macro Map

This table is the working coordination surface for rosetta demos. Before rewriting more demos, check this table first and extend a whole API family when the missing API is reusable.

| Rust-shaped API family | Demos seen in scan | `sa_std` macro surface | Sla lowering status |
| --- | --- | --- | --- |
| `VecDeque::from`, index, `rotate_left` | `52` | `VEC_DEQUE_NEW`, `VEC_DEQUE_PUSH_BACK`, `VEC_DEQUE_GET`, `VEC_DEQUE_ROTATE_LEFT` | Done for `52`. |
| `VecDeque::new`, `.push_back`, `.pop_front() -> Option<T>` | `89`; future queue/executor demos | `VEC_DEQUE_NEW`, `VEC_DEQUE_PUSH_BACK`, `VEC_DEQUE_TRY_POP_FRONT`, `OPTION_NEW_SOME`, `OPTION_NEW_NONE` | Done for `89`; empty `VecDeque<infer>` is resolved by `push_back`. |
| `Vec::new`, `vec![...]` / `vec(...)`, `.push`, `.pop() -> Option<T>`, `.remove`, indexing | `32`, `66`, `86`, `136`, `168`, `184`, `190` | `VEC_NEW`, `VEC_PUSH`, `VEC_POP`, `VEC_REMOVE`, `VEC_GET`, `VEC_LEN`, `VEC_FREE`, `OPTION_*` | Done for current 8-byte-slot demo paths: empty `Vec<infer>`, `push` as void, `pop -> Option<T>`, `remove`, indexing, and `Vec<Future>` queue use in `136`. |
| Array/slice/string `.len()` | `15`, `35`, `64`, `68`, `69`, `74`, `78`, `83`, `87`, `88`, `99`, `141`, `147`, `158`, `165`, `167`, `171`, `172` | `ARRAY_LEN`, `SLICE_GET_LEN`, `STR_LEN`, `STRING_LEN`, `STRING_BUF_LEN`, `VEC_LEN`, `VEC_DEQUE_LEN`, `MAP_LEN`, `BTREE_MAP_LEN` | Receiver-typed routing exists for arrays, vec, vecdeque, hashmap, btree, format strings, and string-like fallback; keep extending by receiver type only. |
| `&str` / `String` byte access and pointer access | `112`, `141`, `147`, `158`, `185`, `190` | `STR_AS_BYTES`, `STR_AS_PTR`, `STR_LEN`, `STRING_AS_BYTES`, `STRING_AS_PTR`, `STRING_BUF_AS_STR`, `STRING_BUF_INTO_BYTES` | `.len()` and equality paths are partial; raw pointer receiver plumbing now exists from array `.as_ptr()` for `112`, but string/byte `.as_ptr()` and `.bytes()/as_bytes()` remain missing. |
| `join` on string slices / CLI arg-like vecs | `90` | `STRING_BUF_NEW`, `STRING_BUF_PUSH_STR`, `STRING_BUF_AS_STR`, `FORMAT_*` | Missing as a grouped String/Vec lowering; do not fake by printing hardcoded joined output. |
| `Option` combinators | `18`, `46`, `53`, `89`, `104`, `105`, `135`, `136`, `146`, `171` | `OPTION_MAP`, `OPTION_UNWRAP`, `OPTION_UNWRAP_OR`, `OPTION_UNWRAP_OR_DEFAULT`, `OPTION_IS_SOME`, `OPTION_IS_NONE`, `OPTION_BRANCH` | `Some/None`, `map`, `unwrap`, `unwrap_or`, `unwrap_or_default`, `copied`, `VecDeque::pop_front`, `Vec::pop`, `while let Some(...)`, chained `if let Some(...)`, `let Some(...) else`, and `match Option<T>` are covered for current paths. |
| `Result` combinators | `19`, `50`, `61`, `108`, `173`, `184` | `RESULT_NEW_OK`, `RESULT_NEW_ERR`, `RESULT_UNWRAP`, `RESULT_UNWRAP_OR`, `RESULT_IS_OK`, `RESULT_IS_ERR`, `RESULT_BRANCH` | Current simple `?`, `unwrap`, `unwrap_or`, `is_ok/is_err` paths are covered; `catch_unwind`/panic result shapes are pending. |
| `HashMap` / `BTreeMap` | `53`, `63`, `81` | `MAP_*`, `BTREE_MAP_*`, `OPTION_*` | Current string-key/i32-value paths are done for both map families: `new`, `insert`, `get`, indexing, receiver-typed `.len()`, and lexical free. |
| `Cell` / `RefCell` / guards | `101`, `102`, `106`, `107`, `124` | `CELL_*`, `REFCELL_*`, `MUTEX_*`, `RWLOCK_*` | `Cell::new/get/set` is done for `106`; `RefCell::new/borrow/borrow_mut` with lexical borrow release is done for `107`; `Mutex<i32>` guard lock/unwrap/deref/update/lexical unlock is done for `102`; remaining grouped work is `RwLock` guards and broader resource cleanup. |
| Time / async / await | `09`, `75`, `133`-`136`, `140` | `TIME_*`, `FUTURE_*`, `TASK_*`, `WAKER_*`, plus collection queues | Pending as one async/time block; `09` must use real `Duration`, `SystemTime`, `Instant`, and sleep. |

## Capability Blocks To Implement Before More Demo Rewrites

1. `AtomicI32` block: `AtomicI32::new`, `load`, `store`, `fetch_add`, `compare_exchange`, `Ordering::*`. Covers `76`, `108`, `109`.
2. Collection block A: done for `VecDeque::new/push_back/pop_front -> Option<T>` and current `Vec::new/push/pop/remove/index` paths, including the `Vec<Future>` task queue in `136`.
3. Collection block B: done for `BTreeMap::new/insert/get/index/len/free`, covering `81` and the grouped map smoke path.
4. Pattern block: Option `while let`, chained `if let`, `let else`, and `match Option<T>` are done for `104`/`105`/`136`/`146`; remaining work is Result/custom enum `if let` / `while let` / `let else` and match guards. Covers `101`, `135`.
5. Interior mutability / guard block: `Cell`, `RefCell`, and current `Mutex<i32>` lexical cleanup paths are done for `102`, `106`, and `107`; remaining work is broader resource cleanup and `RwLock` guards. Covers `101`, `102`, `106`, `107`, `124`.
6. Time/async block: `Duration`, `Instant`, `SystemTime`, real `sleep`, ready async functions, `await`, then join/select/stream/yield. Covers `09`, `75`, `133`-`136`, `140`.
7. IO/raw ownership block: `File`, `AsRawFd`, `Box::into_raw/from_raw`, `mem::forget`, pointer `as_ptr/add/read`. Covers `112`, `153`, `154`, `159`, `181`, `182`.

## Already Covered Enough For Current Demos

- `println(...)` lowers through `sa_std/io/print.sai` and `sa_std/fmt.sai`.
- `format(...)` lowers through `sa_std/string_format.sa` `FORMAT_*` macros.
- `AtomicI32::new`, `load`, `store`, `fetch_add`, `compare_exchange`, and `Ordering::{SeqCst,Acquire,Release,Relaxed,AcqRel}` lower through `sa_std/sync/atomic.sa` / `.sal` macros for `76`, `108`, and `109`.
- `Cell::new`, `get`, and `set` lower through `sa_std/core/cell.sa` `CELL_SET` / `CELL_GET` for the current i32 `106` path.
- `RefCell::new`, `borrow`, and `borrow_mut` lower through `sa_std/core/refcell.sa` `REFCELL_U64_*` macros for the current integer `107` path, with compiler-owned release on lexical scope exit or temporary use.
- `Mutex<i32>::new`, `lock().unwrap()`, guard deref/read/update, and compiler-owned lexical unlock lower through explicit `sa_std/sync/mutex.sa` plus `sa_std/core/result.sa` imports for `102`.
- `VecDeque::new`, `push_back`, and `pop_front -> Option<T>` lower through `VEC_DEQUE_NEW`, `VEC_DEQUE_PUSH_BACK`, `VEC_DEQUE_TRY_POP_FRONT`, and `OPTION_NEW_SOME` / `OPTION_NEW_NONE` for `89`.
- `Vec::new`, `vec(...)`, `push`, `pop -> Option<T>`, `remove`, and indexing lower through `VEC_NEW`, `VEC_PUSH`, `VEC_POP`, `VEC_REMOVE`, `VEC_GET`, and `OPTION_NEW_SOME` / `OPTION_NEW_NONE` for current 8-byte-slot demo paths including `86` and the `tmp_vec_pop_smoke` coverage.
- String literals lower as `Slice` with escaped byte length.
- Array `.len()` lowers to compile-time array length.
- Array/slice/vec iterator chains used so far: `iter`, `into_iter`, `map`, `filter`, `fold`, `sum`.
- `Option` / `Result`: `Some`, `None`, `Ok`, `Err`, `unwrap`, `unwrap_or`, `?` for existing simple paths.
- `Vec`: `vec(...)`, `push`, `into_iter().sum()` for current element sizes.
- `VecDeque::from([...])`, indexing, and `rotate_left` for current queue demo.
- `HashMap::new`, `insert`, `get`, indexing, and `copied().unwrap_or_default()` for current string-key/i32-value demos.
- `Box::new`, `Rc::new`, `Rc::clone`, primitive deref paths.
- `thread::spawn(|| ...)`, `JoinHandle<T>.join().unwrap()` for zero-arg closures returning simple values.
- `mpsc::channel()`, `send(...).unwrap()`, `recv().unwrap()` for current `i32` payload path.
- Static trait dispatch, borrowed trait-object calls for current `dyn Trait` paths, and `trait B: A` declaration syntax for the static supertrait demo `110`.
- `@no_mangle pub extern "C" fn` definitions lower to raw unmangled SA symbols, and `unsafe { ... }` expression blocks preserve the Rust unsafe-call boundary for `111`.

## P0: Fix Before Continuing Many More Demos

These are shared gaps hit by near-term demos, not isolated demo hacks.

| Area | Rust demo pressure | `sa_std` macro status | Missing Sla lowering |
| --- | --- | --- | --- |
| Generic `.len()` | `74_component_store`, `78_cli_args`, `81_kv_store`, many array/string demos | `VEC_LEN`, `VEC_DEQUE_LEN`, `MAP_LEN`, `BTREE_MAP_LEN`, string/slice len exist | Route `.len()` by receiver type: array, slice/string, `String`, `Vec`, `VecDeque`, `HashMap`, `BTreeMap`, set types. |
| `VecDeque::new` + queue ops | `89_job_queue`, later executor queues | `VEC_DEQUE_NEW`, `PUSH_BACK`, `TRY_POP_FRONT`, `FREE` exist | Done for constructor, `push_back`, and `pop_front -> Option<T>`; cleanup ownership remains a later lexical release improvement. |
| `BTreeMap` | `81_kv_store` | `BTREE_MAP_NEW`, `INSERT`, `GET`, `LEN`, `FREE` exist | Done for `BTreeMap::new`, `insert`, indexing/get, len, and lexical cleanup through `BTREE_MAP_FREE`. |
| `AtomicI32` | `76_lockfree_counter`, `108_atomic_spin_lock`, `109_atomic_fetch_add` | `sync/atomic.sa` exists | Done for `AtomicI32::new`, `load`, `store`, `fetch_add`, `compare_exchange`, and ordering constants; extend to other atomic widths only when demos require them. |
| `Cell` / `RefCell` / `Mutex` | `101`, `102`, `106`, `107`, `124` | `CELL_*`, `REFCELL_*`, `MUTEX_*` macros exist | `Cell::new/get/set` is done for i32 `106`; `RefCell::new/borrow/borrow_mut` with lexical borrow release is done for integer `107`; `Mutex<i32>` lock guard cleanup is done for `102`; next add broader RAII/resource semantics needed by `101` and `124`. |
| Pattern sugar | `101`, `104`, `105`, `135`, `136`, `146` | Option macros exist | `while let Some(...)`, chained `if let Some(...)`, `let Some(...) else`, and `match Option<T>` are done for Option; add broader Result/custom enum pattern paths next. |

## P1: Standard Library Facades To Plan As Groups

| Area | Rust demo pressure | `sa_std` macro status | Missing Sla lowering |
| --- | --- | --- | --- |
| `Mutex` guard | `102_raii_guard` | `MUTEX_NEW`, `MUTEX_NEW_I32`, `LOCK`, `UNLOCK` exist | Done for current `Mutex<i32>` path: `Mutex::new`, `lock().unwrap()`, guard deref/update, and lexical guard release without a `drop` keyword. |
| File RAII | `181_file_descriptor_raii`, `182_mmap_memory_mapping` | `FS_OPEN_READ`, `FS_CLOSE`, read/metadata macros exist | Add `File::open(...).unwrap()` and lexical close cleanup. |
| `Box` raw APIs | `153_box_into_raw`, `154_box_from_raw` | `BOX_*` low-level macros exist | Add `Box::into_raw`, unsafe `Box::from_raw`, pointer ownership transfer. |
| `String` collection | `190_base64_encode_simd` | `STRING_BUF_*`, `FORMAT_*`, vec/string macros exist | Add `iter().collect::<String>()` or equivalent typed collect into `String`. |
| More `Vec` surface | `89`, `136`, later queue/task demos | `VEC_NEW`, `POP`, `LEN`, `PUSH`, etc. exist | Current `Vec::new`, `pop -> Option<T>`, typed empty Vec inference via `push`, `remove`, and indexing are done; remaining vector work is broader iter/collect/join surfaces. |

## P2: Larger Semantic Features

| Area | Rust demo pressure | Notes |
| --- | --- | --- |
| Async runtime/task shapes | `75`, `133`-`136`, `140` | Current `async/await` support is only a small ready-future path. Need grouped design for stream, task queue, yield/select/join-all semantics. |
| Dynamic supertrait objects / upcasting | `110`, `163`, `164` | Static `trait B: A` syntax is covered; dyn vtable composition and trait upcasting need a separate trait-object phase. |
| Thread-local static | `124_thread_local_storage` | Needs `static` + thread local semantics or explicit accepted subset. |
| Unsafe/FFI/raw pointers | `112`-`120`, `153`-`160`, `181`-`187` | `111` extern C ABI definition/call is done; `112` raw pointer arithmetic baseline, `113` union overlay baseline, and `114` extern callback/function-pointer baseline are done. The remaining low-level demos should still be tackled as a separate FFI/raw pointer phase. |

## Immediate Recommended Order

1. Implement receiver-typed `.len()` routing broadly before continuing past `74`.
2. Done: implement `VecDeque::new/push_back/pop_front -> Option<T>` as one collection block before `89`.
3. Done: implement `BTreeMap` lowering as one collection block before `81`.
4. Done: `AtomicI32` lowering for `76/108/109`.
5. Done for Option `while let` / chained `if let` / `let else` / `match` in `104`, `105`, `136`, and `146`; implement Result/custom enum pattern paths before `101/135`.

## Policy

- Prefer existing `sa_std` macros. Add `sa_std` macros first when a Rust-shaped primitive is missing.
- Keep Zig lowering thin: type-directed dispatch and macro orchestration only.
- Do not batch-generate `.sla` demos from this audit. Use the audit to guide manual rewrite and verification.
