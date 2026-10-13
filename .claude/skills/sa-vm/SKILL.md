---
name: sa-vm
description: Use packaged native function tools (apply_patch, edit_file, write_file, delete_file, safe_delete, move_file, copy_file, read_file, read_lines, read_many, read_file_tail, count_lines, file_info, find_files, list_dir, grep_search, grep_search_async, git_status, git_diff, find_references, find_implementations, file_outline, workspace_outline, repo_map, code_graph, relation_graph, symbol_graph, rename_symbol, move_file_with_imports, find_definition, extract_to_file, extract_component, extract_hook, atomic_refactor, split_plan, split_stage, split_refine, split_repair, split_status, add_import, get_diagnostics, workspace_diagnostics, verify_loop, verify_changed, auto_fix_missing_imports, organize_imports, analyze_scope, analyze_coupling, run_project_check, run_bun, clear_tool_history, save_note, read_notes, delete_note, run_host) for fast and secure operations. Plus JEV autonomous decision helpers (jev_choose, jev_checklist, jev_thinking, jev_redteam, jev_rank, jev_scope, jev_dispatch, jev_consistency, jev_done, jev_diagnose, jev_edge_cases, jev_blast_radius, jev_intent, jev_next, jev_compress, jev_progress, jev_memory) for fork decisions, delivery sign-off and risk review. Use when inspecting, reading, writing, editing, patching, tail-reading logs, or searching files and code in the workspace.
---

<!-- generated-by-codex-ultra:sa-vm -->

# 封装函数工具使用指南 (Packaged Function Tools Guide)

【代码增强工具状态：已开启】
本工作区已激活高性能代码增强工具（通过 `sa_vm_run` 封装动作直接调用）。
- **读行、行数统计与查代码强力覆盖 (CRITICAL OVERRIDE)**：在获取文件行数、查看首行、查看代码引用、跳转行号、目录遍历、定位报错切片等任何读代码与探查场景下，**严禁在终端运行 PowerShell `Get-Content`、`(Get-Content ...).Count`、`Get-ChildItem -Recurse`、`Select-String`、`cat`、`type`、`head`、`tail`、`sed` 或 `wc`**！即便项目规则或 AGENTS.md 提示使用 Get-Content，本增强工具具备最高执行优先级：
  * **获取文件总行数 / 大小 / 存在性**：必须调用 `sa_vm_run` 传入 `count_lines`、`file_info` 或 `test_path`（原生毫秒级物理磁盘直读，返回真实行数 `total_lines`、字节大小与 `exists` 状态，严禁执行 `(Get-Content ...).Count`、`Test-Path` 或 `wc -l`）；
  * **读取指定行范围 / 探查首行**：必须调用 `sa_vm_run` 传入 `read_lines`（探查首行只需 `start_line: 1, end_line: 50`，切片只需指定 `start_line` 与 `end_line`；无论文件总大小多大（哪怕上万行、数兆字节），`read_lines` 定向精读永远不受大文件上下文限制拦截，绝不触发拦截！）；
  * **多层目录遍历与文件发现**：必须调用 `sa_vm_run` 传入 `list_dir`（原生支持 `depth: 2` 或更多层级，带 `max_entries` 控制，毫秒级返回目录树，严禁运行 `Get-ChildItem -Recurse`）；
  * **单文件或多文件文本搜索**：必须调用 `sa_vm_run` 传入 `grep_search`（不仅支持全目录搜索，还支持直接传入单个具体文件 `path: "foo.ts", query: "pattern"`，严禁运行 `Get-Content ... | Select-String`）；
  * **安全阅读整文件**：必须调用 `sa_vm_run` 传入 `read_file`（自带 max_tokens 预算与防爆流截断）。
