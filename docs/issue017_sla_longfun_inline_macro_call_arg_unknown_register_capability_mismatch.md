# issue017: 超长函数内 inline 宏结果作 call arg 触发 `UnknownRegister` / `CapabilityMismatch`

日期：2026-07-14
状态：open (regressor file `sla_tsgo/members/ast/src/scanner.sla`；未拿到独立最小 repro)

## Summary

`sla_tsgo` 的 TypeScript scanner 关键字识别函数 `lookup_keyword(t: ptr, start: int, len: int) -> int`（`members/ast/src/scanner.sla:67`）是一个**超长扁平函数**：函数体由 9 个分长度段（len==2 … len==11）的连续 `if check_kw(t, start, STR_PTR("..."), N) { return KindX; };` 组成，共 **75 个内联 `STR_PTR("...")` 宏调用**作为 `check_kw` 的第 3 个 `ptr` 参数。

`sa sla check members/ast/src/scanner.sla` ✓ 类型/语法校验通过；
但 `sa sla test tests/test_checker_contract.sla`（该测试套件最终会经 scanner 走到 `lookup_keyword`）触发 trap。

不同 backend 给的 trap_code 不同，但函数归因一致：

### SAB 默认 backend
```text
error[UnknownRegister]: register is not declared in the current scope
  register: tmp_220
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_checker_contract-830bd2358b33a32c.sab","line":738,...,"register":"tmp_220",...}
```

### SA-assembly backend (`--test-backend sa`)
```text
  in function @sla__lookup_keyword(^t: ptr, start: i64, len: i64) -> i64:
  line 32244 (expanded 2272):     tmp_338 = call @sla__check_kw(t, start, tmp_334, tmp_337)
  register: tmp_338
{"trap":"CapabilityMismatch","trap_code":1013,"file":"tests/test_checker_contract.test.sa","line":2272,"source_line":32244,"source_text":"    tmp_338 = call @sla__check_kw(t, start, tmp_334, tmp_337)","message":"call-site capability prefix does not match the callee contract",...}
```

## 关键观察

1. trap 统一发生在 `@sla__lookup_keyword` 内部某个 `call @sla__check_kw(t, start, <tmp_a>, <tmp_b>)` 站点；
2. SAB backend 报 `UnknownRegister(1007): tmp_220`，SA backend 报 `CapabilityMismatch(1013): tmp_338`，且 SA backend 明确给出归因到 `check_kw` 调用、`tmp_334 / tmp_337` 是 inline `STR_PTR("...")` 宏返回 ptr 临时寄存器、`tmp_338 = call check_kw(...)` 是 check_kw 返回值再写入的临时寄存器；
3. 两个不同 backend 给出**不同 trap_code** 但都定位到同一个函数、同一个调用模式 —— 印证是 SLA 编译器在 lowering inline 宏结果作 call arg 时，对临时寄存器的 `capability prefix` / `scope declaration` 推导崩坏；
4. `sa sla check` 通过 → 是 codegen/backend lowering 层面的 bug，不是 SLA 源码类型检查问题。

## Root Cause (working hypothesis)

SLA 编译器在 lowering 超长函数体内「inline SA-macro 结果作为 call argument」的模式时，对 macro 内部展开出的临时寄存器（`STR_PTR` → `EXPAND SLICE_GET_PTR %out_ptr, %slice_reg`）与其所在调用点 callee contract 的 capability 前缀（`^ptr` / `ptr` / `&T`）的推导，存在寄存器生命周期/作用域声明错位：
- 长 function 中累积 75 个该类内联 bytes-pointer 临时；
- backend 在某条 `tmp_X = call check_kw(t, start, tmp_<str_ptr_out_i>, tmp_<const_N>)` 处给 `tmp_X` 的 capability prefix 推导了一个 callee contract 不允许的前缀（或在某控制流路径上未声明即用）；
- SAB backend 因寄存器作用域记录出错报 `UnknownRegister`，SA backend 因能力前缀不匹配报 `CapabilityMismatch`，本质同一处 lowering 缺陷。

## 与 issue 系列关系

- 与 issue006（sla_tsgo parser 链式 `p2 = F(p2)` over-conservative phi-merge）同一家族根：SLA backend 对 inline-temporary / rebind 的寄存器生命周期推导过于保守或倾斜；但 trap_code 不同（006→UseAfterMove 1009，本→1007/1013），触发结构不同（本不涉及 move 语义，纯 lowering 时序）。
- 与 issue011（`vm_builtin_string_format` 长函数 `local = local OP const` 自增自减触发 `RegisterRedefinition`）**高度同源**：都是「超长函数内 backend 对 local/temporary 寄存器的 alloc/release 时序与作用域状态机产生冲突」。区别是 issue011 是 scalar 自增自减，本 issue 是 inline 宏结果作 call arg。
- 建议 fix 一并审视 long-function 寄存器生命周期状态机：`UnknownRegister` / `CapabilityMismatch` / `RegisterRedefinition` / `UseAfterMove` 应同源于 long-function alloc-scope lowering 修复带。

