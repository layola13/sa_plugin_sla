# linked editing direct TSX helper contract 触发 MemoryLeak

状态：已修复并复验。该工单由 imported macro value-arg receiver-temp cleanup 覆盖修复，根因是 `parse_tokens_tsx(STR_PTR(text), STR_LEN(text))` 中 `STR_PTR` / `STR_LEN` 的 receiver load 临时寄存器没有在宏展开后释放。

## 现象

`sla_tsgo` 新增 linked editing range summary 时，直接 contract 在同一个测试里调用 `parse_tokens_tsx(...)`，再把结果传给 `linked_editing_for_position(...)`，会在 SA test backend 的函数退出清理阶段触发 `MemoryLeak`：

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_linkedediting_contract.sla --test-backend sa
```

失败点示例：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "linked editing tsx parse surface"():
  register: tmp_5302
  state: Active
```

## 触发形态

```sla
let text = "let view = <div></div>;";
let parse = parse_tokens_tsx(STR_PTR(text), STR_LEN(text));
let r = linked_editing_for_position(parse, 2);
```

其中 `linked_editing_for_position` 返回结构体 `LinkedEditingRangeResult`。

## 影响与兜底

- `members/linkedediting/src/linkedediting.sla` 可以通过 `sa sla check`。
- 使用显式构造 `ParseResult` 的 direct contract 通过。
- LS facade 路径 `ls_get_linked_editing_range(parse_tokens_tsx(...), 2)` 在 `tests/test_ls_contract.sla --test-backend sa` 中通过。
- 为了继续 `sla_tsgo` 主线开发，direct TSX parse helper contract 暂未纳入稳定测试面。

## 修复与复验

当前 `src/codegen.zig` / `src/sab_codegen.zig` 已在 imported macro value 参数求值产生临时结果时释放该参数寄存器。插件内回归 `tests/test_unit_str_ptr_len_identifier_direct.sla` 覆盖 `STR_PTR(text)` / `STR_LEN(text)` identifier receiver 临时值。

下游稳定 direct regression 已恢复，覆盖：

```sla
let text = "let view = <div></div>;";
let parse = parse_tokens_tsx(STR_PTR(text), STR_LEN(text));
let r = linked_editing_for_position(parse, 2);
```

验证命令：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla check members/linkedediting/src/linkedediting.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_linkedediting_contract.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla test tests/test_linkedediting_contract.sla --jobs 1 --trace-panic
```

结果：稳定 contract 的 `@test "linked editing tsx parse surface"` 直接覆盖 `parse_tokens_tsx(STR_PTR(text), STR_LEN(text))` + `linked_editing_for_position(parse, 2)`；host `--test-backend sa` 下 6/6 通过。

## 相关文件

- `/home/vscode/projects/mnt/sla_tsgo/members/linkedediting/src/linkedediting.sla`
- `/home/vscode/projects/mnt/sla_tsgo/tests/test_linkedediting_contract.sla`