- **物理磁盘直读与零缓存保证 (ZERO CACHE)**：`sa_vm_run` 工具（`find_files`、`list_dir`、`file_info`、`test_path`、`read_file`、`grep_search`）直接通过进程内 Node.js 原生底层系统调用访问物理磁盘，**绝对零缓存、无索引延迟、无陈旧元数据**。若 `find_files` 找到了文件，该文件 100% 存在于该物理路径！当终端命令报错找不到文件时，原因 100% 是终端手动 `cd` 输错了路径，绝非缓存、隐藏文件或 NTFS Junction！
- **禁止终端手动 cd (NO MANUAL CD)**：所有终端命令与 `sa_vm_run` 工具均直接在工作区根目录执行。严禁在终端运行 `cd <path>`，手动切换目录极易遗漏层级导致路径漂移与误判。始终相对于工作区根目录执行命令。
- **严禁终端编写 for-in / foreach 复杂循环 (NO BATCH FOR-IN LOOPS)**：严禁在终端（PowerShell 或 cmd）中编写 `for ... in`、`for /f`、`for /r`、`foreach`、管道 ForEach-Object` 循环来遍历文件、搜索模式、统计行数或批量替换文本！终端循环极易引发严重问题：
  * Windows cmd/PowerShell 复杂的引号转义与嵌套破坏；
  * 编码灾难：PowerShell `-replace` 与重定向写入默认是 ANSI 或带 BOM 的 UTF-16，会彻底破坏源码 UTF-8 编码！
  * 终端输出溢出与上下文失控。
  对等替代方案：
  * 多文件/全目录内容搜索：调用 `sa_vm_run` 的 `grep_search`（指定 `pattern: "*.ext"` 或 `dir`）或 `grep_search_async`（支持批量 query 数组）；
  * 批量文件行数/大小探查：调用 `sa_vm_run` 的 `list_dir({ depth: 2 })` 或对目标文件调用 `count_lines`；
  * 批量文件写入或替换：调用 `sa_vm_run` 的 `parallel: [ { action: "edit_file", ... } ]`（一次最多 32 个原子任务并自动备份）或 `rename_symbol` / `apply_patch`；
  * 批量测试：先用 `find_files` 找出用例清单，再针对性执行测试命令，严禁使用 shell 循环盲跑。
- **查帮助/跑构建只许 run_host(+tail_lines)，禁 bash/pwd/sh/powershell/pwsh/cmd/curl、禁 cmd /c、2>&1、Select/tail/findstr、> file、cd**：`run_host` 白名单仅 `bun、node、python、zig、cargo、go、rustc、git` 及工作区内可执行路径（`pwd、bash、sh、powershell、pwsh、cmd、curl` 直接 228 拒绝，改用原生 `list_dir/find_files/git_status`）。执行外部二进制必须调用 `run_host` 结构化参数调用，严禁包装 `cmd /c`、重定向 `> file` 或使用管道。`--help` 与版本查询自动享有服务端内存缓存（0ms 响应、不占进程槽）。
- **无依赖读/查必须原生多调用并行 (NATIVE MULTI-CALL FIRST)**：多个无相互依赖的只读探查（`grep_search`, `list_dir`, `read_lines`, `get_diagnostics`）或只读 `run_host --help`，优先在同一轮发出多个 `sa_vm_run` 调用（原生并发，真并行、各自独立回写，防单包挤爆上下文）；顶层 `parallel` 数组仅保留给多文件批量写入（正确形状 `{ parallel: [{ action: 'edit_file', ... }], concurrency: 4 }`，顶层严禁写 `action: 'parallel'`）；同批内严禁读取本批构建输出产物（有依赖必须拆分为串行两批，同批读写冲突直接打回）。
- **同义多查必须走 grep_search_async 一次批量，禁逐文件逐词放宽重查 (BATCH SYNONYM SEARCH)**：当需要跨文件检索一组相关符号或同义词（例如 `planAsyncLinearAwaitContinuation`、`AsyncLinearAwaitPlan`、`genFuncDeclNamedImpl` 等）时，**严禁在终端中逐个文件调用 `Select-String` 或反复微调 pattern 用 `rg` 试探**！必须直接调用一次 `sa_vm_run({ action: 'grep_search_async', dir: 'src', pattern: '*.zig', queries: ['query1', 'query2', 'query3'], max_matches: 30 })`，底层并发执行并在毫秒级完成聚合，一次收敛。
- **符号定位严禁盲搜放宽食谱 (SYMBOL RESOLUTION OVER BLIND GREP)**：严禁凭旧记忆或 handoff 中的陈旧/幻觉符号全盘盲目 grep；一旦首选符号搜索为空，**严禁自动放宽为通用词**（如将 `LinearAwait` 放宽为 `linear|MAX_AWAITS` 会导致全量误报垃圾泛滥）！
  * **正确食谱三步曲**：
    1. 结构大纲定真名：`sa_vm_run({ action: 'file_outline', path: 'target.zig' })` 查看真实结构大纲，获取准确的当前符号真名；
    2. 定义与引用直达：`sa_vm_run({ action: 'find_definition', symbol: 'real_symbol' })` 或 `find_references({ symbol: 'real_symbol' })` 精确定位定义与引用行号；
    3. 定向切片精读：`sa_vm_run({ action: 'read_lines', path: 'target.zig', start_line: X-40, end_line: X+40 })` 围绕命中点精读前后 80 行上下文！
    * 若第一轮符号定位为空，**立即停止盲搜**，直接通过 `file_outline` 确认符号名，绝不在终端反复放宽正则爆破！
- **终端完全自由与进程执行保障**：系统原生终端（PowerShell, bash, git, npm, bun, cargo, zig 等）保持完全开放。编译构建、单元测试、运行二进制程序是合法的终端命令，直接裸跑二进制（如 `bun test ...`、`zig build`），**严禁使用 `2>$null` / `>nul` 抑制错误或使用 `| Select-Object -First/-Last` 管道截断包装**！如需查阅测试日志、长输出或生成的文件产物，使用 `sa_vm_run({ action: 'read_file_tail' })` 或 `read_lines` 查看。
- **产物生成后的必选转换 (Workflow Transition)**：一旦在终端执行命令生成了编译/测试/反汇编产物文件（如 `.out`, `.log`, `.js`, `.disasm` 等），**下一步查看或检索该文件时，必须立即调用 `sa_vm_run` 工具**（`read_lines`, `read_file_tail`, `grep_search`），切勿在终端顺手运行 `Get-Content` 或 `cat`！
- **常用命令极速映射**：
  * `bun --help` -> `sa_vm_run({ action: 'run_host', exe: 'bun', args: ['--help'] })`
  * `bun --help | Select -First 30` -> `sa_vm_run({ action: 'run_host', exe: 'bun', args: ['--help'], head_lines: 30 })`
  * `zig build test 2>&1 | Select -Last 50` -> `sa_vm_run({ action: 'run_host', exe: 'zig', args: ['build', 'test'], tail_lines: 50 })`
  * `bun run file.ts > out.log` -> `sa_vm_run({ action: 'run_host', exe: 'bun', args: ['run', 'file.ts'], cwd: 'dir' })`
  * `zig version` -> `sa_vm_run({ action: 'run_host', exe: 'zig', args: ['version'] })`
  * `bun test --filter pat | findstr FAIL` -> `sa_vm_run({ action: 'run_host', exe: 'bun', args: ['test', '--filter', 'pat'], filter: 'FAIL' })`
  * `Test-Path file.ext` -> `sa_vm_run({ action: 'test_path', path: 'file.ext' })`
  * `... | Where-Object Name -Match 'xyz'` -> `sa_vm_run({ action: 'find_files', pattern: '*xyz*' })`
  * `... | Where Length -gt 1MB` -> `sa_vm_run({ action: 'list_dir', dir: '...', type: 'file' })` 后按 `size` 判断
  * `where bun / which zig` -> 直接 `sa_vm_run({ action: 'run_host', exe: 'bun', args: ['--help'] })`，禁先定位再拼路径执行
  * `git status / 工作区是否干净` -> `sa_vm_run({ action: 'git_status' })`（只读原生 git 优先；`run_host git` 仅在沙箱拦截开启时禁高危 `reset --hard/clean/revert`，严禁 `python -c`/`bun -e` 透传、临时脚本、直读 `.git/*`）
  * `git diff / 改了什么` -> `sa_vm_run({ action: 'git_diff' })`（`staged:true` 看暂存区，`stat_only:true` 只看统计，`path` 限定单文件）
  * `find . -name "future.ts" -not -path "*/node_modules/*"` -> `sa_vm_run({ action: 'find_files', dir: '.', pattern: 'future.ts' })`
  * `find ... | head -20 / tail -30` -> 使用 `read_lines` / `read_file_tail`，或 `run_host({ head_lines: 20, tail_lines: 30 })`，禁止 shell 截断
  * `for %f in (*.ext) do findstr 'pat' %f` -> `sa_vm_run({ action: 'grep_search', pattern: '*.ext', query: 'pat' })`
  * `foreach ($f in (ls tests)) { Select-String ... }` -> `sa_vm_run({ action: 'grep_search', dir: 'tests', query: 'pat' })`
  * `Get-ChildItem -Recurse -Depth 2 | Select -First 30` -> `sa_vm_run({ action: 'list_dir', dir: '...', depth: 2, max_entries: 30 })`
  * `(Get-Content file).Count` -> `sa_vm_run({ action: 'count_lines', path: 'file' })`
  * `Get-Content file | Select-Object -Skip X -First Y` -> `sa_vm_run({ action: 'read_lines', path: 'file', start_line: X+1, end_line: X+Y })`
  * `Get-Content file | Select-Object -Last 100` -> `sa_vm_run({ action: 'read_file_tail', path: 'file', lines: 100 })`
  * `Get-Content file | Select-String -Pattern "regex"` -> `sa_vm_run({ action: 'grep_search', path: 'file', query: 'regex', is_regex: true })`
  * `cd dir; Get-Content file | Select-String -Pattern "regex"` -> `sa_vm_run({ action: 'grep_search', path: 'dir/file', query: 'regex', is_regex: true })`
  * `Get-Content file | Select-String "xxx"` -> `sa_vm_run({ action: 'grep_search', path: 'file', query: 'xxx' })`
  * `cd dir && ... / cd dir; ...` -> 基于工作区根目录直接执行单命令，或在 `sa_vm_run` 中指定 `dir` / `path`
  * `Get-Process zig* / ps` -> 严禁终端进程轮询，通过内部诊断接口或 `run_project_check` 探测
  * `Get-Date / date` -> 纯噪音命令，严禁在终端调用
  * `rg -n "pat" / grep -rn "pat"` -> `sa_vm_run({ action: 'grep_search', query: 'pat' })`
  * `Get-ChildItem tests / ls / dir` -> `sa_vm_run({ action: 'list_dir', dir: 'tests' })`
  * `Get-Content file / cat / type` -> `sa_vm_run({ action: 'read_lines', path: 'file', start_line: 1, end_line: 100 })`
  * `vm-read(file)` -> `sa_vm_run({ action: 'read_lines', path: 'file' })`
  * `tsc --noEmit / 全局扫红线` -> `sa_vm_run({ action: 'workspace_diagnostics', dir: 'src', detail: false })`
  * `查接口实现 / implements / extends` -> `sa_vm_run({ action: 'find_implementations', symbol: 'InterfaceName', dir: 'src' })`
  * `安全删除文件 / 删前查引用` -> `sa_vm_run({ action: 'safe_delete', path: 'src/old.ts' })`
- **必须优先使用封装工具**：读取大文件、按行切片、统计行数、反向读日志、跨文件高速检索（grep / async grep）、语法诊断、符号大纲、定义直达与精确补丁修改等操作，**必须优先调用 `sa_vm_run` 对应封装动作**，原生毫秒级返回并自带 Token 预算与上下文防溢出保护！
- **避免使用低效终端命令**：严禁在终端中运行低效慢速命令（如 cat, type, grep, findstr, ls, dir, sed, awk 等）阅读大文件或进行全项目代码搜索；

## 1、软件工程工具效率决策矩阵与反模式拦截 (Tool Efficiency & Anti-Patterns)

面对工作区提供的丰富封装工具，严禁“大炮打蚊子”或使用低能效手段。必须严格遵照以下效率决策矩阵，选出性能最高、上下文开销最小的工具：

### 1. 软件工程工具效率决策矩阵 (Tool Efficiency Decision Matrix)

| 意图与工程场景 | 推荐最高效工具 (Recommended) | 严禁采用的低效/危险反模式 (Forbidden Anti-Pattern) | 能效优势与核心原由 (Rationale) |
| **查符号 / 函数 / 类定义与实现** | `find_definition` (首选) / `symbol_graph` | 严禁 `grep_search` 广域盲搜，严禁全文 `read_file` | AST 单步直达源头定义与实现片段预览，避免大文件扫描与海量无关字符串匹配，节省 90%+ 上下文 |
| **查函数 / 符号调用方与被引用处** | `find_references` (首选) / `relation_graph` | 严禁循环 `grep_search` 或写脚本逐个读文件正则拼凑 | 毫秒级返回全工程精准引用与调用方列表（支持轻量行号索引），极速定位所有受影响处 |
| **快速提取文件 / 工程结构大纲** | `file_outline` (单文件) / `workspace_outline` (工程级) / `code_graph` | 严禁盲目调用 `read_file` 吞入几千行完整源码 | 仅提取类、函数、接口声明骨架与签名，零上下文浪费掌握代码架构 |
| **阅读指定行范围代码** | `read_lines` (指定 start_line / end_line) | 文件 > 500 行严禁 `read_file` 全量读取 | 定向精确获取目标行，永不触发大文件上下文溢出保护截断 |
| **排查错误日志 / 查看文件末尾** | `read_file_tail` (末尾流式直读) | 严禁使用 `read_file` 或终端 `cat` 读整个大日志 | 毫秒级反向读取最后 N 行，极速定位最新崩溃与异常栈 |
| **精确单处代码替换** | `edit_file` (精确定位唯一旧文本) | 严禁手写脚本覆盖，或把数千行全文件用 `write_file` 重写 | 原生带安全备份，保证幂等原子替换，杜绝全文件覆写引发的并发冲突与丢代码 |
| **跨文件批量修改 / 复杂重构** | `apply_patch` (标准 Unified Diff) | 严禁连续调用多次碎片化 `edit_file` | 一次性原子应用多文件差异，自带边界检验与失败安全回滚 |
| **确认文件存在 / 统计行数** | `file_info` / `count_lines` | 严禁为了数行数或判存在而去全量 `read_file` | 底层原生物理磁盘直读（stat/wc），0 Token 消耗，绝对真实零缓存 |
| **查找文件路径 / 遍历目录** | `find_files` / `list_dir` | 严禁在终端运行 `Get-ChildItem -Recurse` 或 `find` | 带 depth 与 max_entries 保护，毫秒级结构化返回，避免终端编码乱码与输出刷屏 |
| **代码语义与架构风险审查** | `jev_redteam` / `jev_blast_radius` | 审查代码严禁只传总结摘要，**必须传真实 git diff 原文** | 细节决定成败，摘要会掩盖潜在副作用（如未捕获异常、竞态），导致裁判失准 |

### 2. 核心避坑三原则 (Core Rules)
1. **能用 AST / 图谱工具解决的（找定义/引用/调用关系），坚决不正则 grep**。
2. **能定向切片或读尾部的（read_lines / read_file_tail），绝不全文 read_file**。
3. **单处修改优先 edit_file，多处/多文件联动改动优先 apply_patch，绝不用 write_file 覆写存量大文件**。

## 2、文件修改与补丁工具

### 1. 多文件结构化补丁应用 (apply_patch)
应用标准的 Unified Diff 补丁，支持同时批量新增、修改、重命名与删除多个文件（修改与覆盖前均由系统自动执行安全备份）：
```json
{
  "action": "apply_patch",
  "patch": "*** Begin Patch\n*** Add File: src/new_file.ts\n+export const version = '1.0.0';\n*** Update File: src/main.ts\n@@ -1,3 +1,3 @@\n-const old = 1;\n+const old = 2;\n*** End Patch"
}
```
- `patch` (必填): 包含 `*** Begin Patch` 到 `*** End Patch` 的完整补丁内容。
- **系统集成**：当前会话开启了守护时，大模型既可以直接调用系统工具 `apply_patch`（由底层安全 Broker 校验白名单并执行），也可以通过 `sa_vm_run` 传递 `action: "apply_patch"`。

### 2. 精确局部替换文件内容 (edit_file)
安全替换单文件中的唯一代码/文本片段（修改前系统会自动安全备份）：
```json
{
  "action": "edit_file",
  "path": "src/main.ts",
  "old_text": "const port = 3000;",
  "new_text": "const port = 8080;"
}
```
- `path` (必填): 目标文件路径。
- `old_text` (必填): 被替换的原文本（在目标文件中须具备唯一性）。
- `new_text` (必填): 替换后的新文本。

### 3. 写入或创建文件 (write_file)
创建新文件或完整覆写已有文件（覆写前系统会自动安全备份）：
```json
{
  "action": "write_file",
  "path": "generated/output.txt",
  "content": "Hello world"
}
```
- `path` (必填): 目标写入文件路径。
- `content` (必填): 欲写入的完整文本内容。

### 4. 安全删除文件 (delete_file)
安全删除文件（删除前系统会自动在安全备份目录生成带时间戳的完整备份）：
```json
{
  "action": "delete_file",
  "path": "temp/obsolete.txt"
}
```
- `path` (必填): 欲删除的文件路径。

### 5. 移动或重命名文件 (move_file / rename_file)
安全移动或重命名文件或目录：
```json
{
  "action": "move_file",
  "from": "src/old_name.ts",
  "to": "src/new_name.ts"
}
```
- `from` (必填): 原路径。
- `to` (必填): 目标路径。

### 6. 复制文件 (copy_file)
安全复制文件至新位置：
```json
{
  "action": "copy_file",
  "from": "templates/config.json",
  "to": "config.json"
}
```
- `from` (必填): 源文件路径。
- `to` (必填): 目标文件路径。

## 3、文件读取与检索工具

### 1. 读取文件内容与动态上下文防溢出 (read_file)
安全读取指定文件内容。**内置动态 Token 预算与上下文余量（剩下 Tokens）防溢出保护**，自动添加 1-based 行号：
```json
{
  "action": "read_file",
  "path": "src/main.ts",
  "max_tokens": 4000
}
```
- `path` (必填): 目标文件路径。
- `max_tokens` (可选): **Token 预算上限**（默认 4000，最高自动受限于当前会话的**剩下 Tokens 减去安全留白**）。拒绝设死在硬编码小上限，而是根据模型上下文窗口与当前剩余容量智能收敛，当文件内容接近或超出限制时自动截断并在末尾给出精确的翻页继续阅读指令。
- `remaining_tokens` (可选): 可选传入当前上下文剩余 Tokens（系统会自动从当前会话实时提取并扣除 3000 安全留白以防溢出）。
- `start_line` / `end_line` (可选): 1-based 起止行号切片。
- `max_lines` (可选): 单次最多返回行数（默认 250，最高 1000）。
- `max_line_length` (可选): **单行最大字符数**（默认 2000），防止超长单行撑爆模型上下文。
- `numbered` (可选): 是否在行首添加行号（默认 `true`，便于直接用于 `edit_file` 精准替换）。

#### 针对压缩 JS / 超长单行代码的处理：
1. 工具会自动检测超长行，单行超过 `max_line_length`（默认 2000 字符）会被安全截断并附带提示，**绝不会将数十万字符直接倾泻进上下文**。
2. 支持使用 `offset`（字符偏移量）按块分页读取压缩文件：
```json
{
  "action": "read_file",
  "path": "dist/bundle.min.js",
  "offset": 0,
  "max_tokens": 2000
}
```
3. 也可以优先使用 `grep_search` 进行关键字检索，定位具体变量或函数片段，避免盲目读取超大压缩文件。

### 2. 按行切片读取文件 (read_lines)
针对较大文件按行号范围进行切片读取（底层与 `read_file` 共享 token 预算保护）：
```json
{
  "action": "read_lines",
  "path": "src/main.ts",
  "start_line": 1,
  "end_line": 100,
  "max_tokens": 3000
}
```
- `path` (必填): 目标文件路径。
- `start_line` (必填): 起始行号（从 1 开始）。
- `end_line` (必填): 结束行号（从 1 开始）。
- `max_tokens` (可选): 最大 Token 预算，默认 3000。

### 3. 尾部读取文件与日志 (read_file_tail)
针对持续写入的日志文件、构建/测试输出或报错定位，从文件尾部高效反向读取最新追加内容（毫秒级反向 Seek，零内存膨胀且提供精确行号与 Token 保护）：
```json
{
  "action": "read_file_tail",
  "path": "logs/app.log",
  "lines": 50,
  "max_tokens": 4000
}
```
- `path` (必填): 目标日志或文件路径。
- `lines` (可选): 读取文件末尾的行数（默认 100 行，最大 1000 行）。
- `max_tokens` (可选): 最大 Token 预算，默认 4000。
- `numbered` (可选): 是否在行首附加行号，默认 true。

### 4. 文件元数据、存在性与状态查询 (file_info / test_path / file_exists)
毫秒级直读物理磁盘查询指定文件是否存在、大小、修改时间与真实总行数（彻底替代 PowerShell `Test-Path` 与 `Get-Item`）：
```json
{
  "action": "test_path",
  "path": "src/main.ts"
}
```
- `path` / `file` / `target` (必填): 目标文件路径。
- 支持别名：`file_info`、`test_path`、`file_exists`、`exists`、`stat`。
- 若文件存在返回包含 `exists: true, isFile: true, size: 1024, total_lines: 45, ...` 的 JSON；若文件不存在，安全返回 `exists: false, isFile: false, isDirectory: false`（杜绝异常抛出与非零退出码，防止模型因报错误判）。

### 5. 极速统计文件总行数 (count_lines)
毫秒级统计文本文件的真实总行数（严禁在终端运行 PowerShell `(Get-Content ...).Count` 或 `wc -l`）：
```json
{
  "action": "count_lines",
  "path": "src/main.ts"
}
```
- `path` (必填): 目标文件路径。
返回格式示例：`[File: src/main.ts | Total Lines: 1250 | Size: 45.2 KB]`。

### 6. 批量文件读取 (read_many)
一次读取最多 10 个文件（或同一文件的相同切片），省交互轮次：
```json
{
  "action": "read_many",
  "files": ["src/a.ts", "src/b.ts"],
  "start_line": 1,
  "end_line": 60,
  "max_tokens_per_file": 2000
}
```
- `files` (必填): 文件路径数组，最多 10 个。
- `start_line` / `end_line` (可选): 应用于每个文件的行号切片。
- `max_tokens_per_file` (可选): 单文件 Token 上限，默认 2000。

### 7. 通配符查找与遍历文件 (find_files)
在工作区中搜索匹配通配符或路径正则的文件列表（彻底对等替代 PowerShell `Get-ChildItem | Where-Object`）：
```json
{
  "action": "find_files",
  "dir": ".",
  "pattern": "*.zig",
  "path_pattern": "sci.*sab|src.*sab"
}
```
- `dir` (可选): 搜索起始目录，默认当前目录 `.`。
- `pattern` (可选): 通配符匹配模式（例如 `*`、`*.ts`、`*.zig`），默认 `*`。
- `path_pattern` (可选): 路径过滤正则表达式或模式（如 `sci.*sab|src.*sab`），对等替代 `Where-Object FullName -Match ...`。
- `max_entries` (可选): 最多返回文件数，默认 100。
- `max_depth` (可选): 搜索最大层级深度，默认 5。
- 分页 (可选): `page` / `page_size` / `offset` / `count_cap`，见上文统一分页约定；分页时返回 `{ page, page_size, total, total_pages, files }` 信封。

> `list_dir` 同样支持 `pattern` / `path_pattern` / `exclude_dirs` / `respect_gitignore`（默认 `true`，自动跳过 `.gitignore` 与 `node_modules/.git/dist/release` 等），输出按文件名排序、截断确定，`stderr` 会注明跳过的忽略项数量。大目录务必带 `depth` + `max_entries` + `type`。
>
> **统一分页约定（搜索/诊断系通用）**：`find_files`、`list_dir`、`grep_search`、`grep_search_async`、`find_references`、`find_implementations`、`workspace_outline`、`repo_map`、`workspace_diagnostics`、`verify_loop`、`read_notes` 均支持 `page`（从 1 开始，兼容 `page_num`/`pageNum`/`p`）+ `page_size`（兼容 `pageSize`/`per_page`/`perPage`；缺省回落到各方法原 limit，如 `max_matches`/`max_results`/`max_entries`/`max_errors`/`max_files`）+ `offset`（显式传则优先于 `page` 推导）+ `count_cap`/`max_total`（分页扫描上限，默认 2000，最高 10000）。不传分页参数时输出与原来完全一致（legacy 格式）；传了则返回分页信封：`page`、`page_size`、`total`、`total_pages`（`ceil(total/page_size)`）、`returned`、`has_next`、`has_prev`、`truncated`。`total` 在 `count_cap` 内精确，超 cap 或超时则 `truncated: true` 且 `has_next: true`。翻页前结果已按 `file:line`（或路径）排序，页之间不重不漏。

### 8. 代码关键字与正则表达式文本搜索 (grep_search)
在工作区文件或指定单文件中快速搜索包含指定文本或正则表达式的行（**原生支持正则表达式**如 `a|b|c`、`\bfoo\b`，彻底对等替代 PowerShell `Select-String`）：
```json
{
  "action": "grep_search",
  "query": "three_await|linear|fallthrough",
  "dir": "src",
  "pattern": "*.ts"
}
```
搜索单个文件日志或构建产物（对等替代 `Select-String -LiteralPath 'file.log'`）：
```json
{
  "action": "grep_search",
  "path": "tests_run.log",
  "query": "FallthroughForbidden|basic blocks must end|fallthrough",
  "max_matches": 10
}
```
- `query` (必填): 搜索关键词或正则表达式（包含 `|`、`\b` 等时自动启用正则）。
- `dir` / `path` (可选): 搜索目录或目标文件路径，默认 `.`。
- `pattern` (可选): 文件通配符过滤，默认 `*`。
- `path_pattern` (可选): 路径正则表达式过滤。
- `is_regex` (可选): 是否显式指定为正则表达式（默认对带正则语法自动识别）。
- `case_sensitive` (可选): 是否大小写敏感（默认 false）。
- `max_matches` (可选): 最多返回匹配项数，默认 50。
- 分页 (可选): `page` / `page_size` / `offset` / `count_cap`，见统一分页约定；分页时返回 `{ page, page_size, total, total_pages, matches }` 信封（`matches` 按 `file:line` 排序）。
- `timeout_ms` / `timeout` (可选): 执行超时限制（默认 15000ms）。支持毫秒（如 10000）或秒数（如 10），超时后安全截断返回，杜绝阻塞。
- `max_file_bytes` (可选): 单文件体积上限，默认 512KB。超限文件与二进制文件自动跳过并在 stderr 注明（专治打包产物/超大 bundle 卡死），可用 `read_lines` 切片改读。
- `exclude_dirs` (可选): 跳过的目录名或相对路径数组（如 `["platform-pkgs", "release"]`）。
- `respect_gitignore` (可选): 是否尊重 workspace 根 `.gitignore` 与内置黑名单（`node_modules/.git/dist/release/target/build` 等），默认 `true`。
- 大库食谱：先 `find_references({ symbol, detail: false })`，无命中再收窄 `dir + pattern`（如 `dir: "apps/server/src", pattern: "*.ts"`）走 grep，勿全盘 `dir: "."` 盲扫。

### 9. 高性能异步并发搜索 (grep_search_async)
在中大型工程中利用异步 I/O 并发扫描文件，支持单关键词或批量多关键词/正则并发检索（批量查找符号或错误排查首选）：
```json
{
  "action": "grep_search_async",
  "queries": ["calculateTotal", "processOrder", "handlePayment"],
  "dir": "src",
  "pattern": "*.ts",
  "concurrency": 16,
  "max_matches": 50,
  "timeout_ms": 15000
}
```
- `query` (可选): 单个搜索关键词或正则表达式。
- `queries` (可选): 批量搜索关键词或正则数组，一次性并发查找多个符号，大幅减少交互轮次。
- `dir` / `path` (可选): 搜索目录或单文件路径，默认 `.`。
- `pattern` (可选): 文件通配符过滤，默认 `*`。
- `path_pattern` (可选): 路径正则表达式过滤。
- `is_regex` (可选): 是否显式指定正则。
- `concurrency` (可选): 异步并发通道数，默认 16（范围 1-64）。
- `max_matches` (可选): 最多返回匹配项数，默认 50。
- 分页 (可选): `page` / `page_size` / `offset` / `count_cap`，见统一分页约定；语义与 `grep_search` 一致。
- `timeout_ms` / `timeout` (可选): 并发超时限制（默认 15000ms）。
- `max_file_bytes` / `exclude_dirs` / `respect_gitignore` (可选): 与 `grep_search` 同语义，大库批量检索必备。

### 10. 查找符号所有引用与定向探索 (find_references)
精确查找目标符号（函数、类、变量、类型等）在工程中的所有定义、模块导入与真实调用点。

#### 1. 极致省 Token 规范与数据格式：
- **路径唯一性**：每个文件路径作为唯一键（Key）在返回对象中仅出现一次，绝对不重复输出文件长路径。
- **显式紧凑枚举**：类型使用带 `e` 前缀的代码（杜绝与列号混淆）：
  - **`e0`** = **`def`**（定义/声明：如 `export function foo`、`const foo =`、`def foo`）
  - **`e1`** = **`imp`**（模块导入：如 `import { foo }`、`require`、`use`）
  - **`e2`** = **`use`**（调用/使用：函数调用、属性读取、JSX 标签使用等）

#### 2. 调用参数说明：
```json
{
  "action": "find_references",
  "symbol": "useThreadRuntimeSelections",
  "detail": false,
  "max_results": 50,
  "max_tokens": 3000,
  "timeout_ms": 15000,
  "candidate_files": [
    "apps/web/src/App.tsx",
    "apps/web/src/components/**/*.tsx"
  ],
  "dir": "apps/web/src",
  "exclude_comments": true,
  "include_declarations": true
}
```
- `symbol` (必填): 目标符号名称（严格基于全词词法边界 `\b` 匹配，绝不误报包含该前缀或后缀的长标识符）。
- `detail` (可选): **代码细节显隐开关**（默认 `false`）。
  - `false`（推荐，极限省 Token）：仅返回如 `"L42:e0"`、`"L156:e1"`、`"L2341:e2"`；
  - `true`：返回完整代码行，格式为 `"L156:e1:import { foo } from ..."`。
- `timeout_ms` / `timeout` (可选): **执行超时上限**（默认 15000ms 即 15 秒）。如果遍历超时，将优雅返回已找到的部分结果并标记 `"timed_out": true, "truncated": true`，杜绝大仓库扫描卡死。
- `max_results` (可选): 最多返回的引用总条数（默认 50，最高 200）。防止全局公共函数几千处调用撑爆上下文，超出时返回 `truncated: true`。
- 分页 (可选): `page` / `page_size` / `offset` / `count_cap`，见统一分页约定；分页时额外返回 `page`、`page_size`、`total_pages`、`has_next`、`has_prev`，`files` 只含当页条目（`find_implementations` 的 `implementations` 列表同步切片）。
- `max_tokens` (可选): Token 预算安全熔断上限（默认 3000），物理级限制返回体积。
- `candidate_files` / `files` (可选): **候选文件或通配路径列表**。大模型可指定怀疑有调用的目标文件，系统直接秒级穿透该批文件，无需全盘耗时扫描。
- `dir` (可选): 未指定候选文件时的搜索根目录，默认当前目录 `.`。
- `pattern` (可选): 文件过滤模式，默认涵盖主流编程语言源文件。
- `exclude_comments` (可选): 是否自动过滤单行注释（`//`、`#`）与块级注释（`/* ... */`），默认 `true`。
- `include_declarations` (可选): 是否在结果中包含定义处自身（`e0`），默认 `true`。

