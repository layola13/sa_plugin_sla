# SLA 潜在问题追记（basic demos 反哺）

在参考 `tsgosa/demos` 丰富 `demos/basic` 时，用 `sa sla check/test/build-exe` 实际验证，
发现以下候选问题。状态分为：已确认 / 待复核 / 已规避（demo 侧绕行）。

## #1 定长数组元素类型错配：check 放行，运行值错（已修复：check 拦截）

- 复现：`fn array_sum(values: [i32; 5])` + 调用 `array_sum([3,1,4,1,5])`，
  字面量按 `int`(i64, 8B stride) 分配 40B，形参按 `i32`(4B stride) 读取，
  `check` 通过，`test` 在求和断言上 panic（`demos/basic/08_arrays` 初版 panic 804）。
  SA 后端（`--test-backend sa`）复现 panic 1001，SAB 后端因 `expected_ty` 路径碰巧通过。
- 期望：`check` 应对 `[i64;5]` → `[i32;5]` 报类型错，或自动统一字面量元素类型。
- 已修复：`src/type_checker.zig` 在全部 `plainCallArgMatches` 调用点后加
  `arrayCallArgStrictMatches` 宽度检查，错配报
  `array element type mismatch (stride differs)`；`/tmp/probe_arr.sla` 现 `check` 退出 1。
- 现状规避：`08_arrays` 改用 `[int; 5]`（与 `tests/test_unit_arrays.sla` 一致）。
- 归属：前端类型检查（Phase 5 聚合布局相关）。

## #2 `if` 表达式作返回值需要 `return if ...`（写法约束，非 bug）

- `fn max(a: i32, b: i32) -> i32 { if a > b { a } else { b } }` 可通过，
  但多行函数体中 `return if c > 10 { 100 } else { 200 };` 更稳。
- 已在 `03_if_else / 06_ternary` 两种写法各保留一种，验证均通过。

## #3 字符串字面量类型推断：无注解绑定 str_eq 失败（已修复）

- 复现（/tmp/probe_str.sla）：`str_eq("hello","hello")` 通过；
  `let s = "hello"; str_eq(s, "hello")` panic；
  `let s: ptr = "hello"; str_eq(s, "hello")` 通过。
- 根因：无注解绑定运行时是 Slice，但检查器暴露为 raw_ptr；
  SAB 的 `str_eq` 指针相等快径与 `CSTR_FROM_PTR` 把 Slice 结构体误当 C 字符串。
- 已修复：SAB 以 `inferred_string_slice_locals` 识别无注解绑定，
  快径排除 + 参数直通 Slice；`/tmp/p3_unannot.sla` 与 `/tmp/p3_main.sla`
 （`EQ`）在默认/SA 双后端全绿。
- 现状（已消除绕行）：`10_strings` 已合并为单绑定，另保留 `: ptr` 对照断言。
- 关联：`current_plan.md` 提到 `str_eq` 相关 known issues；`68_parser_tokens`（数组/参数来源的 ptr）不受影响。

## #4 模板字符串多插值：check 与 test 前端不一致 + 特定组合 runtime 崩溃（已修复 check 侧；残留 #4b）

- `check` 拒绝多插值模板：`println(`hi ${name}, n=${n}!`)` 报 `ExpectedDeclaration`，
  但同文件 `sa sla test`（SAB 路径）可通过（`tests/test_unit_template_string.sla` 亦如此：check 失败、test 3/3 通过）。
- 根因（check 侧）：`check` 以 `.parse_test_bodies = false` 解析，`@test` 体走
  `skipBlockSpan/peekBlockSpan` 跳块；两者按裸花括号计数，模板 `${...}` 的插值
  `}` 被误作块结束，块被提前截断，剩余 `, n=...` 在顶层报 `ExpectedDeclaration`
 （单插值在 `@test` 内同样触发；`fn` 体因正常解析不受影响）。
- 已修复：`src/parser.zig` 两处跳块扫描镜像词法模板状态机
 （`template_start/interp/end` + `interp_depth` 栈），`/tmp/p4_multi.sla`、
  `/tmp/p4_single_test.sla`、`ptr+多插值` 的 `check` 均通过，`test` 双绿；
  本轮复测 `ptr + 多插值` 的 `unreachable` 崩溃已不再出现
  （`: ptr` 绑定持有真 C 串后 CSTR 路径正常）。
