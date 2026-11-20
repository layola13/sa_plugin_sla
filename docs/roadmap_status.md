# Completion Roadmap and Current Progress

> This is the English counterpart of the Chinese document [完成路线图与当前进度](./roadmap_status_cn.md).

> **Document version**: v0.1 / 2026-07-01
> **Status**: Based on `tasks.md`, `progress.md`, and the actual code implementation
> **Related**: [`architecture_cn.md`](./architecture_cn.md), [`testing_and_verification_cn.md`](./testing_and_verification_cn.md)
>
> **2026-11-05 status note**: This document is a progress snapshot from 2026-07-01; the metrics and the "fallback" narratives below reflect the state at that time. The SA-compatible fallback path was removed in its entirety on 2026-09-28 (commit `e96e6b39`): the SAB path is now direct-only, unsupported features fail loudly with `UnsupportedSabDirectFeature`, and `SLA_SAB_NO_FALLBACK` is no longer read by the source code. The current authoritative statement of the SAB contract is the sala repository's [SAB Format Whitepaper (Specification)](https://github.com/layola13/sala/blob/main/content/03_sa_asm/08_sab_whitepaper.html); for the plugin-side current state, see [`sab_pipeline_cn.md`](./sab_pipeline_cn.md) and [`architecture_cn.md`](./architecture_cn.md).

---

## 1. Current Progress Summary (as of 2026-07-01)

| Dimension | Current value | Target | Completion |
|-----------|---------------|--------|------------|
| No-fallback sweep | **58/69** | 69/69 | **84%** |
| Y/shared-lowering | **72%** | 100% | **72%** |
| Direct SAB fallback-removal | **88%** | 100% | **88%** |
| Overall progress (weighted) | ~80% | 100% | **~80%** |

### 1.1 Definitions of Progress Metrics

- **No-fallback sweep**: the number of `tests/test_unit_*.sla` passing with `SLA_SAB_NO_FALLBACK=1`. Grew from an initial 36/64 to 58/69 (5 test files were added along the way).
- **Y/shared-lowering**: the proportion of lowering logic implemented through the shared rules in `lowering_rules.zig`. Grew from 28% to 72%.
- **Direct SAB fallback-removal**: the coverage of SAB compilations that do not go through the SA-compatible fallback path. Grew from 72% to 88%.

### 1.2 Evolution Trajectory

Evolution of the three metrics after each feature increment:

```
Slice                              Y/Shared   Fallback   Sweep
初始基线                             28%        72%       36/64
Y 型前端主干提取                      45%        72%       —
数组字段 ABI 收敛                     48%        73%       38/64
Dyn-borrow plan 消费                 50%        74%       39/64
静态分发符号收敛                      52%        76%       43/64
Vec index-assign metadata            54%        78%       45/64
定长数组解构                          55%        79%       46/64
Cell bool metadata                   56%        80%       47/64
Option 闭包方法                       58%        81%       48/64
智能指针/RefCell 收敛                 66%        85%       50/64
导入宏 (Phase 2A)                   72%        88%       58/69
```

---

## 2. Precise Location of the 11 Remaining Failures

Each failing test file has a clear Phase assignment:

### Phase 3: Calls/Assignments (3 failures)

| Test file | Failure reason | Impact |
|-----------|----------------|--------|
| `assign_move_cleanup` | `UseAfterMove next` — coordination of move/use state with assignment/loop cleanup | Intersection of Phase 3 + Phase 5 |
| `var_comprehensive` | Complete shared calls, aggregate copies, result-target strategy | Phase 3 + Phase 5 |
| `rc_dyn_trait` | dyn-borrow/call materialization + Rc metadata | Phase 3 + Phase 4 |

### Phase 4: Std Metadata (3 failures)

| Test file | Failure reason |
|-----------|----------------|
| `sets` | Set collection operations (std surface metadata + sa_std macros) |
| `std_import` | Standard-library import resolution |
| `sla_import_nested_contract` | Nested contract imports |