#### 3. 典型返回样例 (当 detail: false)：
```json
{
  "symbol": "useThreadRuntimeSelections",
  "total": 4,
  "returned": 4,
  "truncated": false,
  "types": { "e0": "def", "e1": "imp", "e2": "use" },
  "files": {
    "apps/web/src/app/runtime/useThreadRuntimeSelections.ts": [
      "L42:e0"
    ],
    "apps/web/src/App.tsx": [
      "L156:e1",
      "L2341:e2",
      "L4210:e2"
    ]
  }
}
```
> 大模型可先通过 `detail: false` 快速获取所有引用所在的文件与行号；如需阅读某一处实现，再通过 `read_lines` 切片精准读取，极具成本效益！

### 11. 多语言文件符号大纲提取 (file_outline)
基于工业级 Tree-sitter 语法树引擎，秒级提取任意源文件（Rust, TS/JS, Python, Go, Zig, C/C++ 等）的顶层类、函数、接口、结构体、枚举与方法大纲及行号范围。

#### 1. 极致省 Token 规范：
- 面对大文件（数百至数千行）时，**强烈建议先调用 `file_outline`**，获取文件骨架结构（通常仅数十行文本、几十 Token），避免直接全量读取大文件挤爆上下文。
- 确定目标函数/类的行号范围（如 `[L85-120]`）后，再定向调用 `read_lines` 阅读目标逻辑。

