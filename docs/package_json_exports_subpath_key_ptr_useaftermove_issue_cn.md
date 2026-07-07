# package_json_exports_subpath_from_text key_ptr UseAfterMove

状态：新发现，待 SLA compiler/backend 修复。

## 背景

在 `sla_tsgo` 继续按 Go `typescript-go` 架构补 `tspath.ToPath` 风格路径规范化时，`members/module/src/resolver.sla` 改为调用长度感知的 `path_extension_kind_len(...)`。随后按 SA fallback 验证 module contract：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla test tests/test_module_contract.sla --test-backend sa
```

测试尚未进入 resolver 相关断言，在导入图中的 `members/packagejson/src/packagejson.sla` 先触发 verifier `UseAfterMove`。

## 现象

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__package_json_exports_subpath_from_text(data: ptr, data_len
  line 27109 (expanded 9199):     tmp_1375 = call @sla__pkg_starts_with(subpath, subpath_len, key_ptr, pre_len)
  register: key_ptr
  state: expected Consumed, actual Consumed
```

JSON trap 摘要：

```json
{"trap":"UseAfterMove","trap_code":1009,"file":"tests/test_module_contract.test.sa","line":9199,"source_line":27109,"source_text":"    tmp_1375 = call @sla__pkg_starts_with(subpath, subpath_len, key_ptr, pre_len)","register":"key_ptr","expected_mask_name":"Consumed","actual_mask_name":"Consumed","function":"@sla__package_json_exports_subpath_from_text(data: ptr, data_len","message":"moved value is no longer usable"}
```

## 相关源码

`/home/vscode/projects/mnt/sla_tsgo/members/packagejson/src/packagejson.sla`：

```sla
let key_ptr = SLA_JSON_OBJECT_KEY_PTR(exp, ki);
let key_len = SLA_JSON_OBJECT_KEY_LEN(exp, ki);
let star = pkg_find_star(key_ptr, key_len);
...
if pkg_starts_with(subpath, subpath_len, key_ptr, pre_len) {
    ...
    let val = SLA_JSON_OBJECT_GET(exp, key_ptr, key_len);
}
```

`key_ptr` 是普通 pointer 值，按预期应该可作为 read-only ptr/len 参数多次传入 helper/macro。当前 SA backend 生成后把它标为 consumed，导致后续读触发 UseAfterMove。

## 下游影响

- 阻塞 `sla_tsgo` 的 `tests/test_module_contract.sla --test-backend sa` 聚合验证。
- 本次主线变更的 focused gates 不受影响：`tests/test_tspath_contract.sla --test-backend sa`、`tests/test_compiler_contract.sla --test-backend sa`、`tests/test_ls_contract.sla --test-backend sa` 均可继续验证。

