# selection_ranges_for_positions 直接测试触发 MemoryLeak

状态：已修复。

## 现象

在 `sla_tsgo` 新增 selection range summary 时，直接 contract 调用 `selection_ranges_for_positions(parse, N)` 曾在 SA test backend 的函数退出清理阶段触发 `MemoryLeak`。直接 probe 中 `N = 0` 和 `N = 3` 都复现过：

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_selectionrange_contract.sla --test-backend sa
```

失败点示例：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "selection ranges for multiple positions"():
  register: tmp_5349
  state: Active
```

## 最小触发形态

稳定复现不是结构体返回本身，而是进入 helper 前的字符串 slice 宏实参：

```sla
let text = "function f() { return 1; }";
let parse = parse_tokens(STR_PTR(text), STR_LEN(text));
let r = selection_ranges_for_positions(parse, 3);
```

`STR_PTR(text)` / `STR_LEN(text)` 对 owned `str`/`Slice` 绑定求值时，会先从 `text` 栈槽 load 出 receiver 临时寄存器，再展开 `sa_std/string.sa` 宏。旧的 imported macro value-arg 清理只使用 `callArgNeedsRelease(identifier) == false`，导致这些 receiver load 临时寄存器在宏展开后没有释放。

原 helper 形态如下，曾经误导排查方向到结构体早返回/聚合返回：

```sla
fn selection_ranges_for_positions(parse: ParseResult, position_count: int) -> SelectionRangeResult {
    if parse.node_count <= 0 { return selection_ranges_none(SELECTION_RANGE_NO_SOURCE); };
    if position_count <= 0 { ... };
    let base = selection_ranges_for_position(parse, 1);
    if base.status != SELECTION_RANGE_OK { return base; };
    return SelectionRangeResult { status: SELECTION_RANGE_OK, range_count: base.range_count * position_count, parent_count: base.parent_count * position_count, position_count: position_count, root_kind: base.root_kind };
}
```

## 影响与兜底

- `members/selectionrange/src/selectionrange.sla` 可以通过 `sa sla check`。
- 下游稳定 contract `tests/test_selectionrange_contract.sla` 的 SA-text 和默认后端均通过。
- 临时直接 probe 的 `selection_ranges_for_positions(parse, 0)` / `selection_ranges_for_positions(parse, 3)` 在 SA-text 和 strict direct SAB 后端均通过。

## 修复

- `src/codegen.zig`：imported macro value 参数在 `genExpr()` 产生真实临时结果时，宏展开后释放该实参寄存器；覆盖 `STR_PTR(text)` / `STR_LEN(text)` 这种 identifier 求值为 load temp 的场景。
- `src/sab_codegen.zig`：direct SAB 的 imported macro value 参数使用同等释放语义，避免 direct SAB 中相同 receiver load temp 泄漏。10s strict SAB 复验还暴露过一个后续 `StackEscape`：`let text = "abc"` 因 `STR_PTR(text)` 被标记为 borrowed stack storage 后，旧 lowering 会把 string literal 产生的 stack-allocated Slice 存入本地槽后再 `move_` 该 Slice。当前修复在 borrowed stack-storage let 路径中保留 non-owning stack-derived source，不再对它发释放/移动指令。
- 新增插件内回归 `tests/test_unit_str_ptr_len_identifier_direct.sla`，直接覆盖 `ptr_len_roundtrip(STR_PTR(text), STR_LEN(text))`。

## 验证

```sh
zig build --summary all
zig build test --summary all
./zig-out/bin/sla-local-cli sla test tests/test_unit_str_ptr_len_identifier_direct.sla --test-backend sa --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_str_ptr_len_identifier_direct.sla --test-backend sab --jobs 1 --trace-panic
sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_str_ptr_len_identifier_direct.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_str_ptr_len_identifier_direct.sla --test-backend sab --jobs 1 --trace-panic
```

当前本地 10s strict direct-SAB no-fallback 复验：`tests/test_unit_str_ptr_len_identifier_direct.sla` 1/1 passed，约 3.47s，确认不再触发 `StackEscape tmp_3`。

下游 host evidence：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla check members/selectionrange/src/selectionrange.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_selectionrange_contract.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla test tests/test_selectionrange_contract.sla --jobs 1 --trace-panic
```

下游直接回归已恢复：`tests/test_selectionrange_contract.sla` 的 `@test "selection ranges for multiple positions"` 现在直接覆盖 `selection_ranges_for_positions(parse, 0)` 和 `selection_ranges_for_positions(parse, 3)`，并在 host `--test-backend sa` 下通过 5 个测试。

## 相关文件

- `/home/vscode/projects/mnt/sla_tsgo/members/selectionrange/src/selectionrange.sla`
- `/home/vscode/projects/mnt/sla_tsgo/tests/test_selectionrange_contract.sla`
