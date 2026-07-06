# document symbol protocol summary direct contract MemoryLeak

日期：2026-07-06

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

## 当前项目侧处理

`sla_tsgo` 已移除 direct `document_symbol_protocol_summary` contract，用 LS facade 测试
`ls_get_document_symbols_with_capability(parse, false)` 覆盖 flat response kind；该 LS focused contract 在默认 SAB 下通过。
编译器 cleanup 修复后，可恢复 hierarchical/flat direct summary contract。

