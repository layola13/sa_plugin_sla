# 目标条件声明：具体化（Materialization）规范

> 本文为英文原版 [Target-Conditional Declarations: Materialization Specification](./target_conditional_decls.md) 的中文对照版。

状态：规范性。来源：关于 wasm32 usize 的 C 上层裁决（2026-11-07）。该裁决确定了：当声明的 C ABI 宽度取决于编译目标时，应如何在 SLA 源码以及手写的 SA 标准库单元中书写这些声明，同时不赋予 SA 基座（语法、SAB 编码、解析器、检查器）任何条件语义。

## 1. 问题

有时，一个声明必须命名一种 C 类型，而其宽度是目标（target）的属性，而不是语言的属性。典型的例子是 libc 的 `size_t`：在原生目标上是 64 位，在 wasm32（wasi-libc）上是 32 位。单一的具体写法在其中一个目标上必然是错的——如果把 `mmap` 的 `len` 写成 `u64`，那么每个 wasm32 调用点都会在被调方接受 `i32` 的地方传入 `i64`，wasm 校验器会拒绝该模块。

解决办法是一种上层写法：源码为每个目标携带一个变体，并在任何后端看到它之前，由一个具体化步骤把源码缩减为编译目标所对应的那个具体变体。

## 2. 写法

条件块是一段连续的整行注释：

```
// @target-begin
// @target native
<native variant lines>
// @target wasm32
<wasm32 variant lines>
// @target-end
```

- `@target-begin` 开启一个块；`@target-end` 关闭它。块不可嵌套。
- 在块内，`// @target <name>` 开启目标 `<name>` 的区段。已定义的目标名恰好只有 `native` 和 `wasm32`。
- 标记行在去除首尾空白后被识别，且必须是整行。仅仅在行中间提到这些标记的普通注释不算标记。
- 块可以出现在任何注释可以出现的地方：extern 声明周围、调用点周围、常量周围——该机制是文本层面的，与层级无关。
- 在块内、任何区段之外，只能出现空行。

条件形式仅在存在上层处理器对其进行具体化的地方才是合法输入（SLA 前端、sa_std 汇编点）。直接针对单一目标编译的手写 `.sa` 文件使用该目标的具体写法，而不是条件形式。

## 3. 具体化语义

具体化是一个纯函数 `materialize(source, target) -> source`：

1. 任何块之外的行原样通过。
2. 在 `@target-end` 处，块中必须恰好出现过一个针对所请求目标的区段；该区段的行被输出，所有其它区段的行以及所有标记行都被丢弃。
3. 输出中不含任何标记：具体化之后的文本就是普通的 SLA/SA 源码。

选择必须是响亮的（loud），绝不回退。以下每一种情况都是硬错误：

| 条件 | 错误 |
|-------------------------------------------------------|--------------------------|
| 块中没有针对所请求目标的区段 | MissingTargetVariant |
| 同一目标区段在一个块中出现两次 | DuplicateTargetVariant |
| 区段命名了未知目标 | UnknownTargetName |
| 被选中的区段没有内容行 | EmptyTargetSection |
| 区段头出现在块之外 | TargetSectionOutsideBlock|
| 块内有非空内容但不在任何区段内 | ContentOutsideTargetSection|
| `@target-begin` 出现在块内 | NestedTargetBlock |
| 没有块就出现 `@target-end` | EndWithoutTargetBlock |
| 输入在块内结束 | UnterminatedTargetBlock |

不含标记的文件原样返回（identity 快速路径）；在一个原本没有标记的文件中出现的游离区段标记或结束标记，仍会进入状态机并按上述方式响亮地失败。

## 4. 具体化点

同一规范在且仅在以下上层点实现：

1. **SLA 前端**（`sa_plugin_sla`，`src/decl_materialize.zig`）：每个 SLA 源码（根文件以及每一个传递加载的模块）在导入展开和解析之前，都会以本次编译的声明目标进行具体化。`build-wasm` 以目标 `wasm32` 编译；所有其它命令使用 `native`。该目标参与编译新鲜度摘要（freshness digest），因此缓存产物绝不会跨目标泄漏。SA 基座永远看不到条件写法。
2. **sa_std 汇编**（`sci`，`tools/decl_materialize.zig`，在 `build.zig` 中接入）：带有条件块的、由 SA 实现的标准库单元，在宿主汇编器运行之前会针对归档（archive）的目标进行具体化。不含块的单元就地汇编。
3. **Rust SLA 实现**：必须实现同一规范，并通过下面的 golden 语料库，其条件声明支持才被视为合规。

## 5. 条件声明的编写规则

- 只有经过审查的 C 边界声明才使用条件形式。在所有目标上都确实是 64 位的值（协议字段、文件偏移、计数器）保持普通的 `u64` 声明；不要把它们条件化。
- 随目标变化的常量（例如编号因 libc 而异的系统调用标志字）与条件调用点行使用同一机制；绝不要通过无条件切换为某个目标的值来“修复”常量。
- 当已发布的签名保持宽类型（例如导出的 `(u64, u64)` 函数），而它调用的某个 extern 在某些目标上是窄类型时，内部调用点的转换要在该目标的区段中显式写出，并带有响亮失败（panic）的边界检查，绝不能静默截断。
- 任何工具都绝不会隐式收窄调用点。如果一次调用无法通过针对具体化后声明的类型检查，那么源码对该目标就是错的，必须在其自身的条件形式中说明。

## 6. Golden 语料库

`tests/decl_target/` 存放输入/期望配对；合规规则是：对每个目标，`materialize(input, target)` 与期望文件逐字节相等：

- `pair1_conditional.sla` 配 `pair1_conditional.native.expected` 与 `pair1_conditional.wasm32.expected` —— extern 宽度变体，外加一条携带目标标志常量的条件调用点行。
- `pair2_plain.sla` —— 无标记；对两个目标都是恒等（文件本身就是期望输出）。
- `neg1_missing_variant.sla` —— 针对 `wasm32` 的具体化必须以 MissingTargetVariant 失败；针对 `native` 则成功。
- `neg
...[truncated 615 chars]
