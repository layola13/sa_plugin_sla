# Sla 编译器架构文档：Y 型设计与共享降低层

> **文档版本**：v0.1 / 2026-07-01
> **状态**：基于 `src/plugin.zig`、`src/lowering_rules.zig`、`sla_std/std_surface.sla_meta`、`src/sab_codegen.zig`、`src/codegen.zig` 实现
> **关联**：[`std_surface_metadata_cn.md`](./std_surface_metadata_cn.md)

---

## 1. 架构概述：Y 型管线

Sla 编译器采用 **Y 型架构**，这是一个关键的架构决策，保证了前端逻辑不被后端发射器重复。

```
                    .sla 源文件
                         │
                         ▼
             ┌───────────────────────┐
             │   共享前端 (Shared Front-end Trunk)    │
             │                       │
             │  read → source_expand │
             │  → parse → @import    │
             │  → test_filter →      │
             │  monomorphize →       │
             │  load_contracts →     │
             │  type_check →         │
             │  primary_decl_filter  │
             │                       │
             │  (runSlaFrontend)      │
             └───────────────────────┘
                         │
                         ▼
             ┌───────────────────────┐
             │  共享降低规则层 (Shared Lowering Rules)  │
             │                       │
             │  lowering_rules.zig:  │
             │  • StaticCallPlan      │
             │  • CallArgMaterializationPlan  │
             │  • ImportedMacroCallPlan      │
             │  • OptionClosureCallPlan      │
             │  • SmartPointer helpers       │
             │  • ABI layout rules           │
             │  • RefCellBorrowPlan          │
             │                       │
             │  sla_std/std_surface.sla_meta: │
             │  • 元数据驱动的 std surface     │
             │  • 不包含 Zig 编译器分支        │
             └───────────────────────┘
                      ╱    ╲
                     ╱      ╲
                    ▼        ▼
         ┌────────────┐  ┌────────────┐
         │ SA 文本发射器│  │ SAB 结构化 │
         │ (codegen.zig)│  │ 发射器     │
         │             │  │(sab_codegen│
         │ 输出 .sa    │  │ .zig)      │
         │ 文本文件    │  │            │
         │             │  │ 输出 .sab  │
         │             │  │ 二进制文件  │
         └────────────┘  └────────────┘
```

### 1.1 为什么是 Y 型？

| 问题 | 非 Y 型方案 | Y 型方案 |
|------|------------|---------|
| SA 文本和 SAB 有相同的 70% 管线 | 各写一份解析/类型检查 | `runSlaFrontend()` 共享 100% 前端 |
| 调用参数（auto-borrow、副本策略）在两个发射器中逻辑重复 | SAB 独自分支 | `CallArgMaterializationPlan` 统一描述 |
| std library 的 lowering 在两个后端不一致 | 各自 `if type == Vec` | `std_surface.sla_meta` 数据驱动 |
| 新语言特性只在 SAB 实现 | 特性不一致 | 共享规则层强制双后端实现 |

**核心原则**：不要只在 `sab_codegen.zig` 中实现高级语义。新的直接 SAB 工作必须扩展共享降低规则或 std surface metadata，然后让 SA 文本和 SAB 发射器通过共享契约汇合。

---

## 2. 共享前端 (`runSlaFrontend`)

`src/plugin.zig` 中的 `runSlaFrontend` 是 Y 型管线的共享主干：

```
runSlaFrontend(allocator, file, mono, tc, options, stderr, profile)
```

### 管线阶段及各阶段耗时特征

| 阶段 | 函数名 | 说明 | 典型耗时 |
|------|--------|------|---------|
| 源码读取 | `readFileAlloc` | 读取 .sla 源文件 | <10ms |
| 源码展开 | `source_expand.expand` | 展开 `@expand_tuple` 模板宏 | <5ms |
| 解析 | `Parser.initWithDir.parseProgram` | 词法/语法分析 | 10-100ms |
| @import 展开 | `expandSlaImports` | 递归展开 SLA @import 的 .sla 子模块 | 50-500ms |
| 测试过滤 | `pruneTestsByFilter` | 根据 `--filter` 剪枝 @test 声明 | <1ms |
| 单态化 | `monomorphize` | 泛型特化 | 10-200ms |
| 加载合约 | `loadImportedContracts` | 加载 `.sai`/`.sal` 合约 + 注册导入宏 | 20-200ms |
| 类型检查 | `checkProgram` | 类型安全检查 | 10-200ms |
| 主声明过滤 | `primary_decl_filter` | 只保留主声明（非 monomorphization 中间产物） | <1ms |

### 约束

