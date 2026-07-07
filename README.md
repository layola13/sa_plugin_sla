# sa_plugin_sla

Safe ASM (SA) 的 Sla 编译器与工具插件。提供 Sla → SA 编译能力，并向宿主 SA 环境暴露一组 skill 和 CLI 命令。

## 状态

> 项目处于 1.0 之前的活跃开发阶段，**SAB 路径是主线**。
> 具体、可核实的进度指标（no-fallback sweep、Y 型共享 lowering 覆盖率、fallback 移除率）以
> [`docs/roadmap_status_cn.md`](docs/roadmap_status_cn.md) 为准，本 README 不硬编码这些百分比以免过期。

成熟度快照（2026-07-07 本地实测，非性能/兼容性保证）：

| 指标 | 结果 | 含义 |
|------|------|------|
| `sa sla check`（前端：词法/语法/类型检查） | 306/313 | demo 能被前端吃下的比例 |
| `sa sla build-exe`（端到端编译到原生可执行） | **239/313（约 76%）** | 真正落地成熟度指标 |

两者约 22 个百分点的差距，反映"前端能解析"与"后端 lowering 能落地"之间的缺口；失败按 Phase 的归属见 [`docs/roadmap_status_cn.md`](docs/roadmap_status_cn.md) §2。

已知局限（详见 [`docs/roadmap_status_cn.md`](docs/roadmap_status_cn.md) §2 剩余失败清单）：

- 部分语言特性（枚举 payload/match 提取、`derive`、`for in` 协议、`async/await`、集合类 std 元数据等）尚未进入 direct-SAB 快路径，命中时会走 SA 兼容回退路径。
- `demos/rosetta` 树是与 Rust 参考实现对照的样例集，**并非全部都能端到端通过**；请按需单独验证，不要假设整棵树已就绪。
- `&mut T` / `&mut self` 尚未引入（Phase 2 计划）；当前 `&self` 同时覆盖读写，由 SA Referee 兜底。

## 快速上手

