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

默认 `auto` 后端走 SAB 主线：SLA 前端生成 `.sla-cache/sab/...`，然后调用 `sa test <managed.sab> ...`。直接 AST-to-SAB 只是快速路径；如果它遇到尚未手写覆盖的 SLA 特性，例如函数指针间接调用，会改走内存 SA-compatible lowering，再通过 SCI flattener/SAB encoder 生成 SAB。输出仍然是 `.sab`，不会因为 direct fast path 不支持而回退到 `.test.sa`。SCI 的通用 SAB encoder 覆盖 SA `InstKind` / `OpKind` / operand tag 并保留 raw_text、函数寄存器、native register、package identity、upstream location 等后端元数据。

- `--test-backend sab`：强制 SAB 主线；适合验证不会走旧 `.test.sa` 后端。
- `--test-backend sa`：强制旧 `.test.sa` 文本测试路径。
- `--emit-sab`：额外写 sibling `.sab` 供人工检查；托管 SAB 仍在 `.sla-cache/sab/`。

### `sa sla sab disasm`

```bash
sa sla sab disasm <file.sab> [--out <file.sa>]
sa slab disasm <file.sab> [--out <file.sa>]
```

反汇编只用于调试查看，不参与编译主链路。

## SAB v3 布局

```text
magic:          4 bytes = "SAB\0"
version_major:  u8 = 3
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

不允许出现完整 `.sa` source section。兼容字段里只保留 SA compiler 目前仍需要解析的短操作数字符串，例如 call operand，不保存整行 SA 源码。

## 当前支持子集

直接 SAB 后端当前覆盖：

- 函数和 `@test` 声明。
- `i*` / `u*` / `int` / `bool` / `void` / pointer/borrow 的基础类型映射。
- 参数、`let`、`return`、表达式语句。
- 整数和布尔 literal、identifier、二元算术/比较/位运算。
- 最多两个参数的直接函数调用。
- `if/else` 到 `br` / label / `jmp` / merge 的基础控制流。
- `panic(code)`。
- 函数内 `reg_ids` 元数据和 void/test return 前的局部释放，满足 SA verifier 的作用域和泄漏检查。

未覆盖的 SLA 特性会显式返回 `UnsupportedSabDirectFeature` 给上层 SAB 主线，上层随后走内存 SA-compatible SAB encoder。这个 fallback 不是 `sla -> sa -> sab` 用户主线，也不会生成 `.test.sa`；它只是把现有 SA-compatible lowering 作为内存 IR 交给 SCI 的 SAB encoder，保证 SAB 覆盖所有 SA 指令族和 operand 形态。函数指针值/`call_indirect` 当前也走这条完整 SAB encoder 路径。

## 验证记录

最近一次窄验证均避免全量测试：

- SCI 构建：`zig build`，通过；SAB focused Zig tests `sab roundtrip covers every SA instruction and op kind`、`sab roundtrip covers every SA operand kind` 通过。
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
