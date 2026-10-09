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

## #4 模板字符串多插值：check 与 test 前端不一致 + 特定组合 runtime 崩溃（已确认）

- `check` 拒绝多插值模板：`println(`hi ${name}, n=${n}!`)` 报 `ExpectedDeclaration`，
  但同文件 `sa sla test`（SAB 路径）可通过（`tests/test_unit_template_string.sla` 亦如此：check 失败、test 3/3 通过）。
- 组合 `let name: ptr = "sa"; println(`hi ${name}, n=${n}!`)` 在 test 运行时触发
  `signal 6 / reached unreachable code`（`10_strings` 初版）。
  对照探针：`ptr` 单插值通过、无注解双插值通过，崩溃仅出现在 `ptr + 多插值` 组合。
- 现状规避：`10_strings` 的 `str_eq` 用 `: ptr` 绑定，模板插值用无注解绑定，两者分离。

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

## #7 全 return 臂的 switch 函数：check 与 SAB 后端要求互斥（已确认）

- 初版（各臂均 `return`，尾表达式即 `switch`）：`check` 与 `test` 均报
  `TypeMismatch in function tail expression: expected i32, actual void_type`，
  因 `switch` 本身是 `void` 语句。
- 加尾兜底 `return 3;` 后：`check` 通过，但 SAB 后端（`test`）报
  `FallthroughForbidden: basic blocks must end with jmp, br, br_null, or return`
 （不可达兜底块缺少终止子，SAB emitter 缺口）。
- 现状规避：采用 `tests/test_unit_switch_statement_direct.sla` 已验证的混合写法——
  一臂直接 `return`，其余臂赋值 + 尾 `return r`，check/test 双绿。
  tsgosa 的纯 `case: return` 风格在 SLA 侧暂无一对一写法。

## #8 默认参数值不支持：`fn f(a: i32 = 1)` 直接 parse 失败（已确认）

- 复现（/tmp/p_def2.sla）：`fn f(a: i32 = 1, b: i32 = 2) -> i32` 报
  `Syntax Error ... error.SyntaxError`（形参位置）。
- 现状规避：`47_default_args` 用 `f_default()`（零参）+ `f_full(a,b,c)`（全参）
  表达 `f()=6, f(10,2,3)=15, f(10,20,30)=60` 语义。

## #9 Label（`outer:` / `continue outer`）不支持（已确认）

- 复现（/tmp/p_lbl2.sla）：`outer: for i in 0..3` 报 `Syntax Error`。
  无 label 的内层 `break/continue` 正常（/tmp/p_lbl.sla check 通过）。
- 现状规避：`48_nested_break` 用内层 `break` 改写 `continue outer`
 （本用例等价，`t=3`；一般的跨层 continue 仍无对等写法）。

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
