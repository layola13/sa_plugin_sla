# SLA 0.14.1 → 0.17 迁移总结（sa_plugin_sla `0.17` 分支）

> 范围：`sa_plugin_sla` 0.17 分支从“能编过”到“全量验收通过”。
> 工具链：系统自带 zig 0.14.1 → 实测使用 zig **0.17.0**。
> 配套：sibling `sci` 仓同步切到其 `0.17` 分支（`823c6569`），**sci 零改动、零提交**。
> 最终验收：`zig build` OK；`zig build test` OK；严格 sweep **527/527**；
> `sla test` 全量 **527/527 文件、794/794 用例**；
> `SA_PLUGIN_DEV=1 sa plugin install --dev .` 通过。

## 1. 环境准备（复现关键）

0.17 分支源码用了 0.17 新 API（`b.graph.io`、`b.graph.environ_map` 等），
系统自带的 zig 0.14.1（`@zigc/cli`）根本编不过，必须先准备 0.17 工具链：

```bash
# 1) 下载 zig 0.17.0（x86_64-linux，约 50MB）
mkdir -p /tmp/opencode
curl -L -o /tmp/opencode/zig-0.17.tar.xz \
  https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
tar -xf /tmp/opencode/zig-0.17.tar.xz -C /tmp/opencode/
export PATH=/tmp/opencode/zig-x86_64-linux-0.17.0:$PATH  # zig version → 0.17.0

# 2) 可选：让 sa 能找到 zig（sa 的子进程 PATH 查找弱，加 wrapper 最稳）
printf '#!/bin/sh\nexec /tmp/opencode/zig-x86_64-linux-0.17.0/zig "$@"\n' \
  > /usr/local/bin/zig && chmod +x /usr/local/bin/zig

# 3) sci 需要 LLVM（否则 sla test 报 LLVMBackend disabled）
apt-get install -y llvm-14-dev
```

构建约定（本仓实测）：

```bash
cd /content/sa_all/sci            # sibling 仓，先切 0.17 再编
git checkout -B 0.17 origin/0.17
zig build -Dllvm=false            # 无 LLVM 头时；有则直接 zig build
cp -f zig-out/bin/sa ~/.sa/bin/sa # 测试用，也可走 tools/install.sh（ReleaseFast，更慢）

cd /content/sa_all/sa_plugin_sla  # 本仓 0.17
export PATH=$HOME/.sa/bin:/tmp/opencode/zig-x86_64-linux-0.17.0:$PATH
zig build -Doptimize=ReleaseSmall # 或默认 Debug
zig build test                    # 无输出即全绿
SA_PLUGIN_DEV=1 sa plugin install --dev .   # 装 dev 插件（见 §5）
```

注意：

- 构建耗时 2~6 分钟，`bash` 工具 120s 超时会杀前台任务，
  务必 `nohup … &` 后台跑、轮询日志。
- `.sla-cache/` 是按**源码内容**哈希的，换编译器后必须 `rm -rf .sla-cache`，
  否则测到的是旧 SAB（曾因此误判 181“没修好”）。
- `sla test` 扫文件用例依赖 `SA_SLA_FIXTURE_DIR`（见 §4.6），sweep 脚本须导出：
  `export SA_SLA_FIXTURE_DIR=/content/sa_all/sa_plugin_sla/tests/import_fixtures/`

## 2. 基线（修之前）

| 项 | 结果 |
|---|---|
| `zig build`（0.17.0） | OK |
| `zig build test` | OK（exit 0） |
| 严格 sweep（`tools/strict_sweep.sh all`，SAB 直接、无 fallback） | 527/527 |
| 全量 `sla test`（212 tests + 315 rosetta） | 文件 518/527，用例 776 pass / 7 fail；**9 文件失败** |

9 个失败文件（与旧 HEAD 宣称的“9 pre-existing”数量一致）：

- `tests/test_unit_nullish_assign.sla`（TypeMismatch）
- `tests/test_unit_optional_chain.sla`（MemoryLeak）
- `tests/test_unit_tsconfig_buffer_cleanup.sla`（5 用例 fail，环境问题）
- `demos/rosetta/181_file_descriptor_raii`、`182_mmap_memory_mapping`（UseAfterMove→段错误）
- `demos/rosetta/185_dynamic_lib_dlopen`、`187_opengl_context_swap`（FallthroughForbidden）
- `demos/rosetta/314_async_await_pending_resume`、`315_async_thread_pool`（2s 到期 panic）

