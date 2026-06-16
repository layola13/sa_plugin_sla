# sa_plugin_sla

Sla compiler and tools plugin for Safe ASM (SA).

## Overview
This is the standalone Sla compiler plugin, providing Sla-to-SA compilation capabilities. It exposes the following skills and CLI commands to the host SA environment:
- `sa sla build <file>`: Compile a `.sla` source file into a verified `.sa` assembly file.
- `sa sla check <file>`: Lex, parse, and type-check a `.sla` source file without emitting final SA assembly.
- `sa sla test <file>`: Compile a `.sla` test file and run it through `sa test`.

Sla source uses compiler-managed lifetime cleanup by default. User-facing `.sla` code should not need explicit `!x;` releases; generated `.sa` may still contain `!` instructions because that is SA's ownership primitive. Sla intentionally does not add a `drop` keyword or `drop()` function.

## Standard Library Imports
Sla imports SA's top-level `sa_std` package directly:

```sla
@import "sa_std/io/print.sai"
```

The Sla compiler loads imported `.sai` and `.sal` contracts before type checking, so extern functions from imported std contracts are available to Sla code. By default it resolves `sa_std/...` from `SA_STD_DIR` when set, then from `$HOME/projects/sci/sa_std`.

## Build
To build the Sla compiler plugin:
```bash
zig build
```
This produces the plugin manifest and dynamic library:
- `zig-out/lib/sap.json`
- `zig-out/lib/libsla.so`

## Installation
Once built, the plugin can be registered into the SA environment using the package manager:
```bash
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla
```

Run dev-plugin commands with `SA_PLUGIN_DEV=1`, for example:
```bash
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/13_array_sum/main.sla --out /tmp/13_array_sum.sa
SA_PLUGIN_DEV=1 sa sla check tests/test_unit_basic.sla
SA_PLUGIN_DEV=1 sa sla build tests/test_unit_basic.sla --out /tmp/test_unit_basic.sa
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_basic.sla
```

## Rosetta Demos
The `demos/rosetta` tree mirrors the Rust references under `/home/vscode/projects/sci/demos/rosetta` with Sla companions and per-demo Rust/Sla comparison notes. The demos are intended to be checked manually for semantic equivalence, not only for matching final output.