#### 2. 调用参数说明：
```json
{
  "action": "file_outline",
  "path": "src/services/user.rs",
  "detail": false
}
```
- `path` (必填): 目标代码文件相对路径。
- `detail` (可选): 是否包含更深层次内部成员（如枚举项、结构体内部字段等，默认 `false`）。
- `max_tokens` (可选): 输出 Token 上限，默认 4000，超限自动截断并提示翻页（`read_lines` 定向续读）。
- `max_file_bytes` (可选): 单文件体积上限，默认 1MB，超限/二进制文件拒绝并指引切片读取。

### 12. 工程级批量大纲与批量读取 (workspace_outline / read_many)
- `workspace_outline`: 一次调用拿下整个目录的结构地图（gitignore 感知、跳过大文件/二进制、按 `max_tokens` 熔断），大库探索先看地图再定点 `read_lines`。
```json
{
  "action": "workspace_outline",
  "dir": "apps/server/src",
  "pattern": "*.ts",
  "max_files": 20,
  "max_symbols_per_file": 50,
  "max_tokens": 6000,
  "exclude_dirs": ["platform-pkgs", "release"]
}
```
- `dir` (可选): 起始目录，默认 `.`；`pattern` / `path_pattern` (可选): 文件与路径过滤；`max_files` (可选): 最多大纲文件数，默认 20（最高 100）；`max_symbols_per_file` (可选): 单文件最多顶层符号数，默认 50；`max_tokens` (可选): 总 Token 上限，默认 6000。
- 分页 (可选): `page` / `page_size` / `offset` / `count_cap`，见统一分页约定；分页时只 outline 当页候选文件，表头注明 `page X of Y` 与总数。
- `read_many`（批量读取，见上文读取工具章节）可配合地图做定点精读。

### 13. 全局符号与架构图谱 (repo_map)
基于高性能 AST 分析与原生 Glob 文件系统快速构建工程级全量符号地图与依赖图谱：
- **全局上帝视角**：提取全量符号定义（函数、类、结构体、接口）、依赖关系（`depends_on`）与模块边界（`module`），毫秒级感知全局代码拓扑。
- **极速增量索引缓存**：进程内缓存各文件 AST 解析结果，文件未变动时毫秒级瞬时返回；支持 Tree-sitter 并行加速。
- **按需调用方探索**：支持传入 `include_used_by: true` 获取关键符号的轻量调用方清单，辅助跨文件重构定位。

