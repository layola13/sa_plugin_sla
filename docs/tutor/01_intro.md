# SLA 语言简介与核心设计哲学

Sla (Safe Linear Language) 是专为 **Safe ASM (SA)** 平台设计的高级、静态类型、零开销、无垃圾回收 (GC) 的脚本语言。它作为 SA 汇编的高级前端，旨在在保障极高运行时效率的同时，极大提升开发者的生产力。

---

## 1. 与 Safe ASM (SA) 的关系

Safe ASM (SA) 提供了严格的仿射/线性类型系统以及内存安全性校验，但其底层的指令集相对繁琐。在 SA 中，开发者需要手动管理寄存器释放 (`!reg`)，并在控制流分支合并时通过复杂的 Phi 节点解析确保寄存器状态的一致性。这种手动的寄存器释放和 Phi 状态平衡十分容易出错，甚至导致 `PhiStateConflict` 或 `MemoryLeak` 崩溃。

**Sla** 作为高级编译器语言，完美解决了这一痛点：
1. **自动生命周期管理**：Sla 在编译期根据 AST 自动分析所有局部变量的活跃范围，在变量不再被使用或超出作用域时，**自动注入** SA 的释放指令 (`!reg`)。
2. **自动分支 Phi 解决**：当遇到 `if/else` 或 `switch/match` 等分支逻辑时，Sla 编译器在前端计算各个分支的寄存器活跃掩码差异，并在合并点 (Merge Point) 自动为未消费的寄存器产生释放指令，消除了 Phi 状态冲突的安全隐患。
3. ** transpile 降低为 SA**：Sla 源文件 (`.sla`) 经由编译器前端进行词法、语法解析与强类型检查，再被降解为完全合规、类型追踪的 `.sa` 汇编源码，最后交给 SA 校验器 (Referee) 验证并运行。

---

## 2. 核心设计哲学

### A. 静态类型与仿射类型系统 (Affine Type System)
Sla 继承了 SA 的核心内存模型，不支持任意指针算术或无管辖的堆分配。所有的堆资源和复杂对象均受限于“所有权”规则。一个拥有权的值在同一时刻只能有一个所有者，并且默认的赋值与函数传参会导致所有权的“转移” (Move)。这在编译期就杜绝了：
* **悬挂指针 (Dangling Pointers)**
* **双重释放 (Double Free)**
* **数据竞争 (Data Races)**

### B. 无 GC (Garbage Collection) 与零开销
Sla 没有任何运行时垃圾回收器、引用计数扫描线程或隐式内存碎片整理开销。它完全依靠编译期的生存期静态推导，实现精确、预测性极强的即时资源释放。程序运行时的内存分配开销完全等同于手写高效汇编。

### C. 零拷贝集成与 ABI 保持
为了避免为高级语言重写整个标准库生态，Sla 支持**直读 SA 的 ABI 契约文件**：
* **`.sal` 文件直接解析**：Sla 编译器能直接读取 `sa_std` 或第三方插件导出的底层布局契约 (`.sal`)，自动将其翻译为 Sla 的结构体布局偏移。
* **`.sai` 文件直接解析**：Sla 可以直接引入 `.sai` 接口合约文件，使得 SA 底层的 extern 函数能够作为强类型函数直接被 Sla 代码调用。

通过这一机制，Sla 与 SA 底层生态实现了无缝融合，调用标准库接口（如 `Box`, `Vec`, `HashMap`）时没有任何转换损耗，保持了极佳的性能与生态延续性。\n
---

## 4. 编译器 CLI 命令行工具

Sla 作为 SA 环境的插件运行。如果你在开发模式下使用它，可以使用 `SA_PLUGIN_DEV=1` 环境变量前缀；如果是生产环境，则正常使用 `sa` CLI 调取。

Sla 插件提供项目初始化、能力发现、编译、SAB、检查和测试命令：

### A0. 项目初始化与能力发现 (`sa sla init` / `sa sla skills`)
* **初始化项目**：
  ```bash
  SA_PLUGIN_DEV=1 sa sla init /tmp/sla_app
  ```
  该命令创建 `sa.mod`、`src/main.sla` 和 `.gitignore`，其中 `.gitignore` 明确包含 `.sla-cache/`，供托管 SAB 和后续增量编译输入使用。
* **查看 SLA 插件能力**：
  ```bash
  SA_PLUGIN_DEV=1 sa sla skills --json
  ```
  不带 `--json` 时，命令会在当前目录写入 `.codex/skills/sla/SKILL.md` 和 `.claude/skills/sla/SKILL.md`，行为对齐 `sa skills` 的 agent skill 输出。

### A. 代码编译 (`sa sla build`)
将 `.sla` 源代码文件编译降级为经过类型推导和自动生命周期注入的 `.sa` 汇编文件。
* **基本语法**：
  ```bash
  sa sla build <input_file.sla> [options]
  ```