Typical commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/01_hello_world/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/01_hello_world/main.sla --out /tmp/01_hello_world.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/01_hello_world/main.sla
```

---

# Sla → Rust 表层兼容性评估报告

> 评估日期：2026-06-15
> 目标：在不动摇 SA 五符号契约（`= & ^ ! *`）和 Referee O(1) 位掩码验证模型的前提下，让 Sla 表面语法尽可能接近 Rust。

## 一、关键认知校正

**两条红线对应 SA 设计原则**

| 红线 | 对应原则 |
|------|----------|
| 不放弃 `^` | "五符号契约"（design.md §1.3）+ 仿射状态机的核心物理输入 |
| 不引入 `mut` | FAQ §所有权与借用类："共享读 vs 独占写由 Referee 在运行时上下文动态决定，**不在语法层区分**" |

第二条尤其关键 —— **Referee 已经在 `&` 一种语法下自动区分 `Locked_Read` / `Locked_Mut`**，看的是借用视图后面有没有 `store`。Rust 的 `&mut` 完全是冗余声明，引入它反而违背了"少一个前缀 = LLM 出错率更低"。

**第二个关键洞察：`^` 与 Rust 的 `^` 其实没有真正冲突**
- Sla `^x`：**前缀**一元 = Move（`let y = ^x`）
- Rust `a ^ b`：**中缀**二元 = XOR

这两个位置在 parser 里是不同上下文，可以共存。

## 二、重新定位目标："Rust 表层兼容子集"

正确的目标不是"让 Sla 变成 Rust"，而是：

> **让大量 Rust 代码能在 Sla 中原样解析通过，编译器在 lowering 期把 Rust 表面的冗余声明（lifetime/pub/where）静默吸收成 SA 的隐式行为。**
>
> **关于可变性（v0.2 修订）**：Phase 1 当前阶段不引入任何 `mut` 写法；Sla 的 `&self` 当前约定**同时覆盖 Rust 的 `&self` 与 `&mut self`**，由 SA Referee 在 lowering 后兜底（实测 `demos/rosetta/59_method_counter` 等已验证）。`&mut T` 与 `&mut self` 留到 sa3d ECS Phase 6A 启动前（Phase 2）引入；`let mut` 永久不引入（与 sla `let = 可变` 现状冲突）。详见 [`docs/mutability_decision_cn.md`](docs/mutability_decision_cn.md)。

这样 LLM/人类可以直接粘贴 Rust 风格代码，Sla 编译器扮演"翻译器+智能筛选器"的角色，保留 SA 的全部安全约束。

## 三、推荐策略：「Rust 风格 in，SA 语义 out」

### A. 静默吸收型（解析但语义置空，零认知负担）

| Rust 语法 | Sla 解析后处理 | 理由 |
|-----------|---------------|------|
| `let mut x = ...` | **永久不接受**（sla `let` 已默认可变，`mut` 反而沉默误导） | Sla 与 Rust 默认可变性反向，详见 [`docs/mutability_decision_cn.md`](docs/mutability_decision_cn.md) |
| `&mut T` 借用类型 | **Phase 1 不引入**；Phase 2 (sa3d ECS 之前) 引入 | 当前 `&T` 涵盖读写；触发条件见 [`docs/mutability_decision_cn.md`](docs/mutability_decision_cn.md) §2.2 |
| `fn foo(&mut self)` | **Phase 1**：当前未识别（需手工去 mut）；**Phase 2**：作为独立独占借用契约引入 | 同上 |
| `'a` / `'static` lifetime | 解析但不落到语义 | SA 不做跨函数借用图（FAQ 明示） |
| `pub` / `pub(crate)` | 解析丢弃 | SA 默认全部链接器可见（FAQ 明示） |
| `unsafe { ... }` / `unsafe fn` | 解析丢弃；如涉及裸指针，要求被包在 `@ffi_wrapper` 内 | SA 用 `@ffi_wrapper` 函数级隔离替代块级 unsafe |
| `where T: Bound` | 解析；约束只在单态化时做 trait 方法查找用 | 不引入约束求解 |
| `#[derive(...)]` / `#[inline]` | 映射到现有 `@`/`inline` | 同语义换皮 |

这部分对 SA 设计零侵入 —— 纯前端语法 ingestion。

### B. 直接同义映射（Rust 写法 ↔ Sla/SA 既有概念）

| Rust | Sla | 说明 |
|------|-----|------|
| `use std::foo::bar` | `@import "sa_std/foo/bar.sai"` | 双轨接受，文档推 Rust 风 |
| `extern "C" fn ...` | `@extern fn ...` | 双轨 |
| `#[test]` | `@test` | 双轨 |
| `println("...")` / `print(...)` | **当前实现：无 `!` 后缀**，直接当普通函数调用，桥到 sa_std 的 `print` 路径 | Sla 已有 `println`，**短期内不引入 `!` 宏调用语法**（见下方"`!` 决议"） |
| `format(...)` / `vec(...)` / `panic(code)` / `assert(...)` | 同上，短期内全部当函数 / 内建 intrinsic 处理 | 不发射 macro-suffix `!` |
| `i8..i64 / u8..u64 / f32 / f64 / usize / isize` | 加入类型表 | `int` 保留作 `i64` 别名 |
| `bool` / `true` / `false` | 已有 / 加 | |
| `as` 强制转换 | 加 | 与 `.sa` 的 `as` 一致 |
| `+= -= *= /= %= &= \|= ^= <<= >>=` | 加复合赋值 | desugar 成 `x = x op y` |
| `&& \|\| ! << >> \| ~`（位运算 `\|`/`~`） | 加 | 注意 `!` 仍是逻辑非，`^` 中缀=XOR |
| `loop / break / continue / 'label:` | 加（FAQ 已说 SA 不内建，但 Sla 前端要支持，降到 `jmp/br`） | 与 `for/while` 同一套展平器 |
| `if let` / `while let` / `let else` | 加，desugar 到 `match` | |
| `match` 多枝 `\|`、守卫 `if`、`@` 绑定、`..=` 范围、`..` 通配 | 扩展现有 match | |
| `impl Trait for T` + `trait` | 加，**只做单态化静态分发**（FAQ §"为什么没有 Trait"已论证只支持静态分发 + vtable 宏） | 不做 trait coherence、不做 GAT |
| `Self / self / &self` | 已可用；UFCS 已有，自然到位 | 当前 `&self` 同时覆盖 Rust `&self` 与 `&mut self`（读写均允许，SA Referee 兜底）；`&mut self` 在 Phase 2 引入 |
| `enum Variant { A, B(T), C{x:int} }` | 加，sum-type；match 解构按 `[tag\|payload]` lowering（设计文档已 sketch） | |
| 字符字面量 `'a'` | 加，与 lifetime `'a` 用 lexer lookahead 区分 | |
| 数字字面量后缀 `1u32 / 1.5f64` | 加 | |
| 字符串字面量 → `&str` / `String` | 加，需要在 sa_std 给出胖指针布局 | |

