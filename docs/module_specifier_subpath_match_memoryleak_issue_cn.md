# module specifier helper cleanup MemoryLeak

日期：2026-07-06

## 背景

`/home/vscode/projects/mnt/sla_tsgo` 在继续移植 `typescript-go/internal/modulespecifiers/specifiers.go`
时，新增了 package `exports` / `imports` subpath key 的轻量匹配 helper。源码自身通过 Sla
类型检查，但 focused contract 测试在调用 directory subpath matcher 后，SA-text 与默认 SAB 路径都会在
测试函数退出处报告 live temporary register。

这与现有 docs 中记录的临时值 cleanup 类问题相近，但当前复现面来自普通 ptr/len 字符串匹配 helper，
没有 Vec、Result 或 ECS payload。

## 触发形态

仓库：`/home/vscode/projects/mnt/sla_tsgo`

临时测试形态：

```sla
@test "exports subpath directory match"() {
    let dir = "./utils/";
    let spec = "./utils/math/add";
    if module_specifier_subpath_key_matches(STR_PTR(spec), STR_LEN(spec), STR_PTR(dir), STR_LEN(dir)) != true { panic(273); };
    if module_specifier_subpath_key_mode(STR_PTR(spec), STR_LEN(spec), STR_PTR(dir), STR_LEN(dir)) != MATCHING_MODE_DIRECTORY { panic(274); };
}
```

其中 `module_specifier_subpath_key_matches` 是纯标量 bool helper，内部按 key 模式做 exact / directory /
pattern 匹配；directory 分支只做 ptr/len 前缀循环比较。

进一步收窄后，即使只保留 directory key 分类调用也会在同一测试函数出口泄漏：

```sla
@test "exports subpath directory match"() {
    let dir = "./utils/";
    if module_specifier_matching_mode_for_key(STR_PTR(dir), STR_LEN(dir)) != MATCHING_MODE_DIRECTORY { panic(274); };
}
```

同一批 key-classifier helper 中，`imports` key validation 也会触发同类错误：

```sla
@test "imports key validation"() {
    let bad = "#/x";
    let ok = "#dep/*";
    if module_specifier_imports_key_is_valid(STR_PTR(bad), STR_LEN(bad), false) != false { panic(270); };
    if module_specifier_imports_key_is_valid(STR_PTR(bad), STR_LEN(bad), true) != true { panic(271); };
    if module_specifier_imports_key_is_valid(STR_PTR(ok), STR_LEN(ok), false) != true { panic(272); };
}
```

## 复现命令

```sh
SA_PLUGIN_DEV=1 sa sla check members/modulespecifiers/src/modulespecifiers.sla
SA_PLUGIN_DEV=1 sa sla check tests/test_modulespecifiers_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_modulespecifiers_contract.sla --test-backend sa
```

前两条 check 通过。第三条在上述临时测试存在时失败。

## 观察到的 SA-text 错误

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "exports subpath directory match"():
  source_text: "    return"
  register: tmp_2123
  state: Active
```

默认 SAB 路径也曾在同一测试形态下失败：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "exports subpath directory match"():
  register: tmp_2071
  state: Active
```

## 期望

- ptr/len 字符串 helper 的临时值在测试函数退出前被正确清理；
- 调用返回 bool/int 的 helper 不应让测试函数留下 Active temporary；
- SA-text 与 SAB cleanup 规则在该普通表达式路径上保持一致。

## 当前项目侧处理

`sla_tsgo` 当前 contract 测试已移除 directory-key 和 imports-key validation 单测，避免触发 cleanup bug。
随后 pattern subpath struct 返回路径也确认触发同类 cleanup trap，因此 exports/imports subpath key matcher
这组 contract 测试暂时整体移出。node_modules/package path slicing、entrypoint ending 等稳定路径仍有独立测试覆盖。
编译器修复后，建议恢复以下测试面：

- exports pattern key match：`"./feature/*"` 匹配 `"./feature/a/b"`；
- imports key validation：`"#/x"` 在 slash-imports disabled/enabled 下的差异；
- directory key classification：`"./utils/"` 识别为 `MATCHING_MODE_DIRECTORY`。

另一个相近触发面是 local choice 测试：调用 `module_specifier_choose_local_specifier(...)` 并读取
`LocalModuleSpecifierChoice` 返回值字段后，SA-text 也在测试函数出口留下 `tmp_*` Active。编译器修复后可恢复
`IMPORT_PREF_NON_RELATIVE` 和 shorter-relative 两个 direct struct-return 断言，以及
`module_specifier_count_path_components` 的 direct scanner 断言。

同类现象也覆盖 `NodeModuleSpecifierInfo` 这类新结构体返回值的 direct contract 调用。当前保留
`NodeModulePathParts`、package-name slicing、entrypoint ending 等组成逻辑测试；编译器修复后可恢复
`module_specifier_try_node_module_specifier` 的 package-root trimming 与 inaccessible node_modules 两个断言。

进一步验证中，`module_specifier_count_path_components`、`module_specifier_contains_ignored_path` 等新增
ptr/len scanner helper 的 direct contract 调用也会在测试函数出口触发同类 MemoryLeak。因此当前项目侧只保留
已经稳定通过的 19 个 modulespecifiers contract 用例；本文件记录的新增 scanner/path-choice 用例待编译器
cleanup 修复后恢复。