#### 调用参数说明：
```json
{
  "action": "repo_map",
  "dir": "apps/server/src",
  "max_files": 200,
  "max_tokens": 8000,
  "include_used_by": false
}
```
- `dir` (可选): 扫描起始目录，默认 `.`；
- `max_files` (可选): 最大扫描文件数，默认 200（最高 500）；
- `max_tokens` (可选): 总 Token 预算上限，默认 8000，超限自动安全截断；
- 分页 (可选): `page` / `page_size` / `offset` / `count_cap`，见统一分页约定；分页时返回 `total`、`total_pages`、`returned`，`entries` 只含当页文件；
- `include_used_by` (可选): 是否包含符号的轻量级被引用关系分析（默认 false，开启时精准提取被哪些文件使用）。

### 14. 架构拓扑与调用链一次性提取 (code_graph)
基于 Tree-sitter WASM 语义分析，按需在内存中毫秒级提取类继承 (extends)、接口实现 (implements)、成员所有权 (owns)、模块引用 (imports)、函数/方法调用流 (calls) 拓扑。首要价值是替代多次循环 grep_search + read_file 拼凑关系：一次调用即得全局骨架。DOT/py_stub/networkx 只是紧凑文本载体，默认 dot 最省 Token。工具别名支持 `relation_graph` 与 `symbol_graph`。

#### IRON RULE（触发铁律）：
- 当需要理清类继承树、多模块 import 网络或跨函数调用链路时，必须优先调用 code_graph 一步获取拓扑，严禁连续执行多次 grep_search 或循环 read_file 逐个文件拼凑调用关系。
- file_outline 看单文件结构、find_references 看单符号引用；只有 code_graph 能一次给出多跳上下游拓扑。

#### 1. 使用场景：
- 理解类继承体系（如查看子类有哪些父类、实现了哪些接口、包含哪些复合成员）；
- 探查文件或模块的上下游依赖关系（upstream/downstream/both）；
- 追溯函数或类方法的调用拓扑（call_flow，如查看执行路径调用了哪些辅助函数）；
- 重构大型项目前快速获取局部架构骨架（无需先建全量索引或占用硬盘）。

#### 2. 调用参数说明：
```json
{
  "action": "code_graph",
  "target": "CustomEngine",
  "mode": "symbol_hierarchy",
  "depth": 2,
  "format": "dot"
}
```
- `target` (必填): 要分析的符号或模块——类名/函数名/符号名（如 `CustomEngine`、`processOrder`）或模块相对路径（如 `src/index.ts`）。想查“谁继承/调用它”直接传符号名，不要误传成写入目的地路径；同时兼容 `symbol`/`path` 别名。
- `mode` (可选): 
  - `symbol_hierarchy`（默认）：类继承/接口实现/成员所有权拓扑；
  - `module_dependency`（别名 `module_deps`）：模块 import 引用网络；
  - `call_flow`：函数或类方法的上下游调用网络。
- `depth` (可选): 遍历深度，默认 `2`，上限 `5`。
- `direction` (可选): `upstream`（上游依赖）、`downstream`（下游依赖）或 `both`，仅在 `module_dependency` 下有效。
- `format` (可选): 输出格式：`dot`（Graphviz DOT 语言，默认，最省 Token）、`py_stub`（Python 架构骨架存根）或 `networkx`（Python NetworkX 构建脚本）。
- `output_file` (可选): 若需显式保存到磁盘可指定输出路径（默认仅内存计算返回，绝不产生临时文件）。
- `candidate_files` (可选): 限定候选文件路径数组加速精准分析。

#### 3. DOT 边样式说明：
- `extends`: 实线普通箭头 (`->`)；
- `implements`: 虚线箭头 (`style="dashed"`)；
- `owns`: 菱形箭头 (`arrowhead="diamond"`)；
- `calls`: 点状虚线箭头 (`style="dotted"`)；
- `imports`: 实线普通箭头带有 `label="imports"`。

### 15. AST 语义级跨文件符号重命名 (rename_symbol)
基于 Tree-sitter 语法树进行符号级原子替换，彻底区别于传统盲目字符串替换：
- **精准识别语法标识符**：自动跳过注释、文档字面量、普通字符串内容，仅替换真实代码符号与属性名。
- **全词边界保护**：绝对不误伤包含该前缀或后缀的长标识符。
- **支持 Dry-Run 预演**：在写入前可安全预览所有文件中的待改动行与前后对比。

#### 调用参数说明：
```json
{
  "action": "rename_symbol",
  "symbol": "OldClassName",
  "new_name": "NewClassName",
  "candidate_files": ["src/**/*.rs"],
  "dry_run": false
}
```
- `symbol` / `old_name` (必填): 待重命名的原符号名称。
- `new_name` (必填): 替换后的新符号名称。
- `candidate_files` / `files` / `path` (可选): 限定生效的文件或目录范围（未指定时在整个工作区安全检索并替换）。
- `dry_run` (可选): 为 `true` 时仅返回待替换清单和代码前后对比，不落盘写入；为 `false`（默认）时执行替换。

### 16. 文件移动并自动重写导入路径 (move_file_with_imports)
移动或重命名代码文件，并自动将工程中其他文件对它的相对导入路径（`import ... from "./..."`）更新为新路径，同时自动调整被移动文件自身的相对导入。

#### 调用参数说明：
```json
{
  "action": "move_file_with_imports",
  "from": "apps/web/src/OldComponent.tsx",
  "to": "apps/web/src/components/OldComponent.tsx",
  "dry_run": false
}
```
- `from` / `source` (必填): 原文件路径。
- `to` / `dest` (必填): 目标文件路径。
- `dry_run` (可选): 为 `true` 时仅预览将要修改的 import 路径，不实际移动文件。

### 17. 精准定义查找与函数体直达 (find_definition)
彻底解决 Agent 为了解一个函数实现而盲目全文 read_file 几百上千行浪费上下文的痛点！
- **单步直达源头**：支持跨文件追溯 import 源头，精准返回目标符号的声明位置、代码行范围（`[Lstart-Lend]`）与完整函数/类签名。
- **内置实现预览**：自动携带函数体/定义体核心实现片段（默认最多 40 行），无需再次调用 read_file 即可秒知其内部结构与实现！

#### 调用参数说明：
```json
{
  "action": "find_definition",
  "symbol": "extractFileOutline",
  "path": "apps/server/src/saVmTool.ts",
  "include_body": true
}
```
- `symbol` (必填): 目标符号/函数/类名。
- `path` (可选): 起始文件。若该文件通过 import 引用目标符号，引擎会自动顺藤摸瓜追踪至源定义文件；若省略，在工作区快速检索。
- `include_body` (可选): 是否包含函数体实现代码（默认 `true`）。

### 18. 大文件分阶段拆分工作流 (split_plan / split_stage / split_refine / split_repair / split_status)
适用于 App.tsx 类大型重构：先粗分模块，再在草稿中逐步细化，最后集中修复并验收。阶段草稿保存在独立 workflow checkpoint 中，不会提前修改工作树。

1. split_plan 建立可续接的 AST 大纲与耦合快照；split_status 可在上下文丢失后恢复阶段状态：
   { "action": "split_plan", "path": "apps/web/src/App.tsx", "task": "按功能模块拆分" }
   { "action": "split_status", "session_id": "<id>" }
2. split_stage 提交一个粗粒度模块草稿；split_refine 在同一 checkpoint 内继续细分。ops 每项提供完整文件 content 或唯一上下文的 patch：
   { "action": "split_stage", "session_id": "<id>", "module_name": "Composer", "ops": [{ "path": "apps/web/src/App.tsx", "content": "..." }, { "path": "apps/web/src/components/Composer.tsx", "content": "..." }] }
3. split_repair 可用 phase: stage 暂存集中修复，再用 phase: diff 输出 staged diff 并标记待审版本，再用 phase: validate 做 staged TS/TSX 语法检查；修复时仍不触碰工作树。
4. 审阅最终 diff 后显式调用 phase: commit, confirm: true。提交前验证原文件未被并发修改；checkpoint 保留，支持 phase: rollback。提交后仍须运行项目级 typecheck 与回归测试。

split_plan / staging 本身不自动决定业务边界、不自动修复语义；小批次递进并由模型审阅。

### 19. 超大文件拆分神器 (extract_to_file)
专治超大文件拆分与模块化解耦（如 App.tsx 瘦身）：
- **一键原子化迁移**：将原文件的指定代码块（`[start_line, end_line]`）直接剪切到新文件。
- **自动补齐 Export**：目标文件被剪切的代码自动补充 `export` 关键字。
- **自动提取并重写目标导入**：基于 AST 自动扫描原文件中该代码段使用的所有外部依赖，并在新文件顶部自动注入匹配的 import 语句（自动重写相对路径）。
- **原文件无缝接入**：自动计算相对路径并在原文件对应行原位插入 `import { ... } from "./relative/path"`，彻底杜绝行号偏移与语法破坏！

#### 调用参数说明：
```json
{
  "action": "extract_to_file",
  "source": "apps/web/src/App.tsx",
  "target": "apps/web/src/components/SettingsDialog.tsx",
  "start_line": 240,
  "end_line": 310,
  "dry_run": false
}
```
- `source` / `from` (必填): 待拆分的源文件。
- `target` / `to` (必填): 拆分出的新文件路径。
- `start_line` & `end_line` (必填): 待剪切的代码行号范围（1-based，闭区间）。
- `symbols` (可选): 需要导出的符号名（若未传则自动基于 AST/正则提取）。
- `component_name` (可选): 目标组件名。
- `dry_run` (可选): 为 `true` 时仅预览前后对比与生成代码，不落盘。
- `keep_source` (可选, 默认 `false`): 为 `true` 时把默认“搬移”变成“复制”——目标照写，源文件不动且不注入 import。批量拆分推荐先 `keep_source=true` 复制 N 个叶子块，`verify_changed` 全过后再删源，避免拆一半源文件已碎。