### C. 重要的"看似 Rust 实则 Sla"的语义差异（必须文档明示）

| 表面 | 实际语义 | 给开发者的承诺 |
|------|---------|---------------|
| `let mut x` | **永久不接受**（sla `let` 已默认可变） | Sla 与 Rust 默认可变性反向；详见 [`docs/mutability_decision_cn.md`](docs/mutability_decision_cn.md) |
| `&T` | **当前涵盖读写两种用途**（sla 约定）；Phase 2 引入 `&mut T` 后区分 | lowered 始终为 SA `&`；Referee 物理层不变 |
| `Drop` trait | **不支持**（FAQ §显式优于隐式） | 仍由编译器隐式注入 `!`；用户**不能**写 `impl Drop` |
| `'a` 标注 | 仅解析 | 跨函数借用安全由前端责任制，不做检查 |
| `unsafe` 块 | 退化为"声明意图"；真正的指针下行仍只允许 `@ffi_wrapper` 函数级 | 块级 `unsafe { *raw }` → 编译期要求外层函数标 `@ffi_wrapper` 或报错 |
| `panic!()` | `panic(code)`（数值码） | 字符串变体经 sa_std 走 `panic_msg` |
| `Send/Sync` | 解析；语义由 Referee 的 affine mask + 跨核校验（design.md §1.4#5）兜底 | 不暴露 trait 求解 |

### D. 拒绝引入（守住 SA 哲学）

- `let mut x` 写法（永久；与 sla `let = 可变` 现状冲突）
- ~~`&mut` 作为独立类型~~ **修正（v0.2）**：Phase 2 sa3d ECS 启动前**会引入** `&mut T` / `&mut self`，用于 ECS 调度器静态 read/write 集；详见 [`docs/mutability_decision_cn.md`](docs/mutability_decision_cn.md)
- `Drop` trait
- 隐式 GC / unwind / panic catch
- 完整 NLL/Polonius lifetime
- proc-macro / `macro_rules!` 任意复杂展开（保留 Sla 的 `macro` 卫生宏；`println!` 等 hard-coded）

## 四、`^` 与 `!` 在 Rust 兼容下的精确 parser 规则

**`^` 双语义分流（关键，建议写进 parser 测试）**

```
prefix  '^' expr          → Move (Sla 既有)
expr '^' expr             → XOR (Rust 风)
'^' 出现在 type 位置       → 非法
```

判别法：`^` token 出现时，看左侧是否有可作为操作数的表达式结尾（identifier/literal/`)`/`]`）。有 → 中缀 XOR；没有 → 前缀 Move。

**`!` 决议（短期立场）**

```
prefix '!' expr           → 逻辑非（唯一接受语义）
ident '!' (...)           → 短期内不引入。理由：与 SA 的 ! 释放原语在 lexer / 视觉上都易混淆，
                            等 SA 侧 !reg 完全收敛到编译器隐式注入、用户 .sla 中物理消除
                            "!" 出现位置之后，再评估是否打开此入口。
单独 '!' 后跟寄存器        → 仍是 SA 的释放原语，但 .sla 用户层禁止显式书写
                            （仅生成的 .sa 与 @debug 模式可见）
```