## 3. 编译器修复（`src/`，双后端多处镜像）

### 3.1 `??=` 缺 `Some` 回包（`src/parser.zig`）

`a ??= b` 脱糖成 `a = a.unwrap_or(b)`，`unwrap_or` 返回内部值（`i32`），
直接赋给 `Option<i32>` 目标 → `TypeCheck TypeMismatch`。
改为脱糖成 `a = Some(a.unwrap_or(b))`（`?.` 的脱糖早有同款 `Some` 包裹，
见 `parser.zig` `?.` 分支），并同步更新同文件 parser 单测的断言形状
（外层 `Some` + 内层 `unwrap_or`）。

### 3.2 语句丢值越过终结符（`src/sab_codegen.zig`，185/187）

`unsafe { …; return x; };` 作语句时，`genUnsafeExpr` 已终结路径并返回哑值，
外层 `genStmt` 的表达式语句分支仍无条件 `emitRelease(value)`，
在 `return_` 之后落下一条死 `release` → `FallthroughForbidden`。
修复：在 `genStmt` 的 call/通用表达式语句丢值处（及 `genMacroStmt` 对应处），
`lastIsTerminator()` 时跳过该 release（不可达清理本就不该发射）。

### 3.3 `File::open` 三连错（`src/sab_codegen.zig`，181/182）

反汇编定位到三个独立 bug（均只影响 SAB 直接后端，SA 文本后端对照正常）：

1. **`ok_reg` 双释放 → `UseAfterMove`**：`FS_OPEN_READ` 展开在 ok/err 分支用
   `emitBranchRelease(ok_reg)`（只发射、不记账），合并点又 `emitRelease(ok_reg)`，
   每条路径释放两次。修复：分支内补 `markConsumed(ok_reg)`，合并点删除重复释放。
2. **字符串字面量路径未物化 Slice → 段错误**：`genFileOpenCall` 对字面量参数走通用
   `genExpr`，在字面量类型为裸指针时拿到裸数据指针，再按 Slice 取 ptr/len 字段，
   读到垃圾地址（`borrow rX,rY` 中源寄存器从未赋值）。修复：字面量参数强制走
   `genStringLiteral` 构建 Slice。
3. **`as_raw_fd` 中间复制被释放 → 双 close**：`genFileAsRawFdCall` 的 `add` 中间复制
   （File 类型字）被 `release`，等于提前 close 一次，作用域清理再关一次。
   与 SA 文本后端对齐：不再释放该中间复制。

### 3.4 结果 slot 接管补运行时退役（`src/sab_codegen.zig` + `src/codegen.zig`，optional_chain）

`let r = if … { Some(…) } else { None }`（及 `?.` 脱糖、`match` 同形）报
`MemoryLeak`：分支堆分配经 slot 指针回读后，源 alloc 寄存器从未退役
（`store ptr` 是别名语义，不消费源；`lowering_rules.resultSlotStoreTransfersValue`
的设计意图本就是“slot 接管所有权”，但只有编译器侧记账、无运行时退役）。
修复：在 `storeResultSlotTransferredValue`（SAB）/
`storeResultSlotTransferredValueState`（SA 文本）走 transfer 路径时，
对非本地源补 `move_`（SAB）/`^tmp`（SA 文本）：只退役、不释放，
内存仍由 slot→合并加载结果释放。locals 豁免（SA 文本侧以 `tmp_` 前缀判定）。

### 3.5 插件 install 的 net 权限（`sap.json`，见 §5）

`libsla.so` 链接 `connect`/`socket`/`getaddrinfo` 等符号，
来源是 `std.Io.Threaded` 的 vtable（`src/sla_rt.zig` 进程级 Io + sci `sio`），
空 Zig 库对照干净、0.17 无裁剪选项、自写最小 VTable 代价过大。
按 `sa_plugin_vm` 先例声明最小 loopback net 权限
（`http://localhost`、`http://127.0.0.1`，GET；插件本身零网络 I/O，
仅为满足制品静态检查）。

