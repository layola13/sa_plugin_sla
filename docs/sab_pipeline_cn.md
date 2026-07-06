# SLA 直接输出 SAB 管线

## 目标

SAB 是 SA 的二进制 IR 文件格式，不是 `.sa` 文本压缩包，也不是把 `.sa` source 放进 section 的容器。本插件现在保留两条并行主线：

- `sa sla build`：继续输出 `.sa` 文本，服务调试和现有文本链路。
- `sa sla sab ...` / `sa slab ...`：从 SLA 前端直接输出 SAB bytes，供 SA compiler 读取 `.sab` 后进入 verifier/backend/linker。

禁止把 SAB 主线实现成 `sla -> sa text -> sab`。当前 `compileSlaFileToSab` 走的是：

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

该路径不调用 `compileSlaToSaString`、不写临时 `.sa` 文件，也不通过 SA text flattener 重新解析。

## 前置依赖与安装顺序

SAB 主线依赖 SA compiler 侧已经支持 `.sab` 输入。开发环境应先从 `sci` 仓库构建/安装 SA，再安装 SLA 插件：

```bash
cd /home/vscode/projects/sci
./tools/install.sh --no-shell

cd /home/vscode/projects/sa_plugins/sa_plugin_sla
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla
```

`sa build` / `sa build-exe` / `sa run` / `sa test` 在 SA 侧会识别 `.sab` 输入并跳过 `.sa` text flattener，直接把 SAB 解码后的结构化指令交给 verifier/backend。SLA 插件的 `build-exe` 和 `sab workspace` 都依赖这一点把 `.sla-cache/sab/...` 托管文件作为稳定输入交给 SA compiler。

安装后用以下命令确认加载的是 dev 插件和当前能力面：

```bash
SA_PLUGIN_DEV=1 sa plugin list
SA_PLUGIN_DEV=1 sa sla help
SA_PLUGIN_DEV=1 sa sla skills --json
```

`sa sla skills --json` 必须输出 JSON；如果输出文本，说明宿主没有把 JSON mode 转发给插件，或加载了旧插件/旧 SA 二进制。

## CLI 行为

### `sa sla init` / `sa sla skills`

```bash
sa sla init [path]
sa sla skills [--json]
```

- `init` 创建最小 SLA binary project：`sa.mod`、`src/main.sla`、`.gitignore`。
- `.gitignore` 默认包含 `.sla-cache/`，避免把托管 SAB 和后续增量缓存产物提交进仓库。
- `skills --json` 输出插件能力 JSON；文本模式会在当前目录生成 `.codex/skills/sla/SKILL.md` 和 `.claude/skills/sla/SKILL.md`。

### `sa sla sab build`

```bash
sa sla sab build [file] [-p <package>] [--out <file.sab>]
sa slab build [file] [-p <package>] [--out <file.sab>]
```

默认行为是托管缓存，不在源码旁生成用户可见 `.sab`：

```text
.sla-cache/sab/<stem>-<source-path-hash>.sab
```

这个路径稳定保留，用于后续增量编译复用。传 `--out` / `-o` 时，会额外写一份用户指定的 `.sab`，同时仍保留 `.sla-cache/sab/` 中的托管 SAB。

### `sa sla sab workspace`

```bash
sa sla sab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe-options...]
sa slab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe-options...]
```

workspace 模式从当前目录解析 `sa.mod`，选择默认 member 或 `-p/--package` 指定 member，直接生成托管 SAB 到 `.sla-cache/sab/`，再调用 `sa build-exe <managed.sab> ...`。

- 默认不在源码旁落 `.sab`。
- `--sab-out <file.sab>` 会额外写一份指定 SAB 文件。
- `--emit-sab` 会额外写 sibling `.sab`，用于人工检查。
- 传给 `sa build-exe` 的输入是稳定 `.sla-cache/sab/...` 路径，便于 SA 增量缓存命中。

`sa sla build-exe <file.sla>` 也走同一直接 SAB 托管路径：先生成 `.sla-cache/sab/...`，再调用 `sa build-exe <managed.sab> ...`。它不再生成临时 `.sa` 文本作为中间主链路。

### `sa sla test`

```bash
sa sla test [file] [-p <package>] [--test-backend auto|sab|sa] [sa-test-options...]
```

默认 `auto` 后端走 SAB 主线：SLA 前端生成 `.sla-cache/sab/...`，然后调用 `sa test <managed.sab> ...`。直接 AST-to-SAB 只是快速路径；如果它遇到尚未手写覆盖的 SLA 特性，例如函数指针间接调用，会改走内存 SA-compatible lowering，再通过 SCI flattener/SAB encoder 生成 SAB。输出仍然是 `.sab`，不会因为 direct fast path 不支持而回退到 `.test.sa`。SCI 的通用 SAB v4 encoder 覆盖 SA `InstKind` / `OpKind` / operand tag，并保留函数寄存器、native register、package identity、upstream location 等后端元数据；v4 不再保存每条 instruction 的完整 `.sa` raw_text。