前置：先构建并安装 SA（见下方 [Build](#build)），然后安装本插件（见 [Installation](#installation)）。之后：

```bash
SA_PLUGIN_DEV=1 sa sla init /tmp/sla_app          # 生成最小项目骨架
SA_PLUGIN_DEV=1 sa sla check /tmp/sla_app/src/main.sla   # 词法/语法/类型检查
SA_PLUGIN_DEV=1 sa sla build /tmp/sla_app/src/main.sla --out /tmp/main.sa   # 编译为 .sa
SA_PLUGIN_DEV=1 sa sla build-exe /tmp/sla_app/src/main.sla -o /tmp/main    # 编译为原生可执行文件
```

## 命令参考

- `sa sla init [path]`：创建最小 SLA 二进制项目，含 `sa.mod`、`src/main.sla`，并把 `.sla-cache/` 写入 `.gitignore`。
- `sa sla skills [--json]`：列出 SLA 插件能力。文本模式还会把 `.codex/skills/sla/SKILL.md` 和 `.claude/skills/sla/SKILL.md` 写入当前目录。
- `sa sla build <file>`：把一个 `.sla` 源文件编译为经校验的 `.sa` 汇编文件。
- `sa sla build-exe <file>`：走 direct SAB 路径把 `.sla` 编译为原生可执行文件，用 `.sla-cache/sab/...` 下的托管输入交给委派的 `sa build-exe`。
- `sa sla sab build <file>`：把 `.sla` 直接编译为 SAB 字节。默认托管产物写在 `.sla-cache/sab/`；用 `--out <file.sab>` 额外写出一个可见 SAB 文件。
- `sa sla sab workspace`：解析当前 `sa.mod` workspace 成员，走托管 SAB 编译，再委派给 `sa build-exe`。用 `-p <package>` 选择成员，`--sab-out <file.sab>` 额外写出检查用产物。
- `sa sla sab disasm <file.sab>`：反汇编 SAB 文件用于调试；不属于编译路径。
- `sa slab ...`：`sa sla sab ...` 的短别名。
- `sa sla check <file>`：对 `.sla` 源文件做词法、语法、类型检查，不发射最终 SA 汇编。
- `sa sla test <file>`：把 `.sla` 测试文件编译为 `.sla-cache/sab/` 下的托管 SAB 并经 `sa test` 运行。默认 `auto` 后端走 SAB 主线；仅在调试遗留 `.test.sa` 路径时用 `--test-backend sa`，或用 `--test-backend sab` 明确指定严格 SAB 模式。

更多可复制的调用示例见下方 [Installation](#installation) 与 [Rosetta Demos](#rosetta-demos)。

## Standard Library Imports

Sla 直接导入 SA 顶层 `sa_std` 包：

```sla
@import "sa_std/io/print.sai"
```

Sla 编译器在类型检查前加载导入的 `.sai` / `.sal` 契约，因此导入的 std 契约里的 extern 函数对 Sla 代码可用。默认从 `SA_STD_DIR`（已设置时）解析 `sa_std/...`，否则从 `$HOME/projects/sci/sa_std` 解析。

Sla 源码默认使用编译器托管的生命周期清理。用户面 `.sla` 代码不需要显式 `!x;` 释放；生成的 `.sa` 仍可能包含 `!` 指令，因为那是 SA 的所有权原语。Sla 有意不加 `drop` 关键字或 `drop()` 函数。

近期前端新增：丢弃绑定（`_`）、结构体更新 / 切片 rest 模式（`Struct { ..base }`、`[a, b, ..rest]`）、模块级 method-style 调用的显式 `using` 静态扩展、用于平坦数据布局的带 `&` 组合的 `type` 别名、以及限定在 `+ - * /` 的受限 `@overload` 块。这些特性完全在前端处理，lower 到既有 SA 形状，不引入运行时分发。

## 性能

SLA 编译性能的核心事实：**direct（AST→SAB）路径非常快，但命中未覆盖特性会掉到回退路径，回退才是瓶颈**。因此编译性能主要由 fallback 覆盖率决定，而非编译器稳态速度。

以下数字取自 [`docs/roadmap_status_cn.md`](docs/roadmap_status_cn.md) §6 与 [`docs/compilation_optimization_cn.md`](docs/compilation_optimization_cn.md)，均为单文件、特定 fixture 上的微观测量（机器未标定），**不作性能保证**：

| 路径 | 示例 | 耗时 | 备注 |
|------|------|------|------|
| Direct AST→SAB（热，带宏模板缓存） | `vec_remove_direct` | ~257 ms | 相对冷编译约 16× |
| Direct AST→SAB（冷，无缓存） | 同上 | ~4094 ms | 缓存未命中的代价 |
| SA 兼容 flatten（回退） | `parallel_table_erased` | ~4.04 s | 回退惩罚 |
| SAB encode（回退） | 同上 | ~5.22 s | 最大单一阶段 |
| `sa test` 后端（宿主侧） | 同上 | ~13.50 s | 下游，非本仓库范畴 |

大数组初始化优化（`.repeat` + `@memset`，详见 [`docs/compilation_optimization_cn.md`](docs/compilation_optimization_cn.md)）把 `lvm.test.sa` 干净重构从 **>5 分钟缩短到 ~4.6 s**，`lparser.test.sa` 到 **~6.6 s**，消除了单测/增量编译卡死。

本仓库自带 benchmark harness（见 [`docs/benchmarking_cn.md`](docs/benchmarking_cn.md)），定义了 `sla_to_sab_cold` / `sla_to_sab_warm` / `sla_to_native` / fallback-allowed / no-fallback 等基准项：

```sh
tools/bench_sla_pipeline.sh --runs 3 --out /tmp/sla_pipeline_bench.jsonl
```

托管 SAB 产物住在 `.sla-cache/sab/`；未变化的 SAB 字节不会重写，以便 SA 增量缓存复用稳定输入（该行为已描述，尚未单独 benchmark）。

## 工作原理（简述）

`.sa` 与 `.sab` 是两条独立的用户面编译主线，但内部正在收敛为 Y 型契约：

```
SLA AST/typecheck ── 共享 lowering 规则/plan ──┬── SA 文本 emitter
                                              └── SAB 结构化 emitter
```

SAB 生成把 SAB 字节直接写到托管产物路径，不创建 `.test.sa`、也不调用遗留文本测试后端，除非显式 `--test-backend sa`。SAB 路径先尝试 direct AST→SAB 快路径；对尚未覆盖的 SA 指令族与 SLA 特性，SAB 暂时经 in-memory SA 兼容 lowering + SCI flattener/SAB encoder 作为兼容路径。

架构与快路径覆盖范围的完整说明见：

- [`docs/architecture_cn.md`](docs/architecture_cn.md) — Y 型架构、共享前端主干、lowering 规则、emitter 设计
- [`docs/sab_pipeline_cn.md`](docs/sab_pipeline_cn.md) — SAB 快路径已覆盖特性清单、SAB 二进制格式、回退边界

## Build

本插件依赖来自 `sci` 的 SA 编译器/运行时。先构建并安装 SA：

```bash
git clone https://github.com/layola13/sci.git
cd sci
./tools/install.sh --no-shell
```

对于像 `/home/vscode/projects/sci` 这样与本插件并列的本地 checkout，在 SAB 相关改动后要先重建 SA 再重装插件。当前 SAB 测试/构建支持依赖 SCI 的 SAB v4 解码器保留结构化指令操作数与后端元数据（函数寄存器 id、原生寄存器名、包身份、上游位置）。SAB v4 不保留逐指令原始 `.sa` 文本：

```bash
/home/vscode/projects/sci/tools/install.sh --no-shell
```

然后构建 Sla 编译器插件：

```bash
zig build
```

产出插件清单与动态库：

- `zig-out/lib/sap.json`
- `zig-out/lib/libsla.so`

## Installation

构建后用包管理器把插件注册进 SA 环境：

```bash
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla
```

用 `SA_PLUGIN_DEV=1` 运行 dev-plugin 命令，例如：

```bash
SA_PLUGIN_DEV=1 sa sla init /tmp/sla_app
SA_PLUGIN_DEV=1 sa sla skills --json
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/13_array_sum/main.sla --out /tmp/13_array_sum.sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/rosetta/13_array_sum/main.sla -o /tmp/13_array_sum
SA_PLUGIN_DEV=1 sa sla sab build tests/test_sab_direct.sla
SA_PLUGIN_DEV=1 sa sla sab build tests/test_sab_direct.sla --out /tmp/test_sab_direct.sab
SA_PLUGIN_DEV=1 sa sla sab workspace --sab-out /tmp/workspace.sab -o /tmp/workspace_app
SA_PLUGIN_DEV=1 sa sla check tests/test_unit_basic.sla
SA_PLUGIN_DEV=1 sa sla build tests/test_unit_basic.sla --out /tmp/test_unit_basic.sa
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_basic.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_basic.sla --test-backend sa
```

托管 SAB 产物住在 `.sla-cache/sab/`；过滤测试构建用 filter-scoped 路径，不覆盖普通 build/workspace 的 SAB 产物。用户可见 SAB 文件仅在 `--out` / `--sab-out` / `--emit-sab` 请求时写出。委派的 `sa test` / `sa build-exe` 默认 `--jobs auto`，除非用户显式提供 `--jobs`。

## Rosetta Demos

`demos/rosetta` 树镜像 `/home/vscode/projects/sci/demos/rosetta` 下的 Rust 参考实现，附带 Sla 对照与每个 demo 的 Rust/Sla 比较笔记。这些 demo 意在**人工核对语义等价**，而不仅仅是比对最终输出。注意并非整棵树都已端到端通过（见 [状态](#状态)）。

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/01_hello_world/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/01_hello_world/main.sla --out /tmp/01_hello_world.sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/rosetta/01_hello_world/main.sla -o /tmp/01_hello_world
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/01_hello_world/main.sla
```

## 文档

| 文档 | 说明 |
|------|------|
| [`docs/architecture_cn.md`](docs/architecture_cn.md) | Y 型编译器架构、共享前端主干、lowering 规则、emitter 设计 |
| [`docs/sab_pipeline_cn.md`](docs/sab_pipeline_cn.md) | SAB 快路径覆盖清单、二进制格式、回退边界 |
| [`docs/roadmap_status_cn.md`](docs/roadmap_status_cn.md) | 当前完成进度、Phase 1-9 路线图、剩余失败归属 |
| [`docs/compilation_optimization_cn.md`](docs/compilation_optimization_cn.md) | 编译优化策略与实测数字 |
| [`docs/benchmarking_cn.md`](docs/benchmarking_cn.md) | Benchmark harness 与下游 hook |
| [`docs/testing_and_verification_cn.md`](docs/testing_and_verification_cn.md) | 测试编写、no-fallback 测试、9 步验证门禁 |
| [`docs/std_surface_metadata_cn.md`](docs/std_surface_metadata_cn.md) | `std_surface.sla_meta` 格式规范与规则参考 |
| [`docs/stability_metadata_cn.md`](docs/stability_metadata_cn.md) | 稳定性元数据 |
| [`docs/mutability_decision_cn.md`](docs/mutability_decision_cn.md) | 可变性设计决策（`let mut`、`&mut T` Phase 1/2） |
| [`docs/operator_overload_decision_cn.md`](docs/operator_overload_decision_cn.md) | 操作符重载设计（`@overload` 块、`@derive(Add/...)` 路线） |
| [`docs/sla_language_specification_cn.md`](docs/sla_language_specification_cn.md) | 完整 Sla 语言规范 |
| [`docs/macro_vs_rust_cn.md`](docs/macro_vs_rust_cn.md) | 宏系统对比：Sla vs Rust |
| [`docs/rust_vs_sla_final_cn.md`](docs/rust_vs_sla_final_cn.md) | Rust vs Sla 综合对比（已核实） |
| [`docs/rust_surface_compat_report_cn.md`](docs/rust_surface_compat_report_cn.md) | Sla → Rust 表层兼容性评估报告（2026-06-15 快照） |
| [`docs/bevy_syntax_gap_analysis_cn.md`](docs/bevy_syntax_gap_analysis_cn.md) | Bevy ECS 语法差距分析 |
| [`docs/faq.md`](docs/faq.md) | SA/Sla 设计 FAQ（`^`/`!`/Trait/Drop 等决策依据） |
| [`docs/tutor/01_intro.md`](docs/tutor/01_intro.md) … [`07_builtin_api.md`](docs/tutor/07_builtin_api.md) | 教程系列 |