## 4. Demo 修复（`demos/rosetta/`，4 个）

### 4.1 181/182：相对路径 → `/dev/null`、`/dev/zero`

Rust 原版开的就是 `/dev/null`（182 为 `/dev/zero` 语义），SLA 移植版误写成
相对路径 `"sap.json"`，在 `sla test` 的 cwd/sandbox 下打不开（unwrap panic 17）。
改回与 Rust 一致的绝对路径，CWD 鲁棒。

### 4.2 314/315：手动 `block_on` → `task::poll`，创建与驱动同函数

原 `block_on` 用 `FUTURE_READY_POLL_STATE` 直读 ReadyFuture 版式，
而 `defer_ready`/async 状态机是另一套布局 → 永远 Pending → 2s 到期 panic；
且 future 的 vtable 是编译器侧元数据，**不出函数**，跨函数传 future 必用错 poll fn。
改法：删除手动 pin/waker/Box 版 `block_on`，用已验证的 `task::new` +
`task::poll`/`task::result` 循环；future 的创建与驱动放在同一函数
（314 内联进 `pending_resume_total`；315 的 `pool_worker`/`drive_job` 改传 `i32`，
在 worker 内创建并驱动，只经 `Arc<Mutex>` 回传 `i32` 结果）。
`#[test]` 断言的数学期望不变（42；10+20+30）。

### 4.3 tsconfig：纯环境问题，未改码

用例读盘依赖 `SA_SLA_FIXTURE_DIR`，sweep 未导出该变量时 5 fail，
导出即 5/5。验收 sweep 须带该变量（见 §1）。

## 5. `sa plugin install --dev .`（曾阻塞，已打通）

- 现象：`plugin artifact references network symbol without declared net permission: connect`。
- 根因：见 §3.5（`std.Io.Threaded` vtable 链接 libc socket 面）。
  另踩过两个坑：`sa` 子进程找 `zig` 弱，加了 `/usr/local/bin/zig` wrapper
  脚本（exec 到 0.17 真体）；`~/.sa/bin/zig` 不能直接拷二进制（丢 `lib/` 即报
  `unable to find zig installation directory`）。
- 验证：安装 EXIT 0，`sa plugin list` 有 `sla`；
  `SA_PLUGIN_DEV=1 sa sla check/test` 端到端正常；
  此前修复点经**已安装的 dev 插件**复测全绿。
- 未覆盖：裸 `sa sla`（非 dev）在本机仍 `unknown command`，
  属正式 release bundle 流程范畴，不在本次验收内。

## 6. 验收结论与提交

| 项 | 结果 |
|---|---|
| `zig build` / `zig build test`（0.17.0） | EXIT 0 |
| 严格 sweep | 527/527 |
| 全量 `sla test` | 527/527 文件，**794/794 用例，0 失败** |
| `plugin install --dev` + dev 链路 | 通过 |

`origin/0.17` 提交（按序）：

1. `ad982a4c` — 验收修复：`src/{parser,sab_codegen,codegen}.zig` +
   4 个 demo（§3.1–§3.4、§4）。
2. `cde8cc61` — `sap.json` loopback net 声明（§5）。
3. `23a0db5a` — `.gitignore`：忽略 harness 会话态
   （`.codex-ultra/thread-skills/`、`.codex-ultra/vm-trash/`、
   `.opencode/package.json{,.lock}`）。

## 7. 已知限制（未修，有意延后）

- **跨函数 future 传参**：async 状态的 vtable 只活在编译器侧、按寄存器 key，
  出函数即丢，默认错配成 READY poll fn → 永 Pending。
  本次在 demo 侧规避（同函数创建+驱动）；根治需改 async ABI（自描述 vtable），
  工作量大、风险高，留待后。
- **`sla test` 需要 LLVM 版 `sa`**：无 LLVM 头的 `sci` 构建（`-Dllvm=false`）
  会导致 `LLVMBackend disabled`；本机已装 `llvm-14-dev` 全量构建。
- **sci 仓**：仅切分支+本地构建，**零改动零提交**；`sci` 侧 checker 对 Zig
  基线符号的严格性问题未动。
- 工作区常年有工具改写的 skills `SKILL.md` churn，未提交（恢复分支版本即可）。