- 现状规避：`10_strings` 的打印统一用 `"..."` 格式化（见其 README）。
- 残留 #4b（已修复，2026-10-10）：反引号模板脱糖为嵌套 `format()` 调用
  （`println(format(...))`），此前双后端 `println` 仅当首参为字符串字面量才
  展开占位，嵌套调用只输出换行。现单参 string-like/format-string 走既有
  per-arg 发射（SAB 经 `planPrintlnArg` + `emitPrintlnArg`，SA 镜像同发射），
  其余元数保持裸换行历史行为。回归 `94_nested_tpl` 已补直打断言。
  模板断言仍可用 `str_eq(format(...), ...)` 或 `"..."` 直调。

## #5 `println("{}", s)` 与 `str_eq(s, …)` 对字符串变量注解的要求互斥（已修复）

- 复现：`str_eq` 要求显式 `: ptr`（#3），但 `println("{}", s)` 对 `: ptr` 绑定
  在 SAB 原生 `build-exe` 运行时崩溃（`signal 6 / reached unreachable code`，
  /tmp/probe10e.sla；本轮复现为 `/tmp/p5_noimp.sla` build-exe `abort 134`，
  而 `test` 双后端通过、`sa run` 正常）。
- 根因：SAB 的 `: ptr` 绑定借用 dance 引用了未定义的寄存器
  （反汇编见 `borrow r17,r18` 且 `r18` 无定义），`println` 再把数据指针
  当 Slice 解引用（`load +0/+8`）。
- 已修复：SAB 的 `: ptr` 字符串绑定直接持有 NUL 结尾数据指针
  （`explicit_ptr_string_locals`），`println/len/format-push/as_ptr` 对其走
  C 字符串路径；`/tmp/p5_noimp.sla` build-exe 输出 `hello`，退出 0。
- 现状（已消除绕行）：`10_strings` 已合并为单绑定，另保留 `: ptr` 对照断言。
- 归属：`println`/格式化路径与字符串变量物化（SAB emitter）。

## #6 复合赋值仅支持 `+= |= &=`，`-= *= /= %=` 无词法 token（已修复）

- 复现（/tmp/probe_op.sla）：`x += 1` 通过；`x -= 1` / `x *= 2` / `x /= 4` / `x %= 5`
  均报 `Unexpected prefix token: equal`；对照 `x |= 1` / `x &= 1` 通过。
- 根因：`src/lexer.zig:62-106` 的 token 枚举仅定义 `plus_equal`、`pipe_equal`、
  `ampersand_equal`（另有 `question_question_equal`），缺失 `minus_equal` /
  `asterisk_equal` / `slash_equal` / `percent_equal`，故 `-=` 等被切分为 `-` + `=`。
- 期望：在 lexer + parser 补齐四种复合赋值（或 `check` 给出明确不支持提示）。
- 已修复：`src/lexer.zig` 新增四种 token 及 `-/ * / / / %` 后接 `=` 分支；
  `src/parser.zig` 在 `parseStmt` 脱糖为 `sub/mul/div/mod` + `assign`，
  并补入 `genericLookaheadBoundary`；`31_compound` 已改回原生写法，全量 50/50 全绿。

## #7 全 return 臂的 switch 函数：check 与 SAB 后端要求互斥（已修复）

- 初版（各臂均 `return`，尾表达式即 `switch`）：`check` 与 `test` 均报
  `TypeMismatch in function tail expression: expected i32, actual void_type`，
  因 `switch` 本身是 `void` 语句。
- 加尾兜底 `return 3;` 后：`check` 通过，但 SAB 后端（`test`）报
  `FallthroughForbidden: basic blocks must end with jmp, br, br_null, or return`
 （不可达兜底块缺少终止子，SAB emitter 缺口）。
- 根因：三处不识别全发散 `switch` 尾——检查器 `exprTerminates` 无 `switch` 分支；
  共享 `lowering_rules.exprTerminates` 同缺；SAB 函数尾声无条件发射取值尾声；
  SAB/SA 的 `switch` 合并哨兵无条件发射（不可达指令落到终止子之后）。
- 已修复：检查器 + 共享层 `exprTerminates` 新增 `switch` 臂
  （全臂发散 + 含 `default` 才算终止）；SAB 函数尾声对终止体跳过取值尾声；
  SAB/SA 的 `switch` 合并块仅在可达时发射（有 fallthrough、无 default、
  或末臂非 default）。探针 `/tmp/p7a.sla`（纯 `return` 臂尾 `switch`）
  `check + test`（SAB/SA 双后端）全绿，build-exe 运行返回 20 正确。
- 现状：`33_switch_return` 保留已验证的混合写法（仍双绿）；
  纯 `case: return` 尾 `switch` 风格现已同等支持。