## Repro

环境：
```text
project: /home/vscode/projects/mnt/sla_tsgo
compiler: /home/vscode/.sa/bin/sa  (# sa binary modtime 2026-07-13 18:20:39)
scan toolchain: SLA_PLUGIN_DEV=1 sa sla ...
```

复现命令：
```sh
cd /home/vscode/projects/mnt/sla_tsgo
rm -rf .sla-cache
SA_PLUGIN_DEV=1 sa sla check members/ast/src/scanner.sla   # ✓ passes (type-check)
SA_PLUGIN_DEV=1 sa sla test tests/test_checker_contract.sla                 # ✗ UnknownRegister(1007) tmp_220 @ SAB 738
SA_PLUGIN_DEV=1 sa sla test --test-backend sa tests/test_checker_contract.sla # ✗ CapabilityMismatch(1013) tmp_338 @ expanded 32244, in @sla__lookup_keyword
```

## 已尝试的 source-side 实验（全部不能消除 trap）

注：scanner.sla 与 git HEAD 一致（0 diff）—— 本 trap 是 HEAD 既有，非任何 Pass 引入。以下均在 sla_tsgo 项目层进行，目的是隔离 SLA 编译器 bug，不是作为正式修复。

### 实验 A：将 `STR_PTR("...")` 从内联位置提到 `let` 局部变量
仅改 `len == 9` 段（5 个 STR_PTR 调用），把每个内联 `STR_PTR("xxx")` 改成 `let kw_i = STR_PTR("xxx"); if check_kw(t, start, kw_i, 9) { ... };`。`sa sla check` 仍通过。
重跑 `test_checker_contract.sla`：trap **完全不变**——`tmp_220 @ SAB 738`，连 SAB 文件 ID `830bd2358b33a32c` 都一致。
结论：陷阱命中的不是 len==9 段，inline vs let 的局部变动影响不到该次 sinning 路径；已回滚实验。

### 实验 B（未执行，避免 issue006 同类型破坏性移动）：全函数 75 个 STR_PTR 改成 `let` 局部变量
可能能消除该/tmp_220，但因 issue006 Pass49→51 经验显示同类 long-function 寄存器重整只会在 SAB 内移动 trap 而非根除；且扫描已确认 trap 在 SAB 第 738 行而非函数末尾，改善面太广，不再尝试。

## 影响面

sla_tsgo 全量扫描 148 测试套件，已知：
- 5 GREEN（test_core/discovery/protocol/sourcemap/tsconfig_contract）
- 143 RED：
  - `UnknownRegister`(1007) / `RegisterRedefinition`(1006) / `MemoryLeak` / `PhiStateConflict` / `CapabilityMismatch`(1013) 各自命中不同套件
  - 多个 contract 套件（`test_checker_contract`, `test_astnav_contract`, `test_binder_contract`, `test_callhierarchy_contract`, `test_codeactions_contract`, `test_compile_ts_to_js_text_contract`, `test_compiler_*`（共 11 个 checker_pool 套件）, `test_diagnostics_contract`, `test_documenthighlights_contract`, `test_documentsymbols_contract`, `test_emitter_contract`, `test_emitter_js_text_contract`, `test_emitter_write_capture_contract`, ...）在 `ast/scanner` 内超长函数/成 call-site 处同源触发
- 同 regime 的 `test_parser_contract`, `test_module_specifier_*` 等仍维持 `UseAfterMove`(1009) = issue006

## 建议的 SLA 编译器端 fix 方向

1. 长函数（>上限，例如 N>32 左右）的寄存器分配/capability prefix 推导，在 inline SA-macro 结果作 call arg 时，明确 macro 输出寄存器与 callee 参数 contract 的能力等价化规则；
2. 长函数内 control-flow join 点的 `register alive-set` 与 backend 临时寄存器 release/realloc 时序在 `alloc_release/PhiStateConflict` 环节做横向一致校验；
3. 复用 issue011 修复路径中 long-function alloc-scope machinery。
4. 提供 compiler 选项 `-Wlongfun-regalloc` 用于标记可疑 long-function lowering 以便定位。

## fix 检验硬门槛

