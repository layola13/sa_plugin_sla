# issue022: sla_music_cli `build-exe` direct SAB keeps stale `tmp_*` call operands and trips `UseAfterMove`

日期：2026-07-15
状态：PARTIAL / OPEN（direct SAB codegen 症状已修复；`build-exe` 输入已裁剪；完整 native 验收仍阻塞于 timeout）

## Summary

`/home/vscode/projects/sla_music_cli` 的 music 纯 SLA 单测在 SA fallback 下已经通过，但真实 CLI 可执行文件构建走 direct SAB 时失败。失败点看起来不是 music 源码语义问题，而是 direct SAB call-arg materialization / operand serialization 问题：planned static call 里保留了 SA-text 风格的 `^tmp_*` operand 字符串，而不是使用当前 SAB register。

## Repro

```sh
cd /home/vscode/projects/sla_music_cli
printf 'track lead instr=12 key=0 vel=90 len=1;\nscore main main=1 { lead: 1 2 3 }\n' > /tmp/slamusic-input.sla
SA_PLUGIN_DEV=1 sa sla build-exe src/main.sla -o /tmp/slamusic-cli
```

结果：

```text
error[UseAfterMove]: moved value is no longer usable
  register: tmp_167
  state: expected Consumed, actual Consumed
  file: .sla-cache/sab/main-81c5284c2170c4fb.sab
  line: 790
```

## Evidence

Disassemble:

```sh
SA_PLUGIN_DEV=1 sa sla sab disasm .sla-cache/sab/main-81c5284c2170c4fb.sab --out /tmp/slamusic-main.disasm.sa
```

`music_cli_dispatch` 附近的 decoded call operands 异常：

```sa
call r25990,"@sla__music_cli_input_arg",""
call r25991,"@sla__music_cli_build","^tmp_13802"
call r25997,"@sla__music_cli_inspect","^tmp_13806"
```

这里 `music_cli_input_arg` 已经生成 SAB register `r25990`，后续 static call 却仍使用 `^tmp_13802` 这类 SA-text 临时名。direct SAB verifier 之后在 decoded `sa_vec_push` fragment 附近报 `tmp_167` 已 consumed。

## Working Hypothesis

`sab_codegen.zig` 的 planned static call 参数路径在某些 aggregate/by-value 参数上复用了 SA-text operand string，而不是根据 direct SAB 当前 lowered register 重新序列化 operand。该 stale operand 进入 decoded SAB 后，会让 verifier 的 move-state 与 register ownership 跟实际生成路径错位。

重点检查区域：

- `src/sab_codegen.zig`
- `emitPlannedStaticCallTo`
- `genPlannedSabCallArg`
- `moveCallArgFromValueReg`
- planned static call / aggregate call-arg materialization

## Acceptance

修复后至少需要：

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla build-exe src/main.sla -o /tmp/slamusic-cli
/tmp/slamusic-cli verify /tmp/slamusic-input.sla
/tmp/slamusic-cli inspect /tmp/slamusic-input.sla
/tmp/slamusic-cli build /tmp/slamusic-input.sla -o /tmp/slamusic.mid
```

并增加 compiler 侧最小回归，覆盖 helper 返回 aggregate 立即作为 by-value/static call 参数传入 direct SAB 的路径，确认 disasm 不再出现 stale `^tmp_*` operand。

## 2026-07-16 Update

本轮已修复两个直接相关的 direct SAB codegen 问题：

- std macro/template `ptr_add out, base, offset` 展开时，base 和 dynamic offset 两个 value operands 都会从模板文本名 coercion 成当前 SAB register。此前只处理 base，导致 `PTR_BYTE_ADD(arg.ptr, i)` 生成 `ptr_add r457,r458,"tmp_184"` 这类 stale text operand。
- borrowed stack-slot binding 存储 raw pointer scalar 后，不再对已被 `store` 转移进 slot 的临时 ptr 继续发 `release`。此前新生成 SAB 在 `cli_arg_eq` 中仍有 `store left_p,tmp_151` 后 `release tmp_151`，触发 `UseAfterMove`。

已验证：

```sh
zig fmt --check src/sab_codegen.zig
zig build test -j1 -Dtest-filter="std macro template coerces ptr_add dynamic offset arg" --summary all
zig build -j1 --summary all
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_ptr_byte_add_read_type_sa.sla --filter "direct sab ptr byte add stack slot temps are non owning" --test-backend sab --jobs 1 --trace-panic
sa plugin install --dev .
```

下游 `/home/vscode/projects/sla_music_cli` 清理相关 `.sla-cache/sab/main-81c5284c2170c4fb.sab*` 后重新生成的 disasm 已确认：

```sa
ptr_add r457,r458,r459
store r405,0u,r457,ty:12
```

即不再有 `ptr_add ...,"tmp_*"`，也不再有 `store ... r457` 后的 `release r457`。

完整验收仍未关闭：`SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla build-exe src/main.sla -o /tmp/slamusic-cli` 在重新安装 dev plugin 后不再快速报 `UseAfterMove tmp_151`，但当前在本机约 3 分钟处 timeout 124，未产出 `/tmp/slamusic-cli`。后续需要把这个 `build-exe` timeout 作为剩余 blocker 继续缩小；本 issue 保持 OPEN，直到 CLI 可执行文件和 `verify` / `inspect` / `build` 三个命令通过。

## 2026-07-16 Update 2

本轮确认 `call rN,"@sla__music_cli_build","^tmp_*"` 这类 disasm 形态本身不是 stale operand 的充分证据：SAB direct call body 仍保留源符号文本，`recordCallBodyRegs()` 会把 body 中已知符号记录到当前函数寄存器集合。最小 fixture 和下游 `music_cli_dispatch` 形态一致。

已落地一个 build-exe 输入缩小 slice：

- `SlaCompileOptions` 新增 `prune_for_entry_function`。
- `sa sla build-exe`、`sa sla build-workspace`、`sa sla sab workspace` 生成 native 输入 SAB 时从 `main` 做 post-typecheck reachable decl filter；`sa sla sab build` 保持完整 SAB 输出，方便检查/反汇编。
- `--emit-sab` 在 build-exe/workspace 路径不再二次编译 sibling SAB，而是写出同一份已裁剪的 `sab_bytes`。
- 新增 Zig 回归 `sla build-exe SAB codegen prunes unreachable main declarations`，确认 `main -> used -> helper` 之外的 unused function 和 test decl 不进入 executable SAB。

验证：

```sh
zig fmt --check src/plugin_compile_options.zig src/plugin_compile.zig src/plugin_commands.zig src/plugin_tests.zig
zig build test -j1 -Dtest-filter="sla build-exe SAB codegen prunes unreachable main declarations" --summary all
zig build -j1 --summary all
sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
git diff --check
```

下游 `/home/vscode/projects/sla_music_cli` 本地 strict direct-SAB `build-exe` 输入已从约 7.7MB / 778 funcs 缩到约 3.9MB / 396 funcs，且 `test_decl=0`。但完整 native 阶段仍未关闭：不带 `--emit-sab` 的真实路径

```sh
timeout 300s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla build-exe src/main.sla -o /tmp/slamusic-cli-pruned --jobs 1
```

在 direct SAB codegen 约 20s 后进入底层 `sa build-exe`，最终仍 timeout 124；对已裁剪 managed SAB 直接跑 `sa build-exe ... --jobs 1 --dce full` 也在 300s timeout。当前剩余 blocker 更像 SA native compile 对该仍较大的 CLI dispatch/音乐转换闭包不收敛，而不是 direct SAB stale operand。CLI `verify` / `inspect` / `build` 三个命令仍未运行。