### Phase 5: Aggregates/Enums/Derive (4 failures)

| Test file | Failure reason |
|-----------|----------------|
| `enum_match` | Tag/payload layout + match extraction |
| `derive_semantics` | Derive-generated operators/function calls |
| `struct_update` | Aggregate update/copy/drop layout |
| `spaceship_cmp` | Comparison/operator dispatch |

### Phase 6: Protocols/Iterators (2 failures)

| Test file | Failure reason |
|-----------|----------------|
| `for_in_protocol` | Non-generic protocol lowering |
| `generic_for_in_protocol` | Generic iterator specialization |

### Phase 8: Async (1 failure)

| Test file | Failure reason |
|-----------|----------------|
| `async_await` | async state machine/Future/task |

---

## 3. Completion Roadmap: Phases 1-9

### Phase 0: Operational Rules ✅ Completed

- Ensure the Y-shaped architecture remains unchanged
- Establish verification gate standards
- Establish the progress report template

### Phase 1: Borrowing, Precedence, and Smart-Pointer Convergence ✅ Completed

**Status**: 100%
**Key outcomes**:
- Shared smart-pointer helper functions (`smartPointerType`, `associatedRuleNeedsUnderlyingSmartPointer`)
- RefCell borrow/borrow_mut through a shared lifetime plan
- Pointer-backed index-address metadata (`VEC_GET_MUT_PTR_U64`)
- Rc/Arc clone through metadata + shared receiver materialization
- Removed the temporary SAB-only `genRcArcCloneCall` branch

**Open items**:
- Extract a complete shared address/projection plan (`&field`, `&index`, `&*smart`, `&**chain`)
- Fully move RefCell lifecycle into the shared plan

### Phase 2: Macro Expansion Completion ✅ Phase 2A Completed

**Status**: 2A (imported macros) 100%, remaining macro convergence ~70%

**2A outcomes**:
- Imported SA expression-output macros lowered through the shared Y path
- `ImportedMacroCallPlan` in `lowering_rules.zig`
- Direct SAB lowers arbitrary imported macros through a generically decoded macro-fragment path

### Phase 3: Complete Shared Call and Argument Materialization Plan ← Current Focus

**Goal**: all static/external/method/macro-expansion calls share a single call plan
**Expected progress**: Y/shared: 72% → 76%; Fallback: 88% → 90%; Sweep: 58/69 → 61/69

| Subtask | Priority |
|---------|----------|
| `CallArgMaterializationPlan` extension (array→slice borrow, dyn fat pointer, copy struct) | P0 |
| Call-result target plan (void, expression value) | P0 |
| Argument register ownership and release strategy | P0 |
| Target failures: `assign_move_cleanup`, `var_comprehensive`, `rc_dyn_trait` | P0 |

### Phase 4: Std Surface Metadata Generalization

**Goal**: add or extend metadata rule kinds only when a failing test proves the need
**Expected progress**: Y/shared: 76% → 84%; Fallback: 90% → 94%; Sweep: 61/69 → 64/69

| Subtask | Priority |
|---------|----------|
| Set collection operation metadata | P0 |
| Standard-library import helper functions | P0 |
| Rc/dyn metadata | P1 |
| Smart-pointer method maintenance | P1 |

### Phase 5: Aggregate, Enum, Derive, and Operator Semantics

**Goal**: struct update, enum payload layout, match extraction, derived equality/ordering/hash/debug, spaceship comparison, and copy/drop cleanup strategy
**Expected progress**: Y/shared: 84% → 92%; Fallback: 94% → 96%; Sweep: 64/69 → 68/69

### Phase 6: Protocol Lowering and Iteration

**Goal**: lower basic and generic `for in` protocols through a shared iterator/protocol plan
**Expected progress**: Fallback: 96% → 98%; Sweep: 68/69 → 69/69

### Phase 7: Import, Package, and Standard Resolution Parity

