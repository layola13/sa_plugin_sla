# SA 动态栈路径 FS_READ_TO_STRING 返回损坏 buffer

## 状态

- 发现时间：2026-07-07
- 下游项目：`/home/vscode/projects/mnt/sla_tsgo`
- 后端：`--test-backend sa`
- 当前下游规避：避免继续展开递归 tsconfig extends loader；保留直接 base 配置读取测试作为通过基线。

## 现象

`members/syntax/src/tsconfig.sla` 在解析 `child.json` 的 `"extends": "./base.json"` 时，会把当前 config 路径目录和 JSON string 中的 `base.json` 拼成动态 buffer，再调用 `SLA_FS_EXISTS` / `SLA_FS_READ_TO_STRING`。

`SLA_FS_EXISTS(dynamic_path, len)` 返回存在，但随后 `SLA_FS_READ_TO_STRING(dynamic_path, len, ...)` 返回的 data 指针内容不是目标文件内容，而是类似栈槽/寄存器数据的损坏 buffer。直接用字符串字面量读取同一个 `base.json` 能正常解析。

## 复现命令

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla test tests/test_tsconfig_contract.sla --test-backend sa
```

当前稳定结果：18 项通过，`extends inherits base target/strict, child overrides module` 失败。

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

## 备注

同文件中 JSON string 比较已经改为显式 `ptr + len` byte compare，原先由 `str_eq` 读取非 NUL JSON slice 导致的崩溃已在下游修正。当前问题集中在动态 path buffer 与 FS read 的交互。

