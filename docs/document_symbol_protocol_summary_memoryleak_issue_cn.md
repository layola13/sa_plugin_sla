# document symbol protocol summary direct contract MemoryLeak

日期：2026-07-06

状态：已修复并复验。该工单由 imported macro value-arg receiver-temp cleanup 覆盖修复，根因是 `parse_tokens(STR_PTR(text), STR_LEN(text))` 中 `STR_PTR` / `STR_LEN` 的 receiver load 临时寄存器没有在宏展开后释放。

## 背景

`/home/vscode/projects/mnt/sla_tsgo` 在对齐 Go upstream `internal/ls/symbols.go` 时，为 document symbols 增加了
hierarchical `DocumentSymbol` 与 legacy flat `SymbolInformation` 的协议形态 summary。源码检查通过，且经
`members/ls/src/ls.sla` facade 的 focused LS contract 能通过默认 SAB；但 direct contract 直接调用
`document_symbol_protocol_summary(parse, false)` 时，SA-text 与默认 SAB 都会在测试函数返回处留下 active temporary。

## 触发形态

仓库：`/home/vscode/projects/mnt/sla_tsgo`

临时 direct contract：

```sla
@test "document symbol protocol summary flat"() {
    let text = "class C { m() { return 1; } }";
    let parse = parse_tokens(STR_PTR(text), STR_LEN(text));
    let r = document_symbol_protocol_summary(parse, false);
    if r.status != 0 { panic(90); };
    if r.response_kind != DOCUMENT_SYMBOL_RESPONSE_FLAT { panic(91); };
    if r.item_count <= 0 { panic(92); };
    if r.flat_item_count != r.item_count { panic(93); };
    if r.hierarchical_item_count != 0 { panic(94); };
}
```

## 复现命令

```sh
SA_PLUGIN_DEV=1 sa sla check members/documentsymbols/src/documentsymbols.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_documentsymbols_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_documentsymbols_contract.sla --test-backend sa
```

源码 check 通过；direct contract 在上述临时测试存在时失败。

## 观察到的错误

默认 SAB：

```text
error[MemoryLeak]: live registers remain at function exit
  register: tmp_6052
  state: Active
```

SA-text fallback：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "document symbol protocol summary flat"():
  source_text: "    return"
  register: tmp_5568
  state: Active
```

## 原项目侧处理

`sla_tsgo` 曾移除 direct `document_symbol_protocol_summary` contract，用 LS facade 测试
`ls_get_document_symbols_with_capability(parse, false)` 覆盖 flat response kind；该 LS focused contract 在默认 SAB 下通过。
编译器 cleanup 修复后，hierarchical/flat direct summary contract 已恢复。

## 修复与复验

当前 `src/codegen.zig` / `src/sab_codegen.zig` 已在 imported macro value 参数求值产生临时结果时释放该参数寄存器。插件内回归 `tests/test_unit_str_ptr_len_identifier_direct.sla` 覆盖 `STR_PTR(text)` / `STR_LEN(text)` identifier receiver 临时值。

下游稳定 direct regression 已恢复，覆盖：

```sla
let text = "class C { m() { return 1; } }";
let parse = parse_tokens(STR_PTR(text), STR_LEN(text));
let flat = document_symbol_protocol_summary(parse, false);
let hierarchical = document_symbol_protocol_summary(parse, true);
```

验证命令：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla check members/documentsymbols/src/documentsymbols.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_documentsymbols_contract.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla test tests/test_documentsymbols_contract.sla --jobs 1 --trace-panic
```

结果：稳定 contract 的 `@test "document symbol protocol summary direct"` 直接覆盖 flat 与 hierarchical 两条 `document_symbol_protocol_summary(...)` 路径；host `--test-backend sa` 下 10/10 通过。