- `--test-backend sab`：强制 SAB 主线；适合验证不会走旧 `.test.sa` 后端。
- `--test-backend sa`：强制旧 `.test.sa` 文本测试路径。
- `--emit-sab`：额外写 sibling `.sab` 供人工检查；托管 SAB 仍在 `.sla-cache/sab/`。

### `sa sla sab disasm`

```bash
sa sla sab disasm <file.sab> [--out <file.sa>]
sa slab disasm <file.sab> [--out <file.sa>]
```

反汇编只用于调试查看，不参与编译主链路。

## SAB v4 布局

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

当前 section：

- `1 symbol_pool`：符号名、函数名、label、短文本 token。指令流引用 symbol id。
- `2 function_sigs`：函数签名、参数能力、参数类型、返回类型、函数 kind、参数寄存器、函数寄存器集合。
- `3 const_decls`：常量声明和结构化 literal。
- `4 instructions`：指令 kind、source line、op kind、atomic metadata、operands。

不允许出现完整 `.sa` source section。v4 instruction payload 不写 raw instruction text；只保留必要的结构化 operand 和短操作数字符串，例如 call body operand、atomic expected/new operand、const literal text。`sab disasm` 是调试反汇编，不参与编译主链路。

## 当前支持子集

直接 SAB 后端当前覆盖：

- 函数和 `@test` 声明。
- `i*` / `u*` / `int` / `bool` / `void` / pointer/borrow 的基础类型映射。
- 参数、`let`、`return`、表达式语句。
- Phase 1 标量 `var`：`var x: T` 直接生成 `stack_alloc`，整体赋值生成 `store`，读取生成 `load`；支持当前 i32/bool 标量槽和分支合流后的读取。
- identifier 赋值和基础 `while` 循环。
- 整数和布尔 literal、identifier、二元算术/比较/位运算。
- 直接函数调用，使用 type checker 已解析符号，支持多参数普通调用。
- plain struct literal、field access、struct return 的通用布局 lowering。
- 语言级函数指针值与调用：命名函数/泛型特化作为 `fn(...) -> T` 值时生成结构化 vtable const，函数指针参数和局部变量调用直接生成 `load` + `call_indirect`。
- 普通闭包绑定和调用：`let f = |x| ...; f(arg)` 会在 direct SAB 中以内联闭包 body + 参数寄存器映射生成，支持捕获外层局部值和当前一/二参数闭包 smoke tests，不进入 fallback。
- 首批 std surface 元数据桥接：`sla_std/std_surface.sla_meta` 用数据描述关联函数、方法和索引糖如何展开为已导入 SA 宏片段，并按实际用到的依赖函数过滤合并 SAB module。`sab_codegen.zig` 只读取规则、解析导入、展开宏片段和合并结构化 SAB，不写死 `Vec`、`thread`、ECS 或业务库语义。
- `if/else` 到 `br` / label / `jmp` / merge 的基础控制流。
- chained `if let` / value-producing `if let`：通过共享 `planLetPattern()` 分类 Option/Result/user-enum tag 检查，SAB 只负责具体 `br` / label / result-slot merge / cleanup 发射；rosetta `104_if_let_chains` strict direct-SAB no-fallback 已通过。
- 普通 planned static call 的 `&[T; N] -> &[T]` array-to-slice borrow：共享 `CallArgMaterializationKind.array_to_slice_borrow` 负责语义分类，SAB 只负责 stack `Slice`/`SLICE_NEW` materialization 和临时 backing array cleanup；`tests/test_unit_array_to_slice_call.sla` local/host SA-text 与 strict direct-SAB no-fallback 已通过。
- `panic(code)`。
- 函数内 `reg_ids` 元数据和 void/test return 前的局部释放，满足 SA verifier 的作用域和泄漏检查。

当前目标是清零 fallback。未覆盖的 SLA 特性目前仍会显式返回 `UnsupportedSabDirectFeature`，旧路径随后走内存 SA-compatible SAB encoder；这只是过渡兼容，不是最终架构，也不能作为完成标准。后续必须通过通用 direct lowering 或通用 SAB macro/stdlib 表示移除这些缺口，不能在编译器里按 `Vec`、`thread`、ECS 或业务库名写死普通代码语义。

