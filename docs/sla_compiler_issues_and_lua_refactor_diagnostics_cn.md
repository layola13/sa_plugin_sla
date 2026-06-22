# SLA 编译器与 Lua 重构遇到问题及怀疑点详细总结文档

## 一、 核心问题与怀疑点汇总

### 1. SLA 编译器的宏体（Macro Body）解析上下文逃逸 Bug 【优先级最高】
* **表现现象**：在编译大文件（如 `lua_sla.sa`，展开后达 27,664 行）时，经常会遇到 `error[ForbiddenSyntax]: MacroExpansionBudget`（超过 10,000,000 条指令预算限制），并且 flattener 打印的调试日志中行号会周期性地向前回跳（例如 `16396` -> `16139` -> `16928` -> `16692`）。
* **技术根源分析**：
  在 `sci/src/flattener.zig` 中，宏体解析获取行切片的逻辑如下：
  ```zig
  fn macroDefBodyLines(def: *const MacroDef, lines: []const SourceLine) []const SourceLine {
      if (def.owned_body_lines.len != 0) return def.owned_body_lines;
      return lines[def.body_start..def.body_end];
  }
  ```
  以及当宏被调用展开时：
  ```zig
  const def = macros.get(macro_name) orelse return error.InvalidMacroInvocation;
  const body_lines = macroDefBodyLines(&def, lines);
  ```
  * **问题在于**：`lines` 参数是**当前正在被 emit 的文件行列表**。当宏在别的引入文件（例如通过 `@import` 引入的标准库或其它 `.sa` 文件）中被定义，它的 `def.body_start` 和 `def.body_end` 记录的是定义该宏的**原始文件**行索引。
  * 如果 `owned_body_lines` 未能成功拷贝或为空，该函数就会退化为使用原始文件索引去切片当前完全不同文件的 `lines`，导致取到了垃圾数据或错误的代码行（其中可能恰好包含其它宏定义或 `#rep` 段），从而形成无限递归和行号乱跳转。
* **怀疑点与解决方案**：
  * 应当强制在所有宏定义收集时（包括本地定义和反序列化加载）对宏的 `owned_body_lines` 进行深拷贝，杜绝回退到使用 `lines[def.body_start..def.body_end]` 的危险逻辑。

---

### 2. SLA 编译器对跨模块 `@import` 生成路径相对化错误
* **表现现象**：编译 `src/lua.sla` 并输出到根目录 `lua_sla.sa` 时，会遇到 `PackageNotResolved` 错误，导致编译无法继续。
* **技术根源分析**：
  * 处于 `sa_lua/src/lua.sla` 里的代码使用 `@import "lobject.sla"` 导入同目录文件。
  * SLA 编译器在将其输出为根目录的 `lua_sla.sa` 时，直接将 `@import "lobject.sla"` 翻译成了 `@import "lobject.sa"`，而不是根据其相对于 `lua_sla.sa` 的真实位置翻译成 `@import "src/lobject.sa"`。
  * 当 SA 编译器在此处被调用编译根目录的 `lua_sla.sa` 时，由于根目录下没有 `lobject.sa`（它们都在 `src/` 目录下），导致相对路径寻址失败，进而报出 `PackageNotResolved` 错误。
* **解决方案**：
  * 在 SLA 编译器的 Codegen 阶段生成 `genImportDecl` 时，应计算被引用的源文件相对于**最终输出的 `.sa` 文件**的相对路径，而不是粗暴地直接替换扩展名。

---

### 3. SA 编译器因 `PackageNotResolved` 导致的内存双重释放段错误（Segfault）
* **表现现象**：一旦依赖查找抛出 `PackageNotResolved` 错误，`sa` 编译进程会直接崩溃闪退（退出码 `139`）。
* **技术根源分析**：
  * 在 `sci/src/cli.zig` 的 `hashResolvedSourceTreeUncached` 中：
    ```zig
    const real_source_path = try std.fs.cwd().realpathAlloc(allocator, source_path);
    errdefer allocator.free(real_source_path); // 注册了全函数有效的 errdefer
    ...
    try files.append(.{ .path = real_source_path, ... }); // 已经将所有权移交给 files 列表
    ```
  * 如果函数在随后的递归或依赖解析中发生任何错误（如 `PackageNotResolved`），`errdefer` 会释放掉 `real_source_path`。而在函数退出后，caller 的 `defer` 依然会对 `files` 内的每个条目的 `path` 进行释放，导致 **Double Free**。
* **解决方案**：
  * 现已打上防双重释放补丁，增加了所有权移交标志变量 `owned_by_files`，在移交完毕后将状态置为 `true`，防止错误发生时二次释放，段错误现已修复。

---

### 4. 单元测试“空跑”假阳性问题
* **表现现象**：当前 `sa_lua/run_lua_tests.sh` 单元测试脚本打印“测试通过”，但实际上没有覆盖任何 Lua 功能。
* **技术根源分析**：
  * `sa_lua/src/lua.sla` 中的 `main` 函数仅仅进行了文件读取并打印 `Loaded script of length` 字节大小，未实现真正的虚拟机解析和执行跳转。
* **解决方案**：
  * 必须在 `main.sa` / `lua.sla` 中打通 Lua 解析与执行入口。

---

## 二、 后续开发计划与改进建议

### 1. 优先重构 SLA 编译器（避免 All-in-One 并入单文件）
* **原理**：目前将所有的 `.sla` 一股脑地合并成一个巨大的 `lua_sla.sa` 极其容易把编译器撑爆。
* **方案**：建议把每一份 `.sla` 生成为一个独立的 `.sa`，然后使用 `@import` 链接。由于 `sa` 目前采用局部静态检验以及模块级符号查找，单独的模块编译能极大减轻内联与单态化时的内存与计算压力。

### 2. 引入精确测试超时保护
* **方案**：在跑测真实的 `.lua` 测试文件时，在测试脚本中引入 `timeout 30` 限制。由于单个单元测试在无死循环时会在毫秒级内完成，若发现耗时超过 30 秒，即判定发生了死循环并自动中断输出，从而防止跑测挂起。

