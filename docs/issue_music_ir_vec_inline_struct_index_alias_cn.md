# issue: SA-text Vec 内联结构体索引字段访问仍按指针槽语义读取

状态：open

## 现象

`/home/vscode/projects/sla_music_cli/src/music_ir.sla` 在 SA-text 后端仍有 `music_ir` 布局相关测试失败。已确认 `Vec<StaffLayoutGlyph>` / `Vec<SourceMapIrMapping>` 的 `VEC_PUSH` 步长可生成真实结构体大小，但 `vec[i].field` 的读取路径仍可能把 inline struct slot 当成 `ptr` 槽处理，导致字段读回默认值或错误值。

## 当前观察

- `VEC_PUSH glyphs, value, 248` 和 `VEC_PUSH source_map, value, 160` 已生成正确元素步长。
- 失败断言集中在 `staff_index`、`staff_line`、`measure_index`、`beam_group`、`glyph_system_index` 等结构体字段。
- 直接把 `Vec<T>` inline 元素索引读改为返回 slot 地址会和现有 owning 临时清理冲突。
- 对 `midi.tracks[0].notes` 这类字段 Vec 链路，不能把字段中的 Vec 指针按 owner 释放；否则后续字段访问会段错误。
- `assume_borrow` 不能用于普通函数，SA verifier 会报 `IllegalUnsafeContext`。

## 需要修复

为 SA-text codegen 设计一个正式的 Vec inline aggregate element projection：

- `vec[i].field` 应直接投影到 inline element slot 的字段地址，不创建 owning struct 临时值。
- `let x = vec[i]` / `push(vec[i])` 若需要值语义，应有明确的复制/移动计划，不能浅复制 owned 字段后由临时清理误释放原容器内容。
- 字段 Vec 接收者应作为非 owning view 使用，不能用普通 `!` 释放底层 Vec。

回归目标：

```sh
zig build local-cli -- sla test /home/vscode/projects/sla_music_cli/src/music_ir.sla --test-backend sa --jobs 1 --trace-panic
```