**关键澄清**：
- Sla 已经有 `println` 作为普通函数 / 内建调用，无需 `!` 后缀。
- 这是"短期不引入"，不是"永远不引入"。当 SA 侧的 `!` 已彻底从 `.sla` 用户面消失、
  视觉冲突风险消除后，可重新评估 Rust 风格的 `println!` / `vec!` / `assert!` 宏入口。
- 在此期间，Rust 源码里的 `println!("...")` 在 Sla parser 接受时建议**容错降级**：
  把紧贴标识符的 `!` 当成"语法噪音"剥离，重写为 `println("...")` 后继续解析，
  这样能保持"Rust 表层兼容子集"的承诺，又不污染 Sla 自己的 `!` 语义。

这套规则不动 SA 任何东西，是纯 Sla 前端 parser 的职责。

## 五、修订后的路线图（按 ROI）

**Phase 1 — 词法/类型表扩容（1 周）**
1. 新增 token：`&&` `||` `<<` `>>` `|` `~` `+=` 系列 `..=` `'` `#` `_`
2. 类型表加 `i8/i16/i32/i64/u8/u16/u32/u64/usize/isize/f32/f64/str`，`int`=`i64` 别名
3. 字面量：`true/false/0x/0o/0b`、字符 `'a'`、字面量后缀
4. `^` 精确双语义、`!` 三语义 parser

**Phase 2 — 静默吸收型语法（1 周）**
- 解析 `mut/pub/'a/where/unsafe/#[...]`，全部丢弃或同义重写到 `@` 语法
- `use` / `mod` 与 `@import` 双轨

**Phase 3 — 控制流补齐（1 周）**
- `loop` / `break` / `continue` / labeled break / `as` / 复合赋值 / `if let` / `while let` / `let else`

**Phase 4 — match 扩展 + 真正的 enum（2 周）**
- 多枝 `|`、守卫 `if`、`@` 绑定、范围 `..=`、`..` 通配
- 带 payload 的 sum-type enum，按 SA 的 tagged union 布局（design.md §1.4#2）lowering

**Phase 5 — trait 静态分发（2 周）**
- `trait` + `impl Trait for T`
- 仅生成单态化函数 + vtable 宏；对照 FAQ §动态分发的 `DISPATCH` 宏

**Phase 6 — 标准库表面**
- `println` / `print` / `format` / `panic` / `assert` 作为**无 `!` 后缀**的函数/内建 intrinsic 桥到 sa_std 现有宏（与 Sla 已实现的 `println` 路径一致）
- Rust 源码里的 `println!(...)` 由 parser 容错剥 `!` 重写为 `println(...)`
- `Vec/Box/Rc/Arc/Option/Result/String/&str` 走 `@extern` + `.sal` 桥接，命名对齐 Rust
- 待 SA 侧 `!` 在 `.sla` 用户层完全隐形后，再评估是否打开 Rust 风 `!` 宏调用入口

## 六、能达到的"Rust 兼容度"重新校准

务实目标：
- **Phase 1（当前）**：Rust 表层 ≈ **70%**（`let mut x` / `&mut T` / `&mut self` 都需手工去 mut，约定 `&self` 涵盖读写）
- **Phase 2（sa3d ECS 启动前）**：Rust 表层 ≈ **85%**（引入 `&mut T` / `&mut self`；`let mut` 永久不引入）
- 语义 ≈ Rust safe 单线程子集 - Drop trait - 完整生命周期 - proc-macro

差异留给文档一页说清：
1. **可变性反向 + 当前 `&self` 涵盖读写**：Sla `let` 默认可变（Rust `let` 默认不可变）；`let mut` 永久不引入；当前 `&self` 同时覆盖 Rust `&self/&mut self`，由 SA Referee 兜底；Phase 2 sa3d ECS 启动前引入 `&mut T` / `&mut self`。详见 [`docs/mutability_decision_cn.md`](docs/mutability_decision_cn.md)
2. `Drop` 由编译器代劳
3. lifetime 只是注释
4. `unsafe` 收敛到函数级

LLM 写代码时几乎察觉不到边界 —— 它生成 Rust 风格，Sla 静默吸收，SA 拿到的是干净扁平的所有权指令流。
