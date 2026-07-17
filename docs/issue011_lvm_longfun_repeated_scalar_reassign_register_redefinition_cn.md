# issue011: `vm_builtin_string_format` 中反复自赋值的 scalar local 触发 `RegisterRedefinition`

日期：2026-07-13
状态：fixed/current-non-repro for the original `sf_pos`
RegisterRedefinition surface. `lua_sla/src_lua/lvm.sla` 的后续
`vm_table_set_index` / `tm` UseAfterMove 是新的大型下游 blocker，目前没有独立
最小 repro；后续应另开 issue 或先提取最小复现，不再把它归因到本 issue 的
scalar self-reassign register 重定义问题。

## Summary

`sa sla test lua_sla/src_lua/lvm.sla --test-backend sa` 在 `vm_builtin_string_format(vm: &VMState, ra: int, rb: int)` 内触发 trap：

## 2026-07-14 reverify update

使用当前 dev plugin 串行复验：

```sh
cd /home/vscode/projects/lua_sla
SA_PLUGIN_DEV=1 sa sla test src_lua/lvm.sla --test-backend sa --jobs 1 --trace-panic
```

原 `@sla__vm_builtin_string_format` / `sf_pos` `RegisterRedefinition(1006)` 未复现。测试继续执行到新的阻塞点：

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__vm_table_set_index(&vm: ptr, tidx: i64, key_tt: i64, key_i
  line 262662 (expanded 220563):     tmp_49541 = call @sla__vm_call_tm_lightc(&vm, ^tm, ^obj, ^key, tmp_49540, ^val)
  register: tm
  state: expected Consumed, actual Consumed
```

因此本文原始 scalar self-reassign `RegisterRedefinition` 证据应视为历史
surface，issue011 按 fixed/current-non-repro 关闭。当前大型 `lvm.sla` 仍有后续
move-state blocker，但应基于 `vm_table_set_index` / `tm` 提取新的最小 repro，或
另开 `UseAfterMove` 工单；不要再把当前失败归因到 `sf_pos` self-reassign。

```text
error[RegisterRedefinition]: register is already live
  in function @sla__vm_builtin_string_format(vm: ptr, ra: i64, rb: i64):
  line 138967 (expanded 102276):     sf_pos = tmp_17889
  register: sf_pos
{"trap":"RegisterRedefinition","trap_code":1006,...}
```

`sf_pos` 对应 SLA 源 `src_lua/lvm.sla:1942 let sf_pos = 0;`，第一个 `alloc` 在 `/tmp/lvm_built.sa:105456 sf_pos = tmp_17271`。之后函数体内对 `pos` 多次做形如下面的自增自减赋值：

```sla
let pos = 0;
...
while fi < flen {
    out[pos] = c;
    pos = pos + 1;
    fi = fi + 1;
}
```

生成的 SA 在 `pos = pos + 1;` 处编码为：

```text
tmp_17285 = const 1
tmp_17286 = add sf_pos, tmp_17285
!sf_pos                    # 释放 sf_pos (Consumed 状态机进入消费)
sf_pos = tmp_17286          # 在已被释放的 register 上再次 alloc -> "register is already live"
```

trap 在第二个 `sf_pos = tmp_X` 行（expanded line 102276，等等其中也有 `!sf_pos` 后立即重新 bind）；`sf_pos` register 进入 `Consumed` 状态后被 backend 在同 function scope 释放后第二次 `X = Y` 同名 rebinding 命中判错 "register is already live"。

## Root Cause (working hypothesis)

SLA backend 在 lowering `local_scalar = local_scalar OP const_expr` 的简单加法自赋值形式的指令时，先 emit `!local_scalar` 然后立即 `local_scalar = new_tmp`。这两条指令组合的语义在 `RegisterState` 机看来是：`!local` 计 `Consumed` 之后等待 GC，然后再次 `local = ...` 当作新 alloc——通常 backend 应将该 rebinding视为复用同一寄存器写，但这里执行 ⚑ register already live. 因为第一次 `sf_pos = tmp_17271` 之前的 forwarders没真的 scope out——它仍然 `Active`，后续 release 不让 `Active`转为  `Consumed-then-realloc` 路径不可 — 引发组 trap。

测试 minimal repro (两个独立函数均使用 `let pos = 0; pos = pos + 1; })未能复现：

```sla
fn f0(x: int) -> int {
    let pos = 0;
    pos = pos + 1;
    return pos + x;
}
fn f1(x: int) -> int {
    let pos = 0;
    pos = pos + 1;
    return pos + x;
}
# `sa sla check` / `sa sla test` 均 EXIT=0，test result 0 passed 0 failed
```

此 minimal 复现成功，但 lvm.sla 内的 `vm_builtin_string_format`  (462 行, 多分支条件块结构) 中放就 trap. **这个 trap 看上去需要那一长串复杂 control flow/tight register pressure 情境下才触发；尚未压制 minimal repro**.

## Evidence from `/tmp/lvm_built.sa`

```text
105456: sf_pos = tmp_17271             # 起点: pos = 0; 首次 alloc
105502: tmp_17286 = add sf_pos, tmp_17285
105504: !sf_pos
105505: sf_pos = tmp_17286             # pos = pos + 1; 重 bind ← 此处 trap
105567: !sf_pos
105599: tmp_17316 = mul sf_pos, 8
105609: !sf_pos
105610: sf_pos = tmp_17320             # pos = pos + body_len; 重 bind
...
```

函数 `@sla__vm_builtin_string_format` 内对 `sf_pos` register 总共有 10+ 此类 release-then-alloc 改组.

## Candidate fix

SLA backend 必须能区分同一 scalar local 的 `let X = ...` 一次绑定与  `X = ...` 自赋值的 reusable write back. 当前似乎 `let sf_pos = 0` 之后 `sf_pos = pos + 1` 在 后端转换成 `extend 计算 + 释放 + 再 alloc` 的序列，而 actual 写 simple add 仍属同一 birth scope 不必释放也可—— 或者 释放再通知重 hold. 当前实现下从 `Consumed` 反赖 `Active` 又 across scope to `new local live` 处理错误.

应在 lowering `fn` scope 内 的 `BinOp reassign`(simple '+ - * / etc)中不要 emit `!ident/lvalue = .. ;` 而只 emit:

```text
tmp_X = OP lhs, rhs
lhs = tmp_X
```

(`lhs` 原 binding 仍是该寄存器 active 状态；无需 `!lhs` then re-alloc) — 形成 removaleq replacement 不 splitionary.

## Regression

需要找到一个稳定 minimal repro 复现 trap；或者使用 `lua_sla/src_lua/lvm.sla` 自身作为大型 repro — endpoint 链。当前 test 流程为：

```text
cd /home/vscode/projects/lua_sla
rm -rf .sla-cache
timeout 1200 env SA_PLUGIN_DEV=1 sa sla test src_lua/lvm.sla --test-backend sa
# 5 分钟左右 sla codegen -> sa test 后 2 分钟 -> trap dump on stderr.
```

原始 `sf_pos` surface 当前不再要求新增最小回归。若后续 `tm` UseAfterMove 能
提取稳定 reducer，应在新的 issue 中补对应 fixture；不要复用
`tests/test_unit_scalar_reassign_register_redefinition.sla` 作为本 issue 的闭环条件。