* **可用选项**：
  * `-o <file>` 或 `--out <file>`：指定输出的 `.sa` 文件物理路径。如果未指定，默认将输入路径中的 `.sla` 后缀名直接替换为 `.sa` 输出。
* **使用示例**：
  ```bash
  # 编译 main.sla 并默认输出为 main.sa
  SA_PLUGIN_DEV=1 sa sla build demos/rosetta/13_array_sum/main.sla
  
  # 编译并显式指定输出到临时目录
  SA_PLUGIN_DEV=1 sa sla build tests/test_unit_basic.sla --out /tmp/basic_output.sa
  ```

### B. 可执行文件构建 (`sa sla build-exe`)
将 `.sla` 源文件一步编译为本地可执行文件。当前实现默认走直接 SAB 主线：插件从 SLA AST/type-checker 结果生成 SAB bytes，写入稳定托管路径 `.sla-cache/sab/...`，再调用底层 `sa build-exe <managed.sab>`。这不是 `sla -> sa -> sab`，也不会在源码旁默认生成 `.sa` 或 `.sab`。
* **基本语法**：
  ```bash
  sa sla build-exe <input_file.sla> [sa build-exe options]
  ```
* **额外参数传递**：
  `.sla` 文件后面的参数会原样传给底层 `sa build-exe`，例如 `-o <file>`、`-g`、`--no-incremental`。
* **SAB 检查产物**：
  如需保留一份源码旁 `.sab` 供检查，可传 `--emit-sab`。默认 `.sla-cache/sab/...` 托管文件会保留，用于后续增量编译复用。
* **使用示例**：
  ```bash
  SA_PLUGIN_DEV=1 sa sla build-exe tests/test_unit_field_array_cleanup.sla -o /tmp/field_array_cleanup
  ```

### B2. SAB 二进制构建 (`sa sla sab` / `sa slab`)
SAB 是 SA 的二进制 IR。SLA 的 SAB 主线直接输出 SAB，不经过 `.sa` 文本。
* **生成托管 SAB**：
  ```bash
  SA_PLUGIN_DEV=1 sa sla sab build tests/test_sab_direct.sla
  ```
  默认输出到 `.sla-cache/sab/<name>-<hash>.sab`，不在源码旁落盘。
* **额外写出 SAB 文件**：
  ```bash
  SA_PLUGIN_DEV=1 sa sla sab build tests/test_sab_direct.sla --out /tmp/test_sab_direct.sab
  ```
* **workspace 构建**：
  ```bash
  SA_PLUGIN_DEV=1 sa sla sab workspace -p app --sab-out /tmp/app.sab -o /tmp/app
  ```
  workspace 模式解析当前 `sa.mod`，选中默认 member 或 `-p/--package` 指定 member，使用 `.sla-cache/sab/...` 作为 `sa build-exe` 的稳定输入路径。`--sab-out` 只额外写出一份可检查的 SAB 文件。
* **反汇编调试**：
  ```bash
  SA_PLUGIN_DEV=1 sa sla sab disasm /tmp/test_sab_direct.sab --out /tmp/test_sab_direct.sa
  ```
  反汇编只用于查看，不参与编译主链路。

### C. 语法与强类型检查 (`sa sla check`)
仅对 `.sla` 源文件进行词法分析、语法解析、单态化展开与静态类型检查，以验证其语法正确性，**不生成**任何物理 `.sa` 汇编代码，用于快速语法纠错。
* **基本语法**：
  ```bash
  sa sla check <input_file.sla>
  ```
* **使用示例**：
  ```bash
  SA_PLUGIN_DEV=1 sa sla check tests/test_unit_basic.sla
  ```

### D. 单元测试运行器 (`sa sla test`)
用于编译和执行定义了 `@test` 块的测试代码。
Sla 编译器默认会把该 `.sla` 文件编译为托管 SAB `.sla-cache/sab/...`，接着在底层调用 `sa test <managed.sab>` 执行所有未忽略的测试块，并展示最终的通过状态。只有显式传 `--test-backend sa` 时才会使用旧的 `<input_file>.test.sa` 文本测试后端。
* **基本语法**：
  ```bash
  sa sla test <input_file.sla> [extra_args]
  ```
* **额外参数传递**：
  你可以在命令后面附加任何底层 `sa test` 工具支持的参数。例如 `--include-ignored` 可以让跳过的 `@test ignored` 测试也被强制加入执行。
* **使用示例**：
  ```bash
  # 执行基础单元测试
  SA_PLUGIN_DEV=1 sa sla test tests/test_unit_basic.sla
  
  # 执行测试并强制包含被标记为忽略的测试块
  SA_PLUGIN_DEV=1 sa sla test tests/test_unit_basic.sla --include-ignored
  ```