- `mono` 和 `tc` 是调用者拥有的：调用者必须 `init`/`deinit`（并在其尾部代码生成期间保持它们存活，因为尾部代码会从其中读取信息）
- 新的前端阶段必须添加到 `runSlaFrontend`，而不是添加到单个尾部
- 所有阶段都受 `SLA_PROFILE` 环境变量的计时支持

---

## 3. 共享降低规则层 (`lowering_rules.zig`)

`src/lowering_rules.zig` 是 Y 型架构的**核心共享模块**。它包含两个发射器都消费的规则/计划，确保 SA 文本和 SAB 在语义上保持一致。

### 3.1 调用计划

#### `StaticCallPlan`
- `target_symbol: []const u8` — 解析后的函数符号
- `arg_count: usize` — 参数量
- `argPrefix(arg)` — 返回 `&`/`^`/null（借用/移动前缀）

由 `planStaticCall(tc, expr, call)` 和 `planResolvedStaticCall(tc, expr, call)` 构建。

#### `CallArgMaterializationPlan`
描述每个参数如何物化（materialize）：
```zig
pub const CallArgMaterializationKind = enum {
    array_to_slice_borrow,  // 数组到切片的隐式借用
    dyn_borrow,             // dyn trait 胖指针物化
    auto_borrow,            // 自动借用（接收者或参数）
    copy_struct_value,      // 结构体值拷贝
    value,                  // 普通值传递
};
```

每个计划都携带 `release_after_call: bool` 决定调用后是否需要释放。

由 `planCallArgMaterialization(arg, input)` 构建。

#### `ImportedMacroCallPlan`
描述导入的 SA `[MACRO]` 调用：
- `macro_name` — 宏名
- `import_path` — 导入路径
- `arity` — 总参数个数
- `leading_outputs` — 前导输出参数个数（如 `out`, `nonnull_ptr`）
- `expression_output` — 是否表达式输出（即宏可作为表达式使用）
- `borrowed_arg_mask` — 哪些参数被直接 `&%param` 借用
- `callArgNeedsAddressableSlot(index)` — 该参数是否需要可寻址栈槽

由 `planImportedMacroCall(tc, call)` 构建。

### 3.2 ABI 布局规则

所有布局规则共享，不匹配任意发射器：

```zig
pub fn abiTypeSize(ty) usize           // 类型大小
pub fn structAbiSize(decl) usize       // 结构体 ABI 大小
pub fn structFieldLayout(decl, name)   // 字段偏移/大小
pub fn tupleFieldLayout(tuple, index)  // 元组字段布局
pub fn arrayElementLayout(arr, index)  // 数组元素布局
pub fn inlineArrayStride(elem_ty)      // 内联数组步长（非指针槽）
```

**关键 ABI 规则**：结构体中的固定数组以指针大小（8 字节）槽位存储，而数组值本身保留内联元素布局。

### 3.3 智能指针类型识别

```zig
pub fn smartPointerType(ty) -> ?SmartPointerType  // 识别 Box/Rc/Arc/RefCell
pub fn boxInnerType(ty)     // Box<T> 的 T
pub fn rcInnerType(ty)      // Rc<T> 的 T
pub fn arcInnerType(ty)     // Arc<T> 的 T
pub fn refCellInnerType(ty) // RefCell<T> 的 T
pub fn smartPointerDerefType(ty) // 可解引用的智能指针
```

### 3.4 其他共享辅助函数

| 函数 | 目的 |
|------|------|
| `deriveNameMatches` / `structHasDerive` | Derive 名称比较 |
| `isVoidType` | 是否 void 类型 |
| `callArgPrefix` | 获取 `&`/`^` 前缀 |
| `prefixedIdentifierCallArg` | 提取带前缀的标识符参数 |
| `callArgNeedsRelease` / `exprResultNeedsRelease` | 是否需要释放 |
| `rootIdentifier` | 链式表达式的根标识符 |
| `assignmentMovesIdentifier` | 赋值是否触发移动 |
| `shouldAutoBorrowResolvedArg` / `shouldAutoBorrowReceiverArg` | 自动借用条件 |
| `planOptionClosureCall` | Option 闭包方法分类 |
| `planRefCellBorrowCall` | RefCell borrow/borrow_mut 分类 |
| `mangleMethodName` / `mangleTraitMethodName` | 方法名修饰 |
| `dynMethodSlot` / `vtableName` | VTable 布局 |
| `optionInnerType` | 提取 Option<T> 的 T |

---

## 4. 元数据驱动的 Std Surface

参见单独的 [`std_surface_metadata_cn.md`](./std_surface_metadata_cn.md) 文档。

**关键原则**：
- `sla_std/std_surface.sla_meta` 是数据，不是编译器逻辑
- SAB 后端通用地读取这些规则
- 任何标准库类型（Vec、Option、Result、Cell、Rc、Arc、Box、RefCell、Slice）的 lowering 都在元数据中定义，不在 Zig 分支中
- 新类型只需在 `.sla_meta` 中添加规则行，无需修改编译器