## #8 默认参数值不支持：`fn f(a: i32 = 1)` 直接 parse 失败（已决策：明确拒绝）

- 复现（/tmp/p_def2.sla）：`fn f(a: i32 = 1, b: i32 = 2) -> i32` 报
  `Syntax Error ... error.SyntaxError`（形参位置）。
- 决策：语言规范 §15 明确列为不支持；解析器对形参 `=` 给出针对性提示
  （`expected r_paren (default parameter values ... see demos/basic/47_default_args)`，
  探针 `/tmp/p8.sla` 已验证）。
- 官方绕行：`47_default_args` 用 `f_default()`（零参）+ `f_full(a,b,c)`（全参）
  表达 `f()=6, f(10,2,3)=15, f(10,20,30)=60` 语义（README 与规范口径一致）。

## #9 Label（`outer:` / `continue outer`）不支持（已决策：明确拒绝）

- 复现（/tmp/p_lbl2.sla）：`outer: for i in 0..3` 报 `Syntax Error`。
  无 label 的内层 `break/continue` 正常（/tmp/p_lbl.sla check 通过）。
  `break/continue` 后不接受标签名（`continue outer` 报 `expected semicolon`）。
- 决策：语言规范 §15 明确列为不支持；解析器对语句首 `name:` 给出针对性提示
  （`expected semicolon (loop labels ... see demos/basic/48_nested_break)`，
  探针 `/tmp/p9.sla` 已验证）。
- 官方绕行：`48_nested_break` 用内层 `break` 改写 `continue outer`
  （本用例等价，`t=3`；一般的跨层 continue 仍无对等写法，需显式重写；
  README 与规范口径一致）。

## #10 `len()` 作用于字符串返回表示字数而非字符数（已修复）

- 复现（/tmp/p_strlen*.sla）：`len("hi there")` / `len("")` / `len("hello")`
  曾返回 `2`（疑为胖指针表示字数）；本轮复测字面量 `len` 已返回正确字节数
  （`5/0/8`，`test` + build-exe 双绿）。
- 根因（变量情形）：SAB 的 `len()` 对 raw_ptr 统一做 `CSTR_LEN` NUL 扫描，
  而无注解变量实际是 Slice，扫描结构体字节得垃圾值
 （本轮复现：`/tmp/plen_var.sla` 默认后端 `panic 2001`，SA 后端通过）。
- 已修复：SAB 的 `len()` 对 `inferred_string_slice_locals` 改读 Slice 长度字段；
  `/tmp/plen_var.sla` 双后端全绿。
- 现状：字符串相等断言统一用 `str_eq`（见 #3），`len(str)` 字面量与变量均已验证。

## #11 数字分隔符字面量（已修复，2026-10-10）

- 原复现（/tmp/psep.sla）：`let x = 1_000;` 报
  `found '_000', expected semicolon`（词法数字段遇到 `_` 即停，后续当标识符）。
- 修复：词法仅保留数字间 `_`（十进制/浮点小数两侧/十六进制；尾随与孤立 `_`
  保持历史切分行为）；parser 五处转换点（整数/浮点/后缀/重复数组长/定长类型长/
  枚举判别式）经 `stripNumericSeparators` 去分隔符后沿用原逻辑。
- 验证：`1_000+2_000`、`0xFF_FF`、`7_000.5`、`1_000i32`、`0..1_0` 双后端全绿 +
  build-exe 输出核对；`1_`、`1__000` 仍为同类语法错误；回归 `55_num_sep`
  已改直写分隔符形式。

## #12 链式赋值（已修复，2026-10-10）

- 原复现（/tmp/pchain.sla）：`a = b = 5;` 报 `found '=', expected semicolon`
  （赋值语句不返回值，属明确拒绝）。
- 修复：parser 语句层将 `=` 右结合链 desugar 为块
  `{ let __chainK = value; tn = __chainK; …; t1 = __chainK; }`
 （`__qcN` precedent；右向左赋值；纯 `=` 链，`let x = a = 5` 与混合 op-assign
  不在范围）；单赋值路径逐字保留。单态化/checker/双后端零改动（块/let/赋值
  均为既有节点）。
- 验证：双/三链（含函数调用右值）与字段/索引目标双后端全绿 + build-exe
  输出核对；回归 `56_chain_ops` 已改直写链式。

## #13 闭包字面量直接调用（已修复，2026-10-10）

- 原复现（/tmp/piife.sla）：`(|x: int| x * 2)(21)` 报
  `found '21', expected callable function ... (error.InvalidCallTarget)`。
