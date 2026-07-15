# issue022: sla_music_cli `build-exe` direct SAB keeps stale `tmp_*` call operands and trips `UseAfterMove`

日期：2026-07-15
状态：OPEN

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
