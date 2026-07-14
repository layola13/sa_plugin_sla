# SAB deep-borrow void call cleanup regression

状态：部分关闭（2026-07-14）。9 个 strict direct-SAB `&field`/`&*field` runtime signal 11 已修复；SAB `--filter` 的 `no matching test` 注册问题仍开放。

## 当前复现

```bash
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test \
  tests/test_unit_borrow_temp_release_order.sla \
  --filter "void call with two deep borrow args releases both owners" \
  --test-backend sab --jobs 1 --trace-panic

SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test \
  tests/test_unit_borrow_temp_release_order.sla \
  --filter "deep owner remains reusable after void call arg cleanup" \
  --test-backend sab --jobs 1 --trace-panic
```

两条当前均以 code 1 失败。第一条的 SA-text 对照通过 1/1。

## 2026-07-13 排查记录

重新生成当前 direct-SAB artifact 后，第一条失败用例在第一个 `borrow_refcell_box_copy_increment(&*holder.items[0], &*holder.items[1])` 前仍走深层地址 `take/store` 路径：

```text
ptr_add r1625,r1619,16
take r1626,r1625,0u,ty:12
store r1625,0u,r1626,ty:12
...
ptr_add r1638,r1632,16
take r1639,r1638,0u,ty:12
store r1638,0u,r1639,ty:12
call "@sla__borrow_refcell_box_copy_increment","&tmp_863, &tmp_873"
```

SA-text 对照则是 `RC_GET tmp, owner` 后 `tmp_borrow = &tmp`，call 后释放 borrow temp 和 owner temp。把 smart-pointer address predicate 临时收窄到 slot 路径可以让 direct SAB 产物更接近 SA-text，但两条 runtime filter 仍失败；该实验已撤回，说明缺口不只是 `as_ptr_take_pointer_backed_value` 的静态分类。下一步应继续在共享 call-arg lifecycle 中建模“taken value restored before sibling args, borrowed operand, owner/source-temp cleanup”三者的关系，而不是只改 smart-pointer address 分类。

## 归属确认

在 sibling worktree 上对未修改 commit `1df9edc` 串行执行相同 build 和第一条 strict-SAB filter，结果同样失败。因此该问题不能归因于本轮共享静态调用计划；它与当前 RefCell/borrow-temp lifecycle 状态或近期分支合流有关。



## 2026-07-13 filter+test-harness 限制确认

对当前 worktree（build 7/7 通过）串行复测：

- 整文件 strict SAB（无 `--filter`）：`SLA_SAB_NO_FALLBACK=1 timeout 180 ./zig-out/bin/sla-local-cli sla test tests/test_unit_borrow_temp_release_order.sla --test-backend sab --jobs 1`：16 passed / 9 failed。
  - `void call with two deep borrow args releases both owners` 与 `deep owner remains reusable after void call arg cleanup` 在整文件跑时 **PASS**。
- 单 filter strict SAB：上述两条均以 code 1 失败，`--trace-panic` 无 panic 文本，test binary 唯一 stderr 为 `error: no matching test`。
- 单 filter SA-text：同样的 filter（例 `borrowed rc refcell field releases before owner temp`，该用例在整文件 SAB 也 PASS）在 SAB filter 下失败，在 SA-text filter 下 PASS。

结论：两条 filter 失败的直接原因不是 void call codegen 本身，而是 sa test harness 在 SAB 模块 + `--filter` 组合下的 runtime test registration/匹配缺陷——harness 链接的 test binary 找不到匹配测试并退出 `no matching test`。整文件跑时 test registry 正常，这两条 void call case 的 SAB codegen 正确性由整文件 PASS 证明。

仍开放的真正回归：整文件 strict SAB 仍有 9 个用例 `signal 11`，均为 `&field`/`&*field` 借用 smart-pointer 字段后 owner 释放路径冲突，属于 HEAD `1df9edc` 既有问题，需要在共享 call-arg lifecycle plan 中建模 non-owning field-view 与 owner struct cleanup 的关系，不能靠 SA/SAB 各自特判。下一步排查应聚焦 `genFieldAddress` 返回的 field-view pointer 在 `releaseAddressSource`/`emitRelease` 路径里的 non-owning 语义，并在共享层给出 field-view 不消耗 owner 的明确契约。

## 2026-07-14 field-view runtime 修复

根因分为两个直接 SAB 普通表达式路径，二者都绕开了共享地址计划的真实语义：

- `genBorrow()` 对 pointer-backed `&field` 先从字段槽加载 `Box`/`Rc`/`Arc` owner 值，把 owner 值当成 borrow view；后续被调用函数按“字段槽地址”解释该值，最终把 payload/count 等首字段误当指针解引用并 signal 11。
- prefixed borrow call-arg 路径也曾从字段槽加载 owner，再把 owner 作为参数并在调用后释放；这既传错 ABI 地址层级，也提前消费了仍由 containing struct 拥有的字段。

当前修复删除这两个普通 direct-SAB 局部分支。普通 field borrow 与 macro field borrow 现在统一消费 `planAddressOf()` 产生的已物化字段槽地址，并通过 `PrefixedBorrowAddressCallArgReleasePlan` 决定操作数前缀、taken-value restore 和地址/source 临时值 cleanup。Containing struct 内的 owner 不被加载成借用参数，也不在调用后释放。

串行证据：

- `zig build -j1 --summary all`：7/7；
- `zig test src/lowering_rules.zig --test-filter "shared refcell borrow call plan tracks payload kind and release macro"`：1/1；
- `zig build test -j1 -Dtest-filter="shared static call plan emits void calls without result registers" --summary all`：2/2；
- 修正陈旧 `Vec_len` inline-vs-call 断言后，focused std-surface metadata：2/2；
- `zig build test -j1 --summary all`：210/210；
- official dev install/help：通过；
- local strict direct SAB whole-file：25/25；
- local SA-text whole-file：25/25。

因此 9 个 field-view runtime signal 11 子问题已关闭，历史 25/25 whole-file 证据恢复。仍开放的是 SAB module + `--filter` runtime registration：过滤运行仍可能返回 `error: no matching test`，它不是当前 field-view codegen correctness 的反证。

## 期望

- 整文件 local/installed-dev strict SAB 保持 25/25；当前 local 已通过，installed-dev 复验待无并发测试窗口补齐。
- SA-text 保持 25/25；当前 local 已通过。
- 两条 filter 在 local 和 installed/dev strict SAB 下通过（仍开放的 harness 目标）。
- 修复必须进入共享 call/lifecycle plan 或 Typed HIR metadata，不能再增加 SA/SAB 各自的释放特判。
- 修复后重新核对整文件当前计数，再更新历史 `25/25` 记录。