---

## 5. 两个发射器的差异

### SA 文本发射器 (`codegen.zig`)
- 将类型化/特化的 SLA AST 扁平化为 SA 汇编文本
- 输出 `.sa` 文件（可读、可调试）
- 逻辑较快但不妨作为 SAB 的临时备选路径

### SAB 结构化发射器 (`sab_codegen.zig`)
- 直接发射结构化 SAB 字节（二进制格式）
- 首先尝试直接 AST→SAB 快速路径
- 若直接路径不支持某个特性，回退到 SA 兼容路径：
  ```
  AST → codegen (SA text) → flattener → SAB encoder
  ```
  这被称为 **SA-compatible fallback**。

### 回退路径的触发条件

通过 `SLA_SAB_NO_FALLBACK=1` 环境变量禁用回退：
```bash
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_*.sla --test-backend sab
```

回退路径的**主要瓶颈**：
```
SA-compatible flatten: 4.04s
SAB encode:            5.22s
```
相比之下，直接路径只需 24-257ms。**消除回退是整个项目 100% Y 型完成的核心指标。**

---

## 6. 缓存架构

SAB 路径有三层缓存，都在单个编译实例内：

### 第一层：`sa_std` 根缓存
- 每个 SAB 编译实例缓存一次已解析的 `sa_std` 根路径
- 避免重复的文件系统根探测序列

### 第二层：已解码的 std import 模块缓存
- 来自相同 `sa_std` 导入路径的多个标准表面规则重用已解码的 SAB 模块
- 避免重复的 SCI flatten/encode/decode 序列

### 第三层：标识符宏模板缓存
- 参数都是标识符的宏片段（如 `Option::is_some`）
- 生成一次占位符模板 → 后续调用克隆已解码的结构化指令
- 直接参数（数值、类型名）仍然走普通路径

### 写入时缓存比较
```zig
fn writeSabFile(allocator, path, sab_bytes, stderr) -> bool
```
在写入 SAB 文件之前，比较字节内容：如果一致则跳过写入，以保持 SA 增量缓存稳定。

---

## 7. 托管缓存路径

SAB 托管工件位于 `.sla-cache/sab/`：

```
.sla-cache/sab/
├── {stem}-{source_hash}.sab           # 普通编译
├── {stem}-{source_hash}-{variant}.sab  # 测试（带变体）
└── ...
```

### 路径命名规则

| 场景 | 路径 | 键 |
|------|------|-----|
| 普通编译 | `{stem}-{Wyhash(file)}.sab` | 源文件路径 |
| 测试（全部） | `{stem}-{Wyhash(file + "test-all")}.sab` | 源文件路径 + 常量 |
| 测试（带过滤） | `{stem}-{Wyhash(file + "test-filter" + filter)}.sab` | 源文件路径 + 过滤字符串 |

### 缓存隔离

- 过滤后的测试构建使用过滤范围路径，不会覆盖普通构建/工作区 SAB 工件
- 用户可见的 SAB 文件仅在请求时写入：`--out`、`--sab-out` 或 `--emit-sab`

---

## 8. 完整的 CLI 管线图

### `sa sla build <file>`
```
read → source_expand → parse → @import → monomorphize → contracts → typecheck
  → rewriteImports → codegen.generate → .sa 文件
```

### `sa sla build-exe <file>`
```
read → source_expand → parse → @import → monomorphize → contracts → typecheck
  → {sab_codegen.generate → .sab} OR {SA-compatible fallback → .sab}
  → sa build-exe <sab>
```

### `sa sla test <file>`
```
read → source_expand → parse → @import → test_filter → monomorphize → contracts
  → typecheck → reachable-decl-filter
  → {sab_codegen.generate → .sla-cache/sab/...sab} OR {SA-compatible fallback}
  → sa test <sab>
```

---

## 9. 关键架构约束

1. **不要只在 `sab_codegen.zig` 中实现高级语义。** 新的直接 SAB 工作必须扩展共享降低规则或 std surface metadata。

2. **直接 SAB 必须保持直接。** 不要将 `.sla → .sa text → .sab` 作为普通路径实现。

3. **Y 型前端主干必须是唯一的真实来源。** 新的前端阶段放在 `runSlaFrontend` 中。

4. **元数据优先于编译器分支。** 使用 `sla_std/std_surface.sla_meta` 数据文件，而不是在 Zig 中添加 `if type == Vec/Rc/Set` 分支。

5. **无 `Vec`/`thread`/`ECS` 编译器分支。** 这些库语义属于标准库宏、元数据和表面规则。
