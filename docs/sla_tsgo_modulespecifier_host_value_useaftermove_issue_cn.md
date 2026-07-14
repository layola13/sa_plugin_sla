# sla_tsgo modulespecifier host value UseAfterMove — usage-pattern guideline (NOT a compiler bug)

日期：2026-07-13（初版）/ 2026-07-13 重定基调 Pass 47

状态：closed — 已在 sla_tsgo Pass-47 通过 SLA 语言层面的借用-copy 模式规避，非 SLA 编译器缺陷。保留为 SLA 使用规范/工程指引。

## 复盘结论

最初在 sla_tsgo Pass 46 观察到的 `members/modulespecifiers/src/modulespecifiers.sla` clean-check `UseAfterMove` 并非 SLA 编译器 bug，真实根因是 SLA 移动语义（所有用户定义 struct 都是非 Copy，按值传递/按值 let 绑定在进入函数体或首次动态读取时消耗原 owner），叠加 `.sla-cache/sab/` 陈旧二进制在 Pass 24–45 掩盖了真实代码 shape 导致的污染回归。

Pass 47 在 sla_tsgo 侧对售后 `members/modulespecifiers/src/modulespecifiers.sla`、`members/compiler/src/compiler.sla`、`members/ls/src/ls.sla`、`members/tsoptions/src/parsedcommandline.sla` 重写为借用-copy 模式（即 `_copy_borrow(&base)` helper + `..base` struct-update syntax），令所有读 host/Program 派生值仍存的路径都不移动底层 owner。讨论核对：

- 所有 16+ read-only host/list/buf accessor dispatchers 均接 `&T` borrow 参数（只读借用，不消耗 owner）。
- `module_specifier_path_candidate_byte_buf4_set_borrow` / `_at(buf: &T, index)` / `_copy_borrow(p: &T)` 在 modulespecifiers 链通；modulespecifiers 全模块 + 上游 `members/ls/src/ls.sla` + `members/compiler/src/compiler.sla` 均 `sa sla check` GREEN。
- `members/tsoptions/src/parsedcommandline.sla` 内 `source_output_and_project_reference_map_empty()` 修复为 `let d0..d7 = factory();`;"独立工厂" 取代单 `let d = default()`，避免单字面量内多次移动同一 owner。
- `members/compiler/src/compiler.sla` 的多 `Program { ... }` 字面构造辅助（`program_with_processed_files`, `program_with_parsed_command_line`, `program_with_redirect_targets_map`, `program_with_checker_pool`, `program_with_package_json_cache_entry`）统一重写为 `Program { changedField: ..., ..program }` 单字段 struct 更新语法，避免整 `.program.*` 多字面量搬动。

15/18 sla_tsgo 主套件已 strict-SAB no-fallback 严格复验通过（host_min 8/8、options_preferences 6/6、candidate_list 10/10、candidate_bytedir 13/13、multi_candidate_min 8/8、multi_candidate_sort 4/4、multi_candidate_redirect 5/5、multi_candidate_redirect_targets 6/6、redirect_targets_map 6/6、host_project_reference_map 5/5、host_source_bytes 7/7、get_for_file_with_info 6/6、multi_candidate_dispatched_cascade 6/6、parsed_command_line 6/6、source_output_reference_map 6/6）。

## SLA 语言层面剩余的编译器侧面问题

与本次 host-value 主题无关，为重心确定的另一个 issue：在 `members/ast/src/parser.sla` 中，箭头函数 builder 内多步链式 `p2 = F(p2)` 重赋值 + phi-merge + 配合落入 `return G(p)` 路径会触发 SLA 直 SAB verifier 的 `UseAfterMove`，且即便运行时控制流从未进入箭头路径，同一 trap 点也btain reproducible（详见 `issue006_sla_tsgo_parser_chained_reassign_useaftermove.md`）。其结果直接掩盖了 sla_tsgo 中任何调用 `program_new_single_file -> parse_tokens` 的测试套件，使得以下 3 个测试套件同样无法回归：

- `test_module_specifier_package_json_cache_map_min.sla`
- `test_program_parsed_command_line_min.sla`
- `test_module_specifier_program_multi_candidate_min.sla`

issue006 是 SLA 编译器 / SAB codegen 级残留 issue，不是 sla_tsgo 工程能独立绕开的 SLA 移动语义学习指引可解决范围；该问题留待 SLA 编译器侧修复后再行复验。

## 推荐参考的 SLA ownership tutor / usage pattern regression

- `docs/tutor/03_ownership.md`：移动/借用语义、`Move`、`UseAfterMove` 保护。
- `tests/test_unit_assign_move_cleanup.sla:9-17`：外层绑定 borrow-and-reassign pattern `let next = step(boxed); boxed = next;` — 内层 let 重新做一次完整 ident-to-ident 复制素稳定通过 SAB。
- `tests/test_unit_sa_aggregate_reassign_move_cleanup.sla:17-29`：聚合 paired reassign 游线（同形状）。

## 复验命令

```sh
# pass47-style:
cd /home/vscode/projects/mnt/sla_tsgo
rm -rf .sla-cache
# Modules get standalone clean checks before tests
SA_PLUGIN_DEV=1 sa sla check members/modulespecifiers/src/modulespecifiers.sla
SA_PLUGIN_DEV=1 sa sla check members/compiler/src/compiler.sla
SA_PLUGIN_DEV=1 sa sla check members/ls/src/ls.sla
SA_PLUGIN_DEV=1 sa sla check members/tsoptions/src/parsedcommandline.sla

# main suite no-cache regression sweep
for t in test_module_specifier_host_min \
        test_module_specifier_options_preferences_min \
        test_module_specifier_candidate_list_min \
        test_module_specifier_candidate_bytedir_min \
        test_module_specifier_multi_candidate_min \
        test_module_specifier_multi_candidate_sort_min \
        test_module_specifier_multi_candidate_redirect_min \
        test_module_specifier_multi_candidate_redirect_targets_min \
        test_module_specifier_redirect_targets_map_min \
        test_module_specifier_host_project_reference_map_min \
        test_module_specifier_host_source_bytes_min \
        test_module_specifier_get_for_file_with_info_min \
        test_module_specifier_multi_candidate_dispatched_cascade_min \
        test_parsed_command_line_min \
        test_source_output_reference_map_min; do
    rm -rf .sla-cache
    SA_PLUGIN_DEV=1 timeout 200 sa sla test tests/$t.sla | tail -3
done
```

## 结论

sla_tsgo Pass 47 后，本 issue 可由 closed 状态关闭，对 SLA 编译器 / SAB codegen 残留的实际 trigger 转由 `issue006_sla_tsgo_parser_chained_reassign_useaftermove.md` 单独工单追踪。
