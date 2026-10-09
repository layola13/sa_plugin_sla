# SLA 待办（demos/basic 反哺编译器）

> 生成时间：2026-10-08；基准：`demos/basic` 50/50 `check + test` 全绿（`master fe747f7`）。
> 本文件是下一步工作的唯一入口：修编译器缺口 → 补 demos → 全量验证 → 推送。
> 缺口明细见 [`demos/basic/POTENTIAL_ISSUES.md`](../demos/basic/POTENTIAL_ISSUES.md)（#1–#10）；
> 路线图背景见 [`roadmap_status_cn.md`](./roadmap_status_cn.md)（Phase 3–6）。

## 0. 标准验证命令（每项工作收尾必跑）

```bash
export PATH="/tmp/gotools/zig-x86_64-linux-0.14.1:/content/sa_all/sci/zig-out/bin:$PATH"
# 全量（约 50 个 demo × check+test）
pass=0; fail=0; for d in demos/basic/*/; do n=$(basename $d); [ -f "$d/main.sla" ] || continue; if SA_PLUGIN_DEV=1 sa sla check "$d/main.sla" >/dev/null 2>&1 && SA_PLUGIN_DEV=1 sa sla test "$d/main.sla" >/dev/null 2>&1; then pass=$((pass+1)); else echo "FAIL $n"; fail=$((fail+1)); fi; done; echo "TOTAL pass=$pass fail=$fail"
# 抽查可执行落地
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/01_hello/main.sla -o /tmp/basic_01_hello && /tmp/basic_01_hello
```

## 1. 编译器缺口修复（按 ROI 排序）

- [x] **#6 补齐 `-= *= /= %=` 词法 token**（已修复：`src/lexer.zig` 新增
  `minus_equal/asterisk_equal/slash_equal/percent_equal` + `src/parser.zig`
  脱糖为 `sub/mul/div/mod` 二元运算；`31_compound` 已改回原生写法）。
  验收：`/tmp/probe_op.sla` 五种复合赋值 `check+test` 全过；`31_compound` 原生写法全绿；
  全量 50/50 + `zig build test` 302/302。
- [x] **#1 数组字面量元素类型错配**（已修复：`src/type_checker.zig` 新增
  `arrayElemStrictEqual/arrayCallArgStrictMatches`，`[i64;N]`→`[i32;N]` 等宽度错配
  在 `check` 直接报 `array element type mismatch`；`int` 即 `i64` 故现有 `08` 等不受影响）。
  验收：`/tmp/probe_arr.sla`（`[i32;5]` 形参 × `[3,1,4,1,5]` 字面量）`check` 退出 1 并报错；
  SA 后端原静默值错转为前置拦截，SAB 行为不变；现有 `08/16/22/27/28/35/36/37/38` 不回归，
  全量 50/50 + `zig build test` 302/302。
- [x] **#3/#5 字符串变量物化互斥**（已修复：SAB `: ptr` 绑定持有真正的 NUL 结尾
  C 字符串，无注解绑定保持 Slice 并以两集合区分消费路径；`str_eq/println/len/
  format-push/as_ptr` 均按实际表示 lowering）。验收：同一绑定既可 `str_eq` 又可
  `println`；`10_strings` 已合并为单绑定（另保留 `: ptr` 对照）后双后端全绿 +
  build-exe 输出正常。
- [x] **#10 `len(str)` 恒返 2**（已修复：字面量本轮复测已返回正确字节数；
  SAB 变量情形加推断集合护栏读 Slice 长度字段）。验收：`/tmp/p10_len.sla` 与
  `/tmp/plen_var.sla` 双后端全绿。
- [x] **#4 模板多插值 check/test 前端不一致**（已修复 check 侧：跳块扫描模板感知；
  `ptr + 多插值` 崩溃已消除）。验收：`/tmp/p4_multi.sla` 等 `check+test` 双绿；
  残留 #4b（嵌套 `format()` 在 `println` 内双后端只输出换行）已文档化，模板断言
  用 `str_eq`/直接格式化。
- [x] **#7 全 return 臂 switch**（已修复：检查器/共享层补 `switch` 终止判定，
  SAB 函数尾声 + 双后端合并块仅可达时发射）。验收：`/tmp/p7a.sla` 纯 `return` 臂
  尾 `switch` 写法 `check+test` 双后端全绿，build-exe 返回值正确；`33` 混合写法不回归。
- [ ] **#8 默认参数 / #9 label**（`parse` 直接失败类；需语言设计决策：支持 or 明确拒绝+文档）。
  验收：`47/48` 的 README 与语言规范口径一致。