修复落地后，必须满足：
1. `/home/vscode/.sa/bin/sa` modtime 由 `2026-07-13 18:20:39` 更新；
2. `sla_tsgo` 全量扫描在 HEAD scanner/parser 状态下 GREEN 套件数从 5 显著上升（不应仅依赖 `sla_tsgo` 侧绕过）；
3. `test_checker_contract.sla` 的 `UnknownRegister(1007) tmp_220 @ SAB 738` 与 `CapabilityMismatch(1013) tmp_338` 两个 backend trap 一致消失。

### Turn 12 REFINED — refactored + experiment links issue017 to issue006
- 实验 A ( alleen len==9 segment STR_PTR→let) 已经做过(陷阱在 len==2 段,所以那次 trap 不动)。
- 实验 C: 重构把整 `lookup_keyword` 拆成 10 个子函数 (按长度 `len` 分派),\*同时\* 把每个子函数内的 inline `STR_PTR("...")` 提到 `let` 局部变量。`sa sla check` ✓ 通过(行为等价)。
- 重新跑 `tests/test_checker_contract.sla` SAB 默认 backend,tr**完全转换为不同 trap_code**:
  - 原 SAB backend:   `UnknownRegister(1007)  tmp_220              @ SAB 738`
  - 重构后 SAB backend: `UseAfterMove(1009)  sla__lookup_keyword_2__param_0_t  @ SAB 789`
  - 关键: 寄存器从匿名的 `tmp_220` 转为 **实名标记的函数参数** `sla__lookup_keyword_2__param_0_t`(我新拆出的 `lookup_keyword_2(t, start: int)` 函数里第 0 个参数 `t: ptr`)。state: `expected Consumed, actual Consumed, mask 8/8` — 与 issue006 同一签名。
- SA backend (`--test-backend sa`) 现在归因到:
  - 之前 `@sla__lookup_keyword` 在 `tmp_338 = call @sla__check_kw(t, start, tmp_334, tmp_337)` 处的 `CapabilityMismatch(1013) tmp_338`
  - 重构后预期归因会到 `@sla__lookup_keyword_2` 同样 `check_kw` 调用点(待复核)。

### 解释: issue017 与 issue006 同根
当 `STR_PTR("...")` 是 inline 调用 作 `check_kw` 第 3 个 ptr 参数时,SLA 编译 lowering 该位置生成匿名临时 `tmp_N`(对应 `param/source` 没有显式 capability declaration),触发 `UnknownRegister` / `CapabilityMismatch`。
当把 `STR_PTR(...)` 提到 `let kwK = STR_PTR(...)` 然后 `check_kw(t, start, kwK, N)` 时,lowering 状态机就回到了 issue006 模式:第 0 个参数 `t` (已声明的 named `^ptr`/ptr 函数参数) 经过 `let kwK = STR_PTR(...)` 与后续 `check_kw(t, ...)` 时序后被 SLA backend 过度保守地判为 `Consumed/Consumed` mask 8/8 —— 即 issue006 同一套 phi-merge / 能力前缀状态机在不同 ordering 下的相态切换。

**结论**: `UnknownRegister`/`CapabilityMismatch`/`UseAfterMove` `Consumed/Consumed` 均是 SLA 编译器 **call-site 参数所有权 + 寄存器生命周期 lowering** 的不同相态投影,统一于 long-function / inline/macro call arg / move-state 修复带。

### Refactored state of sla_tsgo scanner (实验, will note rollback decision separately)
- 备份: `/tmp/scanner_head_backup.sla`(原 HEAD scanner.sla)
- 重构文件:`members/ast/src/scanner.sla` — 拆为 10 子函数 + dispatch dispatcher。`sa sla check` 仍 ✓ 通过。
- 重构后仍 RED — 只是把 trap_code 从 `UnknownRegister(1007)` 切到 `UseAfterMove(1009)` 同源家族。**不构成 fix**。

### Issue017 -> issue006 linkage推荐
issue006 中列举的三种 SLA 编译器端 fix:
  (a) relax `LoopConditionalConsume` on explicit release/break pacing
  (b) auto-balance owned bindings at loop-exit/break phi-merge
  (c) correct over-conservative merge of chained `p2 = F(p2)`
应**扩充第 4 项**:
  (d) 正确推断函数参数(以及 `let` 临时)在 callee call-site 的 capability 前缀与 inline/macro 展开调用 site 的寄存器生命周期关系;尤其当参数是 named 正函数参数传入 (有 SLA backend 顶层 `^ptr` Capability declaration)而非 inline 匿名临时,backend 不能因 `let kwK = STR_PTR(...)` 的临时生命周期与 `check_kw(t, ...)` 错位而 `UseAfterMove` 函数参数。
本实验给出第 4 项的实物映射,可循此嫁接到 issue006 fix 设计。
