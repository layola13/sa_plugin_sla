# issue: SA-text Vec 结构体元素索引/写回仍存在指针槽别名生命周期问题

状态：fixed/current-non-repro on 2026-07-16

## 现象

`/home/vscode/projects/sla_music_cli/src/music_ir.sla` 在 SA-text 后端仍有 `music_ir` 布局相关测试失败。当前确认 SA 标准库 `Vec` 的元素槽存储的是 `u64`/指针值；`elem_size` 用于容量、偏移步长和整体 buffer copy，不代表 `sa_vec_push` 会把整个结构体 inline 写入槽位。因此问题不应继续按“inline struct slot 读取”修复，而应按指针槽中的结构体 owner/alias/写回生命周期处理。

## 当前观察

- `VEC_PUSH glyphs, value, 248` 和 `VEC_PUSH source_map, value, 160` 只证明元素步长正确；`/home/vscode/.sa/std/alloc/vec.sa` 的 `sa_vec_push` 实际执行 `store write_ptr+0, value as u64`。
- 失败断言集中在 `staff_index`、`staff_line`、`measure_index`、`beam_group`、`glyph_system_index` 等结构体字段。
- 直接把 `Vec<T>` 元素当 inline struct slot 投影字段是错误方向，会把指针低位或槽内容当字段值读取，并破坏 `midi.tracks[0].program` 等已通过用例。
- `let glyph = glyphs[i]; glyph.field = ...; glyphs[i] = glyph;` 这类取出、修改、写回模式仍可能触发错误的 owner/alias 状态，导致读回默认值或错误值。
- 对 `midi.tracks[0].notes` 这类字段 Vec 链路，不能把字段中的 Vec 指针按 owner 释放；否则后续字段访问会段错误。
- `assume_borrow` 不能用于普通函数，SA verifier 会报 `IllegalUnsafeContext`。

## 需要修复

为 SA-text codegen 设计一个正式的 Vec 指针槽结构体元素访问/写回计划：

- `vec[i].field` 应先从元素槽加载结构体 owner 指针，再投影到该结构体字段地址；不能把元素槽本身当结构体地址。
- `let x = vec[i]` / `push(vec[i])` 若需要值语义，应有明确的复制/移动计划，不能浅复制 owned 字段后由临时清理误释放原容器内容。
- `vec[i] = x` 应明确写回的是结构体 owner 指针，并正确结束临时值生命周期，不能把仍需由 Vec 持有的 owner 提前释放或标记为已移动后再读。
- 字段 Vec 接收者应作为非 owning view 使用，不能用普通 `!` 释放底层 Vec。

回归目标：

```sh
zig build local-cli -- sla test /home/vscode/projects/sla_music_cli/src/music_ir.sla --test-backend sa --jobs 1 --trace-panic
```

## 2026-07-16 Update

当前编译器已通过后续 Vec 指针槽和字段生命周期修复覆盖该 surface：

- `tests/test_unit_vec_index_assign.sla` 覆盖 `Vec<struct>` 指针槽读取、动态索引 borrow/swap、以及 Vec 元素 local 的重复 scalar field 读取。
- `tests/test_unit_vec_index_field_assign.sla` 覆盖 `vec[i].field = value` 写回结构体 owner 后可读回。
- `tests/test_unit_field_assign_move_cleanup.sla` 覆盖含 `Vec` 字段的结构体 scalar field assignment cleanup。
- `src/codegen.zig` 的 SA-text Vec index read/write 路径现在把 Vec slot 当 owner pointer slot 处理，而不是把 slot 本身当 inline struct 地址。

复验命令：

```sh
timeout 300s env SA_PLUGIN_DEV=1 \
  sa sla test src/music_ir.sla --test-backend sa --jobs 1 --trace-panic
```

在 `/home/vscode/projects/sla_music_cli` 结果：`26 passed; 0 failed; 0 skipped`。

本 issue 作为 stale open issue 关闭。未运行全量测试。