## 2. demos/basic 51–60（tsgosa 待移植候选）

> 约束：`for in` 迭代器协议（Phase 6）、`async`、Node/Deno/NPM/Zod（203+）暂不碰；
> 字符串索引/`charCodeAt`/`charAt` 有物化坑（#3/#5/#10），字符串类用 `str_eq` 断言。

- [ ] `51_gcd_sum` ← tsgosa `159_gcd_sum`（多值 gcd 累加；`17/21` 已有 gcd，可复用）。
- [ ] `52_pow2_series` ← tsgosa `160_pow2`（2 的幂序列；与 `49_pow2` 互补）。
- [ ] `53_concat3` ← tsgosa `161_concat3`（三段拼接；`Vec::push` 表达，参考 `39`）。
- [ ] `54_neg_index` ← tsgosa `162_at_neg` / `169_neg_idx`（负索引语义用 `len - k` 表达，
  SLA 暂无 `at(-1)`，README 注明）。
- [ ] `55_num_sep` ← tsgosa `164_num_sep`（数字分隔符字面量；先探针 `1_000` 是否支持，
  不支持则记缺口 #11）。
- [ ] `56_chain_ops` ← tsgosa `165_chain`（链式调用；探针方法链在 direct-SAB 是否全绿）。
- [ ] `57_iife` ← tsgosa `170_iife`（立即调用闭包；参考 `20_closures`）。
- [ ] `58_sum_2d` ← tsgosa `172_sum_2d`（二维扁平求和；参考 `19/28` 行主序布局）。
- [ ] `59_count_even` ← tsgosa `174_count_even`（偶数计数；与 `29/43` 互补，换 `Vec` 版）。
- [ ] `60_sort_desc` ← tsgosa `190_sort_desc`（降序插入排序；`16/38` 已有升序，取反比较子）。

每个 demo 要求：`main.sla`（`main + println` + `@test`）+ `README.md`
（tsgosa 编号 + 命令 + 绕行说明）+ 入 `demos/basic/README.md` 索引表。

## 3. 门禁（提交前必查）

- [ ] 新增 demo 逐个 `check + test` 通过（命令见 §0）。
- [ ] 全量 `TOTAL pass=N fail=0`（N = 现有数 + 新增数）。
- [ ] `build-exe` 抽查 ≥2 个新增 demo 可运行输出。
- [ ] `POTENTIAL_ISSUES.md`：新发现记编号 + 复现探针路径；已修复的把“现状规避”改为
  “已修复（commit）”并保留复现记录。
- [ ] commit message 大写英文（例：`FEAT(SLA): ...`），`git push` 到 `origin/master`，
  回报 `pass/fail` 数字与 commit hash。

## 4. 进度账本（追加记录，不删历史）

- 2026-10-08：`demos/basic` 01–20 落地，全绿 20/20，发现 #1–#5（`95e845f` 已推送）。
- 2026-10-08：21–30 落地，全绿 30/30（`fde346f` 已推送）。
- 2026-10-08：31–40 落地，全绿 40/40；根因定位 #6（lexer 缺 token）、#7
 （check/SAB 互斥）（`78ac251` 已推送）。
- 2026-10-08：41–50 落地，全绿 50/50；新增 #8/#9/#10；49 collatz 步数口径
  用 build-exe 核对为 111（`d5a2f6f` + `fe747f7` 已推送）。
- 下一步：先做 §1 前两项（#6、#1），再做 §2 的 51–60。
- 2026-10-09：#6 已修复并验证（全量 50/50 + zig build test 302/302 + build-exe 抽查 01_hello），
  `31_compound` 改回原生写法；已推送（`0915b61`）后继续 #1，再做 §2 的 51–60（每批10个及时提交推送）。
- 2026-10-09：#1 已修复并验证（错配探针 `check` 退出 1 报错，全量 50/50 + zig build test 302/302），
  待推送后继续 #3/#5/#10。
- 2026-10-09：#3/#5/#10 已修复并验证（探针串全绿：`p3 EQ/PASS`、`p5 build-exe hello 退出0`、
  `plen_var` 双后端、`p10`；`10_strings` 合并单绑定后双后端全绿 + build-exe 正常；
  全量 50/50 + zig build test 302/302），待推送后继续 #4/#7。
- 2026-10-09：#4 已修复 check 侧（跳块扫描模板感知，`p4` 探针串双绿；残留 #4b 嵌套
  输出已文档化）+#7 已修复（终止判定 + 双后端合并门，`p7a` 双后端全绿 + exe 返回 20；
  全量 50/50 + zig build test 302/302），待推送后继续 #8/#9 与 51–60。
