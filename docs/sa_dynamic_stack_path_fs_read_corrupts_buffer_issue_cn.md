# SA 动态栈路径 FS_READ_TO_STRING 返回损坏 buffer

## 状态

- 发现时间：2026-07-07
- 下游项目：`/home/vscode/projects/mnt/sla_tsgo`
- 后端：`--test-backend sa`
- 当前状态：已在编译器侧修复并用本地 CLI 复验。下游 `extends inherits base target/strict, child overrides module` 原始 filter 已通过本地 `sla-local-cli` 的 SA 后端，完整 `tests/test_tsconfig_contract.sla` 也已通过 19/19。默认 installed `sa` 命令截至 2026-07-07 仍表现为旧版本，完整下游合同仍是 18/19 并在 panic 302 失败；这属于工具同步状态，不再作为下游源码阻塞证据。

## 现象

`members/syntax/src/tsconfig.sla` 在解析 `child.json` 的 `"extends": "./base.json"` 时，会把当前 config 路径目录和 JSON string 中的 `base.json` 拼成动态 buffer，再调用 `SLA_FS_EXISTS` / `SLA_FS_READ_TO_STRING`。

`SLA_FS_EXISTS(dynamic_path, len)` 返回存在，但随后 `SLA_FS_READ_TO_STRING(dynamic_path, len, ...)` 返回的 data 指针内容不是目标文件内容，而是类似栈槽/寄存器数据的损坏 buffer。直接用字符串字面量读取同一个 `base.json` 能正常解析。

## 复现命令

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla test tests/test_tsconfig_contract.sla --test-backend sa
```

默认 installed `sa` 当前结果：18 项通过，`extends inherits base target/strict, child overrides module` 失败。

关键输出形态：

```text
DBG parse input len=84 text={ ... child.json ... }
...
DBG parse input len=84 text=\0...<stack-like garbage>...
DBG parse bytes=0x7ffe... len=84 ret=(nil)
PANIC: code=302
```

`base.json` 实际长度是 102 字节；失败路径中第二次 JSON parse 得到 84 字节损坏内容，长度也像 child 文件而不是 base 文件。

## 相关源码

`/home/vscode/projects/mnt/sla_tsgo/members/syntax/src/tsconfig.sla`：

```sla
let total = dir_len + eff_len;
let base_buf = SLA_BUF_ALLOC(total + 1);
let w = 0;
w = ts_buf_append(base_buf, w, path, dir_len);
w = ts_buf_append(base_buf, w, SLA_PTR_ADD(ext_ptr, estart), eff_len);
SLA_BYTE_PUT(base_buf, total, 0);
let base_probe = ts_buf_clone(base_buf, total + 1);

let base_exists = SLA_FS_EXISTS(base_probe.ptr, total);
let base_buf_handle = SLA_FS_READ_TO_STRING(base_probe.ptr, total, 65536);
let base_data = SLA_FS_BUFFER_DATA(base_buf_handle);
let base_data_len = SLA_FS_BUFFER_LEN(base_buf_handle);
let base = parse_tsconfig_from_text(base_data, base_data_len);
```

## 预期

动态构造的 path buffer 在传给 `SLA_FS_READ_TO_STRING` 时应按显式长度稳定读取目标文件，返回 `base.json` 的真实内容。

## 修复记录

根因有两层：

- `TsconfigPathSlice { ptr: out, len: n }` 这类 struct literal 中，raw `ptr` 字段被 shared struct-field transfer 规则误判为 owning pointer-backed aggregate，generated-SA 会写出 `^out`，导致后续动态 path buffer 被错误消费。
- `SLA_FS_BUFFER_DATA(...)` / `SLA_JSON_STRING_PTR(...)` 这类 imported macro expression-output 结果此前仍为 `infer`，后续 `JSON_PARSE(child_data, child_len)` 会把 raw ptr 参数物化成 stack slot，宏体中的 `&%bytes` 变成 pointer-to-pointer，最终读取栈槽字节而不是 JSON 文本。

修复位于 `sa_plugin_sla` 编译器侧：

- `src/lowering_rules.zig`：raw `ptr` / borrow / fn ptr 不再被 `structFieldIsPointerBacked` 归为 owning aggregate，struct literal 字段存储使用直接值传递。
- `src/type_checker.zig`：对 imported macro expression-output 做保守类型推断，`*_PTR` / `*_DATA` / `*_AS_PTR` 返回 raw ptr，`*_LEN` / `*_COUNT` 返回 i64。

新增/扩展回归：

- `tests/test_unit_tsconfig_buffer_cleanup.sla`
- `tests/import_fixtures/pkgjson/ptr_helpers.sa`
- `tests/import_fixtures/tsconfig_ext_child.json`
- `tests/import_fixtures/tsconfig_ext_base.json`

验证：

```sh
zig fmt --check src/type_checker.zig src/lowering_rules.zig src/codegen.zig
zig test src/lowering_rules.zig --test-filter "shared imported macro"
zig test src/lowering_rules.zig --test-filter "shared struct literal update field plan"
zig build --summary all
./zig-out/bin/sla-local-cli sla test tests/test_unit_tsconfig_buffer_cleanup.sla --test-backend sa --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_tsconfig_buffer_cleanup.sla --test-backend sab --jobs 1 --trace-panic
cd /home/vscode/projects/mnt/sla_tsgo
/home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli sla test tests/test_tsconfig_contract.sla --filter "extends inherits base target/strict, child overrides module" --test-backend sa --jobs 1 --trace-panic
```

结果：本 repo focused SA/strict SAB 为 5/5 通过；下游原始 filter 为 1/1 通过。

## 备注

同文件中 JSON string 比较已经改为显式 `ptr + len` byte compare，原先由 `str_eq` 读取非 NUL JSON slice 导致的崩溃已在下游修正。当前问题集中在动态 path buffer 与 FS read 的交互。