当前优先方向是继续扩大 std surface 元数据、可导出的闭包/function-object lowering、共享 lowering 规则/计划层和 SAB 宏表示，而不是把文本 codegen 中历史遗留的库分支复制到 `sab_codegen.zig`。目标形态是 `SLA AST/typecheck -> shared lowering rules/plan -> {SA text emitter, SAB structured emitter}`。编译器可以认识语言结构、类型信息、导入宏签名和 SAB 指令格式；普通库的名字、容器算法、线程 API、ECS 规则应留在 std / 插件 / 项目层。聚焦的 zero-arg `thread::spawn(^|| ...)` 捕获闭包、ordinary planned call array-to-slice borrow 和 `/home/vscode/projects/sla_ecs/lib/parallel.sla` no-fallback 路径已经通过；剩余工作是把入口函数/function-object lowering 泛化，并继续完善 result destination、remaining call materialization、macro 参数地址语义等共享计划层，而不是在 SAB 后端写 `thread` 或其它库专用分支。

排查 direct SAB 缺口时使用：

```bash
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test <file.sla> --test-backend sab --filter "..."
```

该开关会让 direct lowering 失败直接报错，而不是进入兼容 fallback。

## 验证记录

最近一次窄验证均避免全量测试：

- SCI 构建：`zig build -Doptimize=Debug`，通过；SAB focused Zig tests `zig test src/sab.zig --test-filter sab` 通过，覆盖 every SA `InstKind` / `OpKind` / operand tag 且 decoded instruction `raw_text` 为空。
- SCI 结构化后端回归：`zig test src/emit_llvm_llvmc.zig --test-filter "assignOperand resolves localized const vtable slots"` 通过，覆盖 v4 SAB 无 raw_text 时函数指针/vtable const 地址 lowering。
- SCI call/interp 回归：`zig test src/interp.zig --test-filter call` 通过，覆盖 structured `parseInstructionCall`。
- Direct 回归：`zig build test -Dtest-filter="sla sab backend lowers plain structs directly" --summary all`、`zig build test -Dtest-filter="sla sab backend lowers function pointers directly" --summary all`、`zig build test -Dtest-filter="sla sab backend lowers multi-argument calls directly" --summary all` 均通过，且这些测试使用 `allow_fallback = false`。
- Direct 函数指针 CLI 回归：`./zig-out/bin/sla-local-cli sla test tests/test_unit_fn_ptr_value.sla --filter "function pointer can be passed as argument" --test-backend sab --jobs 1 --trace-panic`、`--filter "generic function specialization can be passed as argument"`、`--filter "function pointer survives struct return"` 通过，profile 只出现 `sab direct codegen`。
- Direct std surface 回归：`zig build test -Dtest-filter="sla sab backend lowers imported std surface metadata directly" --summary all` 通过；`SLA_SAB_NO_FALLBACK=1 SLA_PROFILE=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_fn_ptr_value.sla --filter "function pointer survives vec push through function" --test-backend sab --jobs 1 --trace-panic` 通过，确认该用例没有走 fallback，且 decoded instructions 的 `raw_text` 为空。当前该路径 `sab direct codegen` 约 7.4s，瓶颈来自 std import/macro fragment 的完整 encode/decode/verify 合并；后续应在 SCI bridge 增加过滤后的 verified SAB fragment 接口，而不是回退到 raw text 或直接拼未经验证的 `FlattenResult`。
- Direct closure 回归：`zig build test -Dtest-filter="sla sab backend lowers closure calls directly" --summary all` 通过；`SLA_SAB_NO_FALLBACK=1 SLA_PROFILE=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_closures.sla --test-backend sab --jobs 1 --trace-panic` 通过，`sab direct codegen` 约 2-8ms。
- Direct var/control-flow 回归：`zig build test -Dtest-filter="sla sab backend lowers var scalar slots directly" --summary all` 通过；`SLA_SAB_NO_FALLBACK=1 SLA_PROFILE=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_var_phase1.sla --test-backend sab --jobs 1 --trace-panic` 通过，覆盖 scalar `var` stack slots、assignment、if branch merge 后读取和基础 while。该轮同时修复 direct SAB 分支条件 cleanup：临时条件在 then/else 或 loop body/exit 各自释放，局部/参数条件不被错误消费。
- Direct no-fallback 更新：`tests/test_unit_fn_ptr_value.sla --filter "thread closure captures function pointer callee"` 和 `/home/vscode/projects/sla_ecs/lib/parallel.sla` 已通过 no-fallback 验证。普通闭包调用、聚焦 zero-arg 逃逸线程闭包、捕获函数指针 callee 以及对应 spawn wrapper 已覆盖；剩余缺口是把该入口函数/function-object lowering 泛化到更多导出闭包形态，并把调用/实参 materialization 规则上移到共享 lowering 计划层，不能通过在编译器内写 `thread` 特例解决。
- SAB 端到端：`SA_PLUGIN_DEV=1 sa sla sab build tests/test_unit_fn_ptr_value.sla --out /tmp/test_unit_fn_ptr_value_v4.sab` 后，`/home/vscode/projects/sci/zig-out/bin/sa test /tmp/test_unit_fn_ptr_value_v4.sab --compile-only` 通过；`test_unit_spaceship_cmp.sla` 与 `test_unit_using_static_extension.sla` 同样通过。
- 性能点测：同一 `test_unit_fn_ptr_value`，`sa test <v4.sab> --compile-only` 约 3.31s-4.39s，raw `.sa` 路径约 11.31s；SA 后端吃 SAB 已明显加速。`sa sla sab build` 前端生成 SAB 仍比 `sa sla build` 慢，本轮测得约 3.66s vs 0.12s，剩余瓶颈在 SLA->SAB 生成阶段的 SA-compatible flatten/verify/encode 与缓存写入。
- 插件构建：`zig build`，通过。
- 默认托管 SAB：`timeout 120s ./zig-out/bin/sla-local-cli sla sab build tests/test_sab_direct.sla`，输出 `.sla-cache/sab/test_sab_direct-...sab`。
- 显式落盘：`timeout 120s ./zig-out/bin/sla-local-cli sla sab build tests/test_sab_direct.sla --out /tmp/sla_direct_out.sab`，`/tmp/sla_direct_out.sab` magic 为 `53 41 42 00`。
- workspace：`PATH=/home/vscode/projects/sci/zig-out/bin:$PATH timeout 120s .../sla-local-cli sla sab workspace --sab-out /tmp/sla_workspace_app.sab -o /tmp/sla_workspace_app`，生成 workspace `.sla-cache/sab/...sab`、`/tmp/sla_workspace_app.sab` 和可执行文件。
- 宿主 SA 安装验证：`/home/vscode/projects/sci/tools/install.sh --no-shell`，随后 `SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla`。
- 宿主插件能力验证：`SA_PLUGIN_DEV=1 sa sla help` 显示 `init` / `skills` / `sab workspace --sab-out`；`SA_PLUGIN_DEV=1 sa sla skills --json` 输出 JSON；`SA_PLUGIN_DEV=1 sa sla init /tmp/sa_host_sla_init` 生成 `sa.mod` 和 `src/main.sla`。
- 宿主 SAB 验证：`SA_PLUGIN_DEV=1 sa sla sab build tests/test_sab_direct.sla` 输出 `.sla-cache/sab/test_sab_direct-...sab`。
- 默认测试后端验证：`timeout 120s ./zig-out/bin/sla-local-cli sla test tests/test_sab_direct.sla --filter "direct sab add"` 通过；`timeout 120s ./zig-out/bin/sla-local-cli sla test tests/test_unit_fn_ptr_value.sla --filter "function pointer can be stored and called"` 通过并保留 SAB `call_indirect`。
- 已安装插件验证：`timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_sab_direct.sla --filter "direct sab add"` 通过；`timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_unit_fn_ptr_value.sla --filter "function pointer can be stored and called"` 通过。`sa plugin install --dev` 在本轮 5 分钟上限内无输出超时，因 manifest/lock 未变化，已用构建产物 `zig-out/lib/libsla.so` 更新 installed `current` 和 `0.1.0` 动态库，hash 已确认一致。
- ECS 性能验证：`timeout 120s env SA_PLUGIN_DEV=1 sa sla test /home/vscode/projects/sla_ecs/lib/parallel_table_erased.sla --filter "table erased readonly parallel runner executes no conflict systems on threads"` 通过，安装后约 19.30s、MaxRSS 约 153MB。本地 profile 显示 parse 0.62s、import expand 1.58s、SA-compatible flatten 4.04s、SAB encode 5.22s，单独 `sa test <managed.sab>` 约 13.50s；当前仍未达到 2-3s 目标，剩余瓶颈在 SAB fallback flatten/encode 和 SA 侧 test compile/link/incremental 行为。
- filtered Zig tests：
  - `timeout 120s zig test ... --test-filter "sla sab build defaults to managed sla cache"`
  - `timeout 120s zig test ... --test-filter "sla sab build emits direct SAB without SA source output"`
  - `timeout 120s zig build test -Dtest-filter="sla sab backend supports SA-compatible indirect call lowering"`
  - `timeout 120s zig build test -Dtest-filter="sla delegated SA commands default to jobs auto unless supplied"`
  - `timeout 120s zig build test -Dtest-filter="sla sab test managed path is scoped by test filter"`
  - `timeout 120s zig build test -Dtest-filter="sla test sab backend prunes unmatched tests before type checking"`

没有跑 `sci` 或插件全量测试；全量测试会造成不必要的 CPU/内存压力。
