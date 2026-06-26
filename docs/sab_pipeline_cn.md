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

## CLI 行为

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

### `sa sla sab disasm`

```bash
sa sla sab disasm <file.sab> [--out <file.sa>]
sa slab disasm <file.sab> [--out <file.sa>]
```

反汇编只用于调试查看，不参与编译主链路。

## SAB v1 布局

```text
magic:          4 bytes = "SAB\0"
version_major:  u8 = 1
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

未覆盖的 SLA 特性会显式返回 `UnsupportedSabDirectFeature`，而不是偷偷回退到 `.sa` 文本链路。

## 验证记录

最近一次窄验证均避免全量测试：

- 构建：`zig build --summary all`，通过。
- 默认托管 SAB：`timeout 120s ./zig-out/bin/sla-local-cli sla sab build tests/test_sab_direct.sla`，输出 `.sla-cache/sab/test_sab_direct-...sab`。
- 显式落盘：`timeout 120s ./zig-out/bin/sla-local-cli sla sab build tests/test_sab_direct.sla --out /tmp/sla_direct_out.sab`，`/tmp/sla_direct_out.sab` magic 为 `53 41 42 00`。
- workspace：`PATH=/home/vscode/projects/sci/zig-out/bin:$PATH timeout 120s .../sla-local-cli sla sab workspace --sab-out /tmp/sla_workspace_app.sab -o /tmp/sla_workspace_app`，生成 workspace `.sla-cache/sab/...sab`、`/tmp/sla_workspace_app.sab` 和可执行文件。
- filtered Zig tests：
  - `timeout 120s zig test ... --test-filter "sla sab build defaults to managed sla cache"`
  - `timeout 120s zig test ... --test-filter "sla sab build emits direct SAB without SA source output"`

没有跑 `sci` 或插件全量测试；全量测试会造成不必要的 CPU/内存压力。