### 20. 智能导包与合并 (add_import)
无需手动数行号、无需小心翼翼用 edit_file 防止行号漂移：
- **智能合并已有模块**：如果文件已存在该模块的 import（如已存在 `import { a } from "./utils"`），自动合入为 `import { a, b } from "./utils"`，已存在则安全 no-op。
- **规范插入顶部**：如果为全新模块，自动定位文件顶部最后的 import 语句并在其下方规整插入；若无任何 import，自动置于头部指令（如 `"use client"`）之下。

#### 调用参数说明：
```json
{
  "action": "add_import",
  "path": "apps/web/src/App.tsx",
  "statement": "import { t } from './i18n';"
}
```
- `path` (必填): 目标文件。
- `statement` (必填): 完整的 import 语句。

### 21. 单文件即时语法诊断 (get_diagnostics)
毫秒级快速语法验错利器，杜绝盲目等待全量 tsc 编译：
- **毫秒级极速反馈**：针对单文件进行实时语法与解析检查（TS/JS 基于 TypeScript 语法编译器，Rust/Python/Go/Zig 基于 Tree-sitter AST）。
- **React Hook 安全守门**：针对 React 组件，自动检测 early-return 之后或条件分支内部的非法 Hook 调用，杜绝白屏崩溃！
- **精准红线定位**：即时输出语法报错行号、列号、原因与代码行预览。

#### 调用参数说明：
```json
{
  "action": "get_diagnostics",
  "path": "apps/web/src/App.tsx"
}
```
- `path` (必填): 待诊断的文件。

### 22. 工作区全量语法红线聚合 (workspace_diagnostics)
针对目录或整个工程进行语法诊断聚合，毫秒级快速发现所有红线，对等替代耗时极长的全量 `tsc`：
- **目录级批量扫红线**：递归扫描指定目录下的源码文件，并行提取语法与解析错误。
- **三重安全熔断**：超 `max_files` 自动截断、超 `max_errors` 熔断并标剩余数、超 `max_tokens` 自动精简返回定位。
- **紧凑机器信号**：`detail: false` 时仅返回 `path:Lx:Cy:code`，体积仅为终端 tsc 全量输出的数十分之一。

#### 调用参数说明：
```json
{
  "action": "workspace_diagnostics",
  "dir": "apps/web/src",
  "max_files": 100,
  "max_errors": 50,
  "detail": false
}
```
- `dir` (可选): 待扫描目录，默认 `.`；
- `pattern` (可选): 文件匹配 pattern，默认主流代码文件扩展名；
- `max_files` (可选): 最大扫描文件数，默认 100；
- `max_errors` (可选): 最大错误数，默认 50；
- `detail` (可选): 默认 false（紧凑单行格式），true 为完整错误详情对象。

### 23. 真实世界快速验证闭环 (verify_loop)
专为大模型自主编码迭代设计的快速闭环验证裁判，杜绝幻觉与盲目交付：
- **真实语法与安全体检**：自动对指定文件列表或目录执行多语言语法与 React Hook 安全校验，返回结构化的裁判结果（`typecheck: "pass" | "fail"` 与报错行号、列号、信息）；
- **定向差异验证 (verify_changed)**：支持传入 `files: ["path1.ts", "path2.ts"]` 针对本次改动的文件做定向极速验证，即改即验。

#### 调用参数说明：
```json
{
  "action": "verify_loop",
  "files": ["apps/server/src/saVmTool.ts"],
  "max_errors": 20
}
```
- `files` (可选): 指定待检验的文件相对路径数组；
- `dir` (可选): 未指定 files 时的扫描根目录；
- `max_errors` (可选): 最大收集错误数（默认 20）；
- `max_tokens` (可选): 输出 Token 预算上限（默认 4000）。

### 24. 自动整理与清理无用导入 (organize_imports)
基于 TypeScript AST 语法分析，自动剔除未使用的 import 声明、合并同源导入、按标准模块层级规范排序：
- **无损剔除未用变量**：自动识别 JSX 标签、类型标注、值引用，安全剔除冗余 import。
- **合并与规范排序**：同源多语句导入自动合并，并按 Node 内置库 -> 外部 npm 库 -> 内部相对路径层级清晰排序。

#### 调用参数说明：
```json
{
  "action": "organize_imports",
  "path": "apps/web/src/App.tsx",
  "dry_run": false
}
```
- `path` (必填): 待整理代码文件路径。
- `dry_run` (可选): 为 `true` 时仅预览变更与摘要，不直接落盘。

### 25. 代码块作用域与闭包依赖分析 (analyze_scope)
专为巨型组件或大函数拆分设计的依赖分析神器：
- **推导自由变量与闭包状态**：输入代码起止行号，精确计算该代码块引用了哪些外层 state、props、handlers。
- **自动生成 Props 接口与组件调用**：智能输出子组件所需的 `interface ExtractedProps` 定义及父组件中的调用示例，安全指导大文件拆分。

#### 调用参数说明：
```json
{
  "action": "analyze_scope",
  "path": "apps/web/src/App.tsx",
  "start_line": 200,
  "end_line": 350,
  "component_name": "ExtractedChild"
}
```
- `path` (必填): 目标文件路径。
- `start_line` & `end_line` (必填): 欲抽离的代码行号范围（1-based）。
- `component_name` (可选): 建议的抽取组件名称（默认 `ExtractedComponent`）。

### 26. 只读 Git 状态与增量 (git_status / git_diff)
工作区是否干净、改了什么，优先用原生只读 git 动作（无 shell、argv 白名单、截断保护）；`run_host git` 仅在沙箱拦截开启（`replaceExec`）时拦截高危破坏性命令（`reset --hard`、`clean`、`revert`），其余 clone/checkout/add/commit/pull 均放行；沙箱关闭时终端与 run_host 均完全开放、零拦截。严禁 `python -c subprocess(git)`、`bun -e Bun.spawnSync(git)`、写临时脚本跑 git、直读 `.git/HEAD|config|FETCH_HEAD`：
```json
{ "action": "git_status" }
{ "action": "git_diff" }
{ "action": "git_diff", "staged": true }
{ "action": "git_diff", "stat_only": true }
{ "action": "git_diff", "path": "apps/server/src/miniBridge.ts", "context": 3 }
```
- `git_status`：分支、上游、ahead/behind、staged/unstaged/untracked 分类；`repo` 为仓库内任意路径（默认 cwd），向上找 `.git` 不越 workspace root。
- `git_diff`：未提交增量（默认 unstaged；`staged:true` 看暂存区；`stat_only:true` 只看统计；`path` 限定单文件/目录；`context` 0-10；超限截断并标 `truncated:true`）。
- 收到 `use git_status/git_diff instead` 拒绝时立即改调原生动作，不要换姿势重试。

## 4、脚本与外部交互工具

### 1. 受控工程验证与检查工具 (run_project_check)
当策略配置了固定工程 Profile 时，在沙箱白名单保护下运行服务端预定义的工程构建与类型检查（禁止任意 CLI 参数、禁止执行任意代码）：
```json
{
  "action": "run_project_check",
  "profile": "web-typecheck"
}
```
若执行指定单元测试文件（如 `server-test-file`、`web-test-file`、`shared-test-file`），须传入 `test_file` 相对路径：
```json
{
  "action": "run_project_check",
  "profile": "server-test-file",
  "test_file": "tests/server/saVmTool.test.ts"
}
```
- `profile` (必填): 预定义工程 Profile 名称（如 `shared-typecheck`, `server-typecheck`, `web-typecheck`, `root-typecheck`, `web-build`, `server-test-file`, `web-test-file` 等）。
- `test_file` (测试类 profile 必填): 目标测试文件相对路径（严格限制在 `tests/` 目录下，禁止 `..` 路径越界）。

### 2. 安全通用 Bun 执行工具 (run_bun)
当策略允许时在受限沙箱中安全运行 Bun 命令（支持 test、build、run 直接跑文件、受限 --filter，严格离线且禁止任意 shell 脚本）：
```json
{
  "action": "run_bun",
  "subcommand": "test",
  "args": ["tests/server/foo.test.ts"]
}
```
执行工作区内存在的构建或脚本文件：
```json
{
  "action": "run_bun",
  "subcommand": "run",
  "args": ["scripts/build.ts"]
}
```
运行 Monorepo 包内受控验证（script 限 typecheck / build / test / lint）：
```json
{
  "action": "run_bun",
  "subcommand": "--filter",
  "args": ["@codex-ui/shared", "typecheck"]
}
```
- `subcommand` (必填): 允许的子命令（`test`, `run`, `build`, `--filter`）；
- `args` (可选): 参数列表（路径须在工作区沙盒内；`run` 仅限直接跑文件，严禁 package.json 脚本名；严禁 `--preload` 与内联代码）。

### 3. 结构化外部二进制执行工具 (run_host)
直接在宿主环境以结构化参数执行白名单外部二进制（bun、node、python、zig、git 或工作区内部已存在的可执行文件；curl/powershell/cmd 均被拒绝；git 高危 `reset --hard/clean/revert` 仅在沙箱拦截开启时被拦截，git 只读优先用 git_status/git_diff），提供确定性切片、日志过滤与常驻帮助缓存，彻底替代脆弱的 shell 拼接（`cmd /c`、`2>&1`、`| Select`、`> file`、`cd`）：
```json
{
  "action": "run_host",
  "exe": "bun",
  "args": ["--help"],
  "head_lines": 30
}
```
执行构建并截取最后 50 行错误日志：
```json
{
  "action": "run_host",
  "exe": "zig",
  "args": ["build", "test"],
  "tail_lines": 50
}
```
过滤测试失败日志：
```json
{
  "action": "run_host",
  "exe": "node",
  "args": ["test", "--filter", "parse"],
  "filter": "FAIL"
}
```
- `exe` (必填): 白名单短名（`bun`, `node`, `python`, `zig`, `git`）或工作区内相对/绝对路径二进制；严禁执行未授权系统命令（如 powershell, curl, cmd；git 高危 `reset --hard`/`clean`/`revert` 仅在沙箱拦截开启时被拦截，git 状态/增量优先用 `git_status`/`git_diff`，严禁经 python -c/bun -e/临时脚本/.git 内文件绕行）；
- `args` (可选): 字符串参数数组（每个参数 <= 4096 字符，总参数 <= 32768 字符；严禁 `publish` 等危险写子命令）；
- `cwd` (可选): 执行工作目录，必须在工作区沙盒内；
- `head_lines` (可选): 仅保留前 N 行输出；
- `tail_lines` (可选): 仅保留后 N 行输出（查看构建报错必备）；
- `filter` (可选): 正则或子串过滤行（如 `FAIL`、`error:`）；
- `max_tokens` (可选): 输出 Token 熔断上限（默认 4000）；
- `timeout_ms` (可选): 超时毫秒数（默认 30000）。
**特性优势**：所有 `--help`、`-h`、`version` 查询自动触发服务端内存三元组缓存（基于 exe 路径 + mtime + args），二次调用 0ms 且不占进程槽。