**Goal**: keep source expansion, import expansion, package metadata, nested contract loading, external callee resolution, standard-root resolution, and test filtering shared in the frontend trunk

### Phase 8: Async/Await and Remaining Runtime Shapes

**Goal**: handle async/await after the call/std/control-flow/import stages are stable; reuse shared Future/task surface metadata and state-machine rules

### Phase 9: Fallback-Removal Gate

**Goal**: full no-fallback sweep from 58/69 to 69/69

**Definition of done**:
```
Y/shared-lowering: 100%
Direct SAB fallback-removal: 100%
No-fallback sweep: 69/69 (local) + 69/69 (host)
所有宏展开和借用/优先级目标已完成
progress.md 和 tasks.md 已同步
已验证的 commits 已完成
```

---

## 4. Execution Order

Recommended execution order from the current state to 69/69:

```
1. Slice 2B — 纯宏收敛（关闭剩余宏展开缺口）
   ↓
2. Slice 3A — 调用/结果/赋值稳定化（3 个 Phase 3 失败）
   ↓
3. Slice 4A — Std 元数据批处理（3 个 Phase 4 失败）
   ↓
4. Slice 5A — 聚合/枚举/Derive/操作符批处理（4 个 Phase 5 失败）
   ↓
5. Slice 6A — 协议降低（2 个 Phase 6 失败）
   ↓
6. Slice 7A — 导入/包对等性
   ↓
7. Slice 8A — async 支持子集
   ↓
8. Slice 9A — 最终回退删除 → 69/69
```

---

## 5. Exit Criteria per Phase

| Phase | Y/shared | Fallback | Sweep | Notes |
|-------|----------|----------|-------|-------|
| Phase 1 | ~66% | ~85% | 50/64 | ✅ Completed |
| Phase 2 | ~76% | ~90% | 61/69 | 2A complete |
| Phase 3 | ~76% | ~90% | 61/69 | Call plan |
| Phase 4 | ~84% | ~94% | 64/69 | Metadata |
| Phase 5 | ~92% | ~96% | 68/69 | Aggregates/enums |
| Phase 6 | ~94% | ~98% | 69/69 | Protocols |
| Phase 7 | ~97% | ~99% | 69/69 | Imports |
| Phase 8 | ~97% | ~99.5% | 69/69 | async |
| Phase 9 | 100% | 100% | 69/69 | ✅ Final gate |

---

## 6. Key Technical Debt

### Embedded Local Branches

Although most semantics are shared, the following still exist in SAB-only branches and should be moved into shared rules:

- **Address/projection plan**: `genAddressOf` behavior for `&field`, `&index`, `&*smart`, `&**chain` is not yet fully shared
- **RefCell lifecycle**: borrow/borrow_mut handle release is partially duplicated in SAB

### Performance Bottlenecks

```
test_unit_vec_remove_direct.sla:
  direct SAB (带宏模板缓存):  257ms    ✅ 16x 加速
  direct SAB (无缓存):       4094ms   ❌ 瓶颈

parallel_table_erased.sla:
  SA-compatible flatten:      4.04s    ❌ 回退瓶颈
  SAB encode:                 5.22s    ❌ 最大单一瓶颈
  sa test:                   13.50s    ❌ SA 后端（宿主侧）
```

**Core contradiction**: the direct path (AST→SAB) is very fast (24-257ms), but encountering an unsupported feature takes the fallback path (flatten 4s + encode 5s). Eliminating the fallback means eliminating the bottleneck.

---

## 7. Related Document Index

| Document | Content |
|----------|---------|
| [`architecture_cn.md`](./architecture_cn.md) | Y-shaped architecture, shared frontend, lowering rules layer |
| [`std_surface_metadata_cn.md`](./std_surface_metadata_cn.md) | Std surface metadata format specification |
| [`testing_and_verification_cn.md`](./testing_and_verification_cn.md) | Test authoring, 9-step verification gates |
| `tasks.md` | Complete task tracking and failure ownership matrix |
| `progress.md` | Feature-increment progress records |