- 修复：`ast.CallExpr` 加 `callee: ?*Node`（默认 null，零兼容影响）；
  parser `l_paren` 位仅放行 `.closure_literal`（其余保持原拒绝文案）；
  checker 首分支镜像命名闭包路径做元数/类型检查；
  SAB/SA 发射首分支直达既有 `genClosureCall`；
  单态化 5 处重建点透传并特化 `callee`（本轮真凶：重建丢字段导致空名调用）；
  18 处 `exprNeeds*` + assigned/addressable/future-runtime/preload/escaped/thread
  visitor 同步覆盖 callee 子树。
- 验证：位置矩阵（let/println 实参/嵌套调用/嵌套闭包/while cond/if cond）
  双后端全绿 + build-exe 输出核对 + 三拒绝路径（非闭包 callee 沿用
  InvalidCallTarget；元数/类型错配各有明确错误）；回归 `57_iife` 已补直接调用断言。
- 现状：`57_iife` 先绑定写法保留为等价写法，直接调用为推荐写法。

## #14 HashMap 在 SAB 默认后端报 UnknownRegister（已修复，2026-10-10）

- 原复现：两次 `insert` + `get().copied().unwrap_or_default()` 在 SAB 默认后端报
  `trap UnknownRegister 1007 ... "callee is not declared"`；`--test-backend sa` 通过；
  仓库内 `demos/rosetta/53_cache_hits` 同症。另注意 `sa sla test` 对零 `@test`
  文件不执行 `main`（m1–m6 空转教训），回归断言必须进 `@test`。
- 根因：SAB 对 `HashMap.get` / `Option.copied` / `Option.unwrap_or_default`
  全无 lowering，通用路径放出 `@sla__get` 等不存在的 callee。
- 修复：SAB 加三处 direct lowering 并挂入 `genCall` 分发（`genMapInsertCall` 之后）：
  `genMapGetCall`（`MAP_TRY_GET` + `OPTION_NEW_SOME/NONE` 折叠，miss 得 `None`，
  与 SA 的 `SLA_MAP_TRY_GET_OPTION` 同语义）；`genOptionCopiedCall`
  （`OPTION_COPIED_U64`）；`genOptionUnwrapOrDefaultCall`
  （`OPTION_UNWRAP_OR_DEFAULT`，零值默认与 SA 一致）。接管条件均为 receiver
  类型匹配（HashMap/Option），其余保持原 fallback。
- 后续（2026-10-10）：`BTreeMap.get`（`genBTreeMapGetCall`，值直存经栈槽中转，
  与 SA 的 `SLA_BTREE_MAP_TRY_GET_OPTION` 同语义）与 `len()` 的 BTree 分支
  （`genVecLenCall` 内 `BTREE_MAP_LEN`）一并补齐；空表缺失/覆盖写/多键/缺键/
  表长矩阵双后端全绿 + build-exe 输出 `10,2,0,2` 核对。
- 后续（2026-10-10）：`map.clear()` 双容器支持（checker `isClearCall` 分支定
  void 类型；SAB 经 `MAP_CLEAR` / `BTREE_MAP_CLEAR` 宏，SA 直调
  `@sa_map_clear` / `@sa_btree_map_clear`；清零后重插矩阵双后端全绿 +
  build-exe 输出 `0,3,0,8` 核对）。`167_map_clear` 可据此落地。
- 验证：空表缺失/覆盖写/多键/缺键矩阵双后端全绿 + build-exe 输出 `10,2,0` 核对；
  `53_cache_hits` 通过。

## 已验证无问题（回归对照）

- [x] `Vec<i32>` vs `Vec<int>` stride（09_vec_methods 全绿，无数组字面量式问题）。
- [x] `switch` over `i32`（13_enum_switch 全绿）。
- [x] `Option::Some/None + match`（15_option 全绿，未触发 PhiStateConflict）。
- [x] 闭包捕获 + 循环（20_closures 全绿）。
- [x] `while true + break/continue`（32 全绿）、`do-while` 语义经 `break` 表达（40 全绿）。
- [x] 嵌套循环众数/中位数排序（37/38 全绿）、`Vec` 拼接去重（39 全绿）。
- [x] 归并/位运算/素数上限/默认参数双函数/label 改写（41-48 全绿）。
- [x] 长循环 collatz（49 全绿，步数口径已用 build-exe 核对为 111）、
  嵌套 `if` + 步长 `while`（50 全绿；`for` 暂无步长语法，用 `while` 表达）。