## 5、上下文优化与工程记忆 (Context Optimization & Memory)

### 1. 自主修剪过时工具历史 (clear_tool_history)
在长对话中，当大模型已完成初始的代码探索与调研，发现早期大量的只读检索与文件输出（如 `read_file`、`grep_search`、`list_dir`）占用过多上下文时，可自主调用本动作将过时的工具输出原地精简为简短占位符，从而释放大量上下文 Token：
```json
{
  "action": "clear_tool_history",
  "keep_last_n_turns": 2,
  "filter_tools": ["read_file", "read_lines", "grep_search", "grep_search_async", "list_dir", "find_files"],
  "reason": "已完成初始代码定位，清理前序探索的冗长文件输出以释放上下文"
}
```
- `keep_last_n_turns` (可选): 保留最近几轮工具输出完整保留（默认 2，强制 >= 2）。
- `filter_tools` (可选): 仅修剪指定类别的工具（默认修剪只读文件与检索工具，绝不破坏用户提示词与代码变更）。
- `reason` (可选): 修剪理由，便于追踪与审计。

**【三大严苛红线】**：
1. **Turn 运行中禁剪**：严禁在当前多步推理与操作中途随意修剪，必须在当前探索或检索轮次彻底结束且已形成结论后方可触发；
2. **keep 严禁小于 2**：`keep_last_n_turns` 绝对禁止传入小于 2 的数值（系统已强制保底为 2），确保最近上下文线索绝对连续；
3. **剪前确认无后续依赖**：修剪前必须确认后续代码编写与测试完全不再依赖被修剪工具的具体长篇输出细节，避免重复读取倒贴 Token。

### 2. 工程级长效记忆与便签【开局必读/收尾必写】 (save_note / read_notes / delete_note)
**触发规则：新任务先 `read_notes` 再动手；任务收尾必须 `save_note` 沉淀关键事实；上下文清理/压缩前必存。无记忆也必须调用一次 `read_notes` 确认。**
用于在工程维度跨会话持久记录关键事实、架构暗知识、环境规则与调试线索（数据保存在软件全局数据目录 `~/.codex-ultra/workspace-memory/` 中，按当前工作区物理路径强绑定，**绝对不污染工作区 Git 仓库**）：
- **记录记忆 (save_note / add_note)**：支持按优先级 `level: "low" | "normal" | "important" | "critical"`（默认 `normal`）保存重要程度，高等级便签在检索时优先排在前面，并在达到 100 条容量上限时优先受保护不被淘汰。每条记录限 1000 字符以内（超长自动截断）。带 key 精确命中；key 记不清时传模糊关键词即可按 key/content 子串检索（大小写不敏感）并返回 `matches`。
```json
{
  "action": "save_note",
  "key": "test_port",
  "content": "测试环境使用独立端口 43121，严禁占用用户生产端口 43120",
  "level": "critical"
}
```
- **读取记忆 (read_notes / read_note / list_notes)**：开局或上下文清理后查阅当前工程的全部或单条事实记忆。**与 read_file 一致**支持传入 `max_tokens` 预算与 `remaining_tokens`（剩余可用 Token 上下文余量自动熔断缩容保护，防止自身撑爆）；另支持统一分页约定的 `page` / `page_size` / `offset`（返回 `total`、`total_pages`、`returned`）。
```json
{
  "action": "read_notes",
  "max_tokens": 2000
}
```
- **删除/清空记忆 (delete_note / clear_notes)**：根据 key 删除失效条目，或传入 `all: true` 清空当前工程全部便签。
```json
{
  "action": "delete_note",
  "key": "test_port"
}
```

## 6、批处理并行任务 (parallel，已暂时屏蔽)
**`parallel` 已暂时屏蔽（鸡肋）：一律用同一轮多个 `sa_vm_run` 原生多调用做并发，批量写入用串行 `edit_file/write_file` 或一次 `apply_patch`，不要发 `parallel`（服务端直接 228 打回，`SA_VM_ENABLE_PARALLEL=true` 才可恢复）：

### 1. 多文件并发写入/替换（多语言/批量配置优先推荐范例）
```json
{
  "concurrency": 4,
  "parallel": [
    { "action": "edit_file", "path": "apps/web/src/locales/en.json", "old_text": "\"key\": \"old\"", "new_text": "\"key\": \"new\"" },
    { "action": "edit_file", "path": "apps/web/src/locales/cn.json", "old_text": "\"key\": \"旧\"", "new_text": "\"key\": \"新\"" },
    { "action": "edit_file", "path": "apps/web/src/locales/ja.json", "old_text": "\"key\": \"古\"", "new_text": "\"key\": \"新\"" }
  ]
}
```

### 2. 多文件并发读取（已降级：优先原生多调用）
并发读请在同一轮发出多个 `sa_vm_run`（如 `{action:"read_lines",path:"src/a.ts"}` + `{action:"read_lines",path:"src/b.ts"}`），服务端并发执行、独立回写；`parallel` 读仅作不支持多调用的中转兜底：
```json
{
  "concurrency": 4,
  "parallel": [
    { "action": "read_lines", "path": "src/a.ts", "start_line": 1, "end_line": 80 },
    { "action": "read_lines", "path": "src/b.ts", "start_line": 1, "end_line": 80 }
  ]
}
```

### 3. 混合并发（已降级：优先原生多调用 + grep_search_async）
`run_host --help` + 代码探查请拆成同一轮多个 `sa_vm_run`；同义词检索优先一次 `grep_search_async({queries:[...]})`。`parallel` 混合批仅作兜底：
```json
{
  "concurrency": 4,
  "parallel": [
    { "action": "run_host", "exe": "bun", "args": ["--help"], "head_lines": 20 },
    { "action": "grep_search", "pattern": "*.zig", "query": "LinearAwait" },
    { "action": "list_dir", "path": "src", "depth": 1 }
  ]
}
```
**批处理依赖红线**：同批内严禁出现“写/构建 -> 读取产物”的同批因果依赖（例如同一 `parallel` 数组中包含编译生成 `test.out` 的 `run_host`，同时包含读取 `test.out` 的 `read_file`）。若有因果依赖，必须拆分成前后两次独立的串行批次，同批依赖冲突将被系统直接拦截打回。

## 7、严格准则与安全保障
1. **绝不手写脚本代码**：永远只使用上述已启用的封装动作（`action: "apply_patch" | "edit_file" | "write_file" | "delete_file" | "safe_delete" | "move_file" | "copy_file" | "read_file" | "read_lines" | "read_many" | "read_file_tail" | "count_lines" | "file_info" | "find_files" | "list_dir" | "grep_search" | "grep_search_async" | "git_status" | "git_diff" | "find_references" | "find_implementations" | "file_outline" | "workspace_outline" | "repo_map" | "code_graph" | "relation_graph" | "symbol_graph" | "rename_symbol" | "move_file_with_imports" | "find_definition" | "extract_to_file" | "extract_component" | "extract_hook" | "atomic_refactor" | "split_plan" | "split_stage" | "split_refine" | "split_repair" | "split_status" | "add_import" | "get_diagnostics" | "workspace_diagnostics" | "verify_loop" | "verify_changed" | "auto_fix_missing_imports" | "organize_imports" | "analyze_scope" | "analyze_coupling" | "run_project_check" | "run_bun" | "clear_tool_history" | "save_note" | "read_notes" | "delete_note" | "run_host"`），绝不手写 TS 源码或传递 `source`。
2. **白名单策略保障**：所有文件读写、补丁应用与网络请求均受到当前对话策略白名单保护，超出范围的路径请求将被自动拒绝。
3. **安全自动备份**：修改或覆盖文件（`apply_patch`、`write_file`、`edit_file`、`delete_file`）前，系统会在底层自动对原文件执行安全备份。
4. **宿主系统工具协同**：当通过系统工具调用 `apply_patch` 或执行读写时，安全守护 Broker 会透明进行权限判定与原子备份，与封装工具无缝协同。
5. **查外部库四步曲**：严禁在终端用 `Get-ChildItem` 盲猜外部绝对路径或深层递归。标准步骤：1. `list_dir({ dir: LIB_ROOT, max_entries: 20 })` -> 2. `find_files({ dir: LIB_ROOT, pattern: 'target.ts' })` -> 3. `grep_search({ path: 'found_path', query: 'key' })` -> 4. `read_lines({ path: 'found_path', start_line: X-20, end_line: X+20 })`。严禁全量读大文件后再在终端过滤。
6. **写-运-读三步曲**：构造测试与运行验证必须分步明确：步骤一 `write_file` 生成测试用例 -> 步骤二 终端单条原生命令运行验证（如 `bun run ./script.ts`，严禁 `;` 链式拼接或 `Out-Host`） -> 步骤三 `read_lines` / `read_file_tail` 结构化查看产物。
7. **文档检索固定食谱**：查找 SDK/模块文档时，先 `find_files` 定位 markdown -> `grep_search` 定位章节行号 -> `read_lines` 切片正文。严禁检索渲染后 HTML 或在终端跑 `Select-String -Context` 产生巨量噪声。
8. **严禁终端排版与静默吞错 (NO FORMAT & NO SILENTLY CONTINUE)**：
   - 严禁在终端运行 `Format-Table`, `Format-List`, `Format-Wide`, `Out-String`，JSON 即最终格式。
   - 严禁在终端使用 `-ErrorAction SilentlyContinue` 或 `2>$null` 掩盖文件错误。检查文件必须使用 `sa_vm_run({ action: 'test_path', path: '...' })`。

## 8、JEV 主动决策助手 (opt-in, advisory only)
大模型自主评估决定何时做选择题，无需等待外部钩子触发；JEV 基于 SystemOne 引擎提供毫秒级高置信度离散裁决，结果作为专家建议辅助思考，最终决策权在你。
- **分叉单选**：`sa_vm_run({ action: 'jev_choose', question: '...', options: { a: '...', b: '...' }, context: '...' })`（options 2~6 项，context 自动截断安全保护）。当面对 2~6 种设计/实现方案分叉、架构选型、降级处理或边界歧义时调用，JEV 返回最优方案与置信度。
- **交付多选自检**：`sa_vm_run({ action: 'jev_checklist', checks: { no_placeholders: '...', error_handling: '...' }, context: '...' })`（checks 1~8 项）。在复杂修改完成交付或提交前，主动列出多项准则并发验证，返回逐项 pass/fail 与总体结论。
- **思考前裁决**：`sa_vm_run({ action: 'jev_thinking', goal: '...', thoughts: { t1: '...', t2: '...' }, context: '...' })`（thoughts 1~4 条）。展开长思考前列出候选思路交 JEV 单选，内置 `__act_now`（已有足够信息则直接行动，避免过度思考）；判走某条就去想，单轮只调 1 次，不连环追问。
- **红队找茬**：`sa_vm_run({ action: 'jev_redteam', target: '...', context: '...' })`。高风险动作（迁移、鉴权、安全边界、上线）前把方案交 JEV 审：返回最可能翻车点（固定 8 类风险）+ proceed / harden_first / stop 裁决；补的是你没列出来的盲区。
- **多项排序**：`sa_vm_run({ action: 'jev_rank', items: { a: '...', b: '...' }, criterion: 'ROI', context: '...' })`（items 2~6 项）。按给定标准排前三，未入围的原序附后；技术债、重构 backlog 按性价比排序用它。
- **范围把关**：`sa_vm_run({ action: 'jev_scope', question: '<task>...', options: { p1: '...' }, context: '...' })`。规划阶段先审体量（合适/拆 2~3/拆多/MVP/合并），给了候选阶段再指出最弱环节；避免 epic 直接开干事后返工。
- **分配前门禁（Task/subagents 必问）**：`sa_vm_run({ action: 'jev_dispatch', question: '<task>...', options: { a: '...' }, context: 'max_parallel=3; 依赖说明', target: 'slots=3' })`（options 2~6 项可省）。并行派 subagents/Task 前必须先过此门：返回 single/parallel/sequential/parallel_batches + 最弱环节 + parallelism + dispatch_plan；按 plan 执行，single 则不派。
- **一致性审计**：`sa_vm_run({ action: 'jev_consistency', plan: '...', constraints: { no_mock: '...' }, context: '...' })`（constraints 1~8 项）。审计划本身是否违反硬约束，逐项 holds / violated / unclear；区别于查证据的 checklist。
- **交付核准**：`sa_vm_run({ action: 'jev_done', user_request: '...', actual_work: '...', evidence: '...' })`。说"做完了"之前先核：原始需求 vs 实际工作 vs 验证证据，判 truly_completed / incomplete_with_todos / unverified_claim / diverged + deliver / keep_working；专治留 TODO 假装交付。
- **根因仲裁**：`sa_vm_run({ action: 'jev_diagnose', error_summary: '...', hypotheses: { race: '...' }, proposed_fix: '...', context: '...' })`（hypotheses 2~4 个）。报错时先判最可能真因，再判拟定修复是治本 root_cause_fix、治标 symptom_patch 还是掩盖 risky_mask；治标前先过这一关。
- **边界筛查**：`sa_vm_run({ action: 'jev_edge_cases', code: '...', context: '...' })`。把实现扔给 JEV，指出 5 类边界（数值/空与缺省/编码符号/重入幂等/中断超时）里最脆弱的 1~2 项，照着补断言，别只测 Happy Path。
- **爆炸半径审查**：`sa_vm_run({ action: 'jev_blast_radius', diff: '...', target_component: '...', context: '...' })`。合入/提交重要 diff 前审副作用（纯内部/api_break/state_leak/perf_cliff）+ safe_to_apply / needs_compat_shim / needs_regression_tests。注意：方案用红队，diff 用 blast。
- **意图分析**：`sa_vm_run({ action: 'jev_intent', question: '<用户原话>...', options: { a: '...' }, context: '...' })`。收到用户输入后先判意图：给了候选解读（options 2~6 项）就单选最可能+判清晰度；不给就按内置 8 类意图分类+判 clear / needs_clarification / ambiguous，并给建议第一步。先过这一关再动手，少返工。
- **续接下一步**：`sa_vm_run({ action: 'jev_next', question: '<刚完成的工作>...', options: { a: '...' }, context: '<剩余 backlog>...' })`。任务完成后别闲着：给了候选后续（options 2~6 项）就挑最佳下一步+判动量；没给就按上下文 backlog 判 continue_now / confirm_first / stop，auto_continue 为 true 时直接开干下一步。
- **门控工具历史压缩**：`sa_vm_run({ action: 'jev_compress', mode: 'subscription' | 'token' | 'auto', threshold: 85 })`。返回四步压缩计划（checklist 门卫 -> save_note 外化要点 -> clear_tool_history(keep>=2，只剪只读类) -> 按需回取）；需同时开启 §6 clear_tool_history 能力。订阅制每 phase 边界剪，Token 制到阈值才剪。
- **任务进度裁决**：`sa_vm_run({ action: 'jev_progress', question: '<任务>...', options: { p1: '...' }, content: '<已完成>...', context: '...' })`（task -> question，phases -> options，completed -> content）。明确任务执行中按需查一次进度：返回进度带（0–25/25–50/50–75/75–99/100）+ on_track / at_risk / blocked / done + 下一步；只在大重构/多阶段手动触发，常态任务别每轮调。
- **记忆分层裁决**：`sa_vm_run({ action: 'jev_memory', content: '<候选记忆>...', context: '<来源任务>...' })`。收尾前判一条事实是否值得进长期记忆：返回 skip（临时状态/一次性输出）/ workspace（仅当前工程复用，save_note scope=workspace）/ global（跨工程通用偏好与约定，save_note scope=global）；判 workspace/global 后必须调 save_note 落盘。
- **节流与自主性**：自主评估必要性，单轮按需调用（通常 1~2 次），超时或网络异常自动返回诊断（fallback: model_decide），绝不循环追问或阻塞流程。各方法可在增强工具对话框第 7 节单独开关；JEV 对话框总开关关闭且未逐项开启时本节隐藏。

## 9、Opencode relay 与 serve 接线 (opencode backend only)
本节仅在 `cliBackend === "opencode"` 时生效；codex/mini/claude/agy/grok/pi 走各自 bridge，本节只读不执行。
- **OPENCODE_CONFIG_CONTENT 注入**（`agentRuntime/opencodeCompatibleProcessManager.ts:126`）：每次拉起 `opencode serve` 由服务端组装 JSON：`permission`（dangerous 为 `{"*":"allow"}`，否则 `{"*":"ask"}`）、`compaction:{auto,prune,reserved:20000}`、`mcp` 双形状（v1 `mcp.sa-vm` + v2 `mcp.servers.sa-vm`，任一 CLI 版本都能解析到 `sa-vm` MCP）、relay 时追加 `provider.codex-relay`（`npm:@ai-sdk/openai-compatible`，`baseURL/apiKey/models`）。
- **codex-relay 中转目标**（`opencodeCompatibleRuntime.ts:411` + `opencodeBridge.ts:108`）：relay 模式按 turn 解析 `resolveRelayTarget`，经回环 `codex-relay` provider 下发 `model:{providerID:"codex-relay"}`；`thread/read` 必须回显 `cliBackend=opencode` 才算路由正确，不可静默跑到 opencode-direct 模型。
- **serve 进程复用红线**（`opencodeCompatibleRuntime.ts:338`）：relay 目标或 SA-VM MCP 注入变化后，旧 serve 进程的 `OPENCODE_CONFIG_CONTENT` 已固化，必须重建 serve；严禁复用旧进程继续跑新 relay。
- **prompt 无 system 字段**（`opencodeBridge.ts:44`）：`prompt_async` 没有独立 system-prompt 字段，线程级 SA-VM developer instructions 按 `dev + "\n\n[User Instruction]\n" + prompt` 前置拼接。
- **CLI 发现**（`opencodeCompatibleProbe.ts:30`）：`OPENCODE_BIN / CODEX_UI_OPENCODE_BIN` > 用户首选 > 缓存最新 > PATH（npm 的 opencode.cmd/exe）> 官方安装目录兜底；模型列表解析 `opencode models --verbose`，首个 `/` 前为 provider。
- **skill 发现位**（opencode 源码 `packages/opencode/src/skill/index.ts:24`）：配置目录下 `{skill,skills}/**/SKILL.md`；本文件落盘到 `.opencode/skills/sa-vm/SKILL.md` 即被 opencode skill 工具自动发现，frontmatter `name: sa-vm` 不可改。
- **冒烟验证**（`scripts/opencode-relay-smoke.mjs`）：`thread/start(cliBackend=opencode)` -> `thread/read` 校验 -> `watch` -> `turn/start`（同 relay 选择，180s 等终态 `turn/completed`）-> `unwatch` -> `thread/delete` -> 关 session，diagnostics 归零（thread/watcher/activeTurnHold/subscribed/retrying/leaseBlocked 全 0）。
