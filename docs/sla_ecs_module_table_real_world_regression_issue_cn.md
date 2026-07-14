# sla_ecs Module Table 真实项目复测回归 issue

状态：编译器/SAB 回归已修复；真实性能目标仍开放。

发现时间：2026-07-09。

背景：在 `sa_plugin_sla` 完成 Module Table / imported macro direct-callee pruning / synthetic benchmark 后，按要求切换到 `/home/vscode/projects/sla_ecs`，使用真实 ECS 项目中大量导入和 SA 宏路径复测性能。合成 benchmark 通过，但真实大项目暴露出以下回归/阻塞点。2026-07-09 已修复前端 check/import/Iterable、`parallel_iterator.sla` strict-SAB PhiStateConflict、`system_param_table_erased.sla` focused strict/default SAB，以及 `parallel_table_erased.sla` default/SAB `8701`。本文继续保留性能结论限制。

## 问题 1：`world_table_erased.sla` 前端 check 崩溃（已修复）

复现目录：

```bash
cd /home/vscode/projects/sla_ecs
```

复现命令：

```bash
timeout 180s env SA_PLUGIN_DEV=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' \
  sa sla check lib/world_table_erased.sla
```

历史结果：失败，进程收到 `SIGABRT`，`/usr/bin/time` 记录约 `elapsed=4.46 maxrss=199936`。

关键栈：

```text
thread panic: reached unreachable code
std/hash_map.zig: putAssumeCapacityNoClobberContext
src/plugin.zig:2453 markSyntacticReachableFunc
src/plugin.zig:1427 buildReachableSymbols
src/plugin.zig:1807 expandSlaImports
src/plugin.zig:4407 runSlaCommandImpl
```

修复记录：

- `markSyntacticReachableFunc` 现在把临时 mangled method 符号 canonicalize 到 `funcs.names.getKey(name)` 后再写入 reachable/worklist，避免调用者释放临时 key 后让 `StringHashMap` 持有悬垂 key。
- `buildReachableSymbols` 非 prune root pass 会扫描 root `@test` body，确保 root tests 内引用的 imported generic 函数参与签名导入展开。
- imported module 的 `@test` declarations 不再 flatten 到 root check，避免导入模块测试体把未注册的传递函数调用带入当前 root check。
- 新增 focused Zig 回归：canonical callable key、root tests reachable imported generic refs、contributing imported modules omit tests。

复验结果：`timeout 180s env SA_PLUGIN_DEV=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' sa sla check lib/world_table_erased.sla` 通过，当前约 `elapsed=2.02 maxrss=119296`。

相关下游 check 复验：

- `lib/system_param_table_erased.sla` whole-file check 通过，当前约 `elapsed=4.46 maxrss=236544`；历史 `TemplateNotFound` 不再复现。
- `tests/test_ecs_result_facades.sla` check 通过，当前约 `elapsed=17.14 maxrss=735616`；历史 Iterable/typecheck failure 不再复现。
- `lib/parallel_iterator.sla` check 通过，当前约 `elapsed=3.48 maxrss=189696`；历史 Iterable/typecheck failure 不再复现。

## 问题 2：`parallel_table_erased.sla` 默认 SAB 路径 panic 8701（已修复）

复现目录：

```bash
cd /home/vscode/projects/sla_ecs
```

对照通过命令，generated-SA 路径：

```bash
timeout 180s env SA_PLUGIN_DEV=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' \
  sa sla test lib/parallel_table_erased.sla \
  --test-backend sa --jobs 1 --trace-panic \
  --filter "table erased readonly parallel runner executes no conflict systems on threads"
```

当前结果：通过，约 `elapsed=6.05 maxrss=187264`。

默认 SAB 路径复现命令：

```bash
timeout 180s env SA_PLUGIN_DEV=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' \
  sa sla test lib/parallel_table_erased.sla \
  --jobs 1 --trace-panic \
  --filter "table erased readonly parallel runner executes no conflict systems on threads"
```

历史结果：失败，约 `elapsed=12.89 maxrss=385624`。

关键输出：

```text
error: test table erased readonly parallel runner executes no conflict systems on threads exited with code 125
panic: code=8701
[FAIL] table erased readonly parallel runner executes no conflict systems on threads
test result: FAILED. 0 passed; 1 failed; 0 skipped
```

修复记录：

- decoded std macro template cache 现在在释放 encode buffer 前深拷贝 `sab.decodeModule()` 的 symbol pool，避免 `BOX_NEW` 等宏模板的 placeholder symbol 变成 `0xaa` 悬垂内存。
- std macro template remap 识别 SCI 宏卫生前缀包住的 `__sla_macro_arg_N`，确保输出 placeholder 仍映射到调用方寄存器。
- direct-SAB planned value call-arg consumption 增加当前 block 后续使用保护，避免 `signature: Vec<i32>` 先传给只读收集函数后被过早 `move_`，随后再传给 attach 函数时报 `UseAfterMove`。

复验结果：

- `timeout 300s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' sa sla test lib/parallel_table_erased.sla --test-backend sab --jobs 1 --trace-panic`：1/1 通过，`elapsed=16.37 maxrss=313984`。
- `timeout 300s env SA_PLUGIN_DEV=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' sa sla test lib/parallel_table_erased.sla --jobs 1 --trace-panic`：1/1 通过，`elapsed=13.37 maxrss=314168`。
- `timeout 240s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' sa sla test lib/system_param_table_erased.sla --test-backend sab --filter "table erased entity query commands param defers spawned entity" --jobs 1 --trace-panic`：1/1 通过，`elapsed=22.71 maxrss=638768`。
- `timeout 240s env SA_PLUGIN_DEV=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' sa sla test lib/system_param_table_erased.sla --filter "table erased entity query commands param defers spawned entity" --jobs 1 --trace-panic`：1/1 通过，`elapsed=23.61 maxrss=638820`。

## 问题 3：`parallel_iterator.sla` strict SAB PhiStateConflict（已修复）

历史复现：

```bash
cd /home/vscode/projects/sla_ecs
timeout 240s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' \
  sa sla test lib/parallel_iterator.sla --test-backend sab --jobs 1 --trace-panic
```

历史结果：`PhiStateConflict`，先是局部 `chunk` 在 thread closure 分支 Consumed、直接 planned static call 分支 Active；宽修后又暴露出参数 `values` loop back-edge 与复用的 `pool` 配置 struct 被误 move。

修复记录：

- `src/lowering_rules.zig` 的 planned value call-arg consumption 现在区分 `source_is_param` 和 `source_is_std_owner`。
- 标准 owner local（例如 `Vec<T>`）在 by-value planned static call 后发出 `move_`，与 closure capture 分支保持一致。
- 函数参数只在旧的 result-forwarding / escaping 场景消费，避免 `values` 在循环内第一次 chunk 生成后被误 move。
- 普通 scalar/config struct（例如 `EcsParallelTaskPool`）不会因为 planned call 被当作 owner move，避免同一测试中 collect/map 复用 `pool` 时 UseAfterMove。
- 新增 compiler fixture：`tests/test_unit_thread_closure_direct_call_merge_direct.sla`。

复验结果：

- local strict-SAB new fixture：1/1 通过。
- installed strict-SAB new fixture：1/1 通过。
- local `lib/parallel_iterator.sla` whole-file strict-SAB：10/10 通过，`elapsed=6.78 maxrss=189868`。
- installed `lib/parallel_iterator.sla` whole-file strict-SAB：10/10 通过，`elapsed=6.42 maxrss=240324`。
- local/installed `lib/parallel.sla` strict-SAB guard：1/1 通过。

## 性能结论限制

当前只能确认：

- Synthetic benchmark 已覆盖重复 `.sla` import、fanout dead-code、单 imported macro、重复多 `.sa` macro import + 展平，且当前 CLI 默认规模能在亚秒级完成。
- 真实 `sla_ecs` 的 `parallel_table_erased.sla` generated-SA focused test 可跑通，约 6 秒。
- 真实 `sla_ecs` 的最大 table-erased world 前端 check 已不再被 `StringHashMap` 断言阻塞，但性能仍未达到目标。
- 默认/SAB focused compiler blockers 已不再复现，但这些通过结果只能证明 SAB cleanup 已恢复，不能作为 Module Table 前端性能达标的证据。

## 真实 profile 证据

`examples/parallel_query.sla` focused generated-SA：

```bash
timeout 180s env SA_PLUGIN_DEV=1 SLA_PROFILE=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' \
  sa sla test examples/parallel_query.sla \
  --test-backend sa --jobs 1 --trace-panic \
  --filter "parallel query demo reads shared table erased world snapshot on threads"
```

结果：通过，`elapsed=4.36 maxrss=161664`。

```text
[sla-profile] parse: 294ms
[sla-profile] import expand: 979ms
[sla-profile] load contracts: 329ms
[sla-profile] import aliases: 279ms
[sla-profile] pre-typecheck reachable decl filter: 4ms
[sla-profile] type check: 13ms
[sla-profile] sa codegen: 25ms
```

`lib/parallel_table_erased.sla` focused generated-SA：

```bash
timeout 180s env SA_PLUGIN_DEV=1 SLA_PROFILE=1 /usr/bin/time -f 'elapsed=%e maxrss=%M' \
  sa sla test lib/parallel_table_erased.sla \
  --test-backend sa --jobs 1 --trace-panic \
  --filter "table erased readonly parallel runner executes no conflict systems on threads"
```

结果：通过，`elapsed=5.33 maxrss=187392`。

```text
[sla-profile] parse: 271ms
[sla-profile] import expand: 1270ms
[sla-profile] load contracts: 334ms
[sla-profile] import aliases: 285ms
[sla-profile] pre-typecheck reachable decl filter: 7ms
[sla-profile] type check: 20ms
[sla-profile] sa codegen: 34ms
```

解释：当前 Module Table 改动没有把真实 `sla_ecs` 路径压到几百毫秒。真实 focused generated-SA 用例中，SLA 前端仍约 1.9s，主要耗在 `import expand`、`parse`、`load contracts`、`import aliases`；总耗时剩余部分来自生成后的 `sa test` 链路。因此合成 benchmark 只能证明小型重复导入/宏 fixture 没有明显退化，不能证明真实 ECS 大导入图已经达到目标。

2026-07-09 追加：当前 compiler cleanup 已消除 `import aliases` 阶段的重复 SLA import 解析。`src/plugin.zig` 复用 import expansion 阶段建立的 `SlaModuleTable` 和 root resolved imports，安装版真实 ECS profile 复测为：

```text
parallel_table_erased.sla focused generated-SA: import aliases 0ms
parallel_query.sla focused generated-SA: import aliases 4ms
```

这只关闭 alias 重复解析子问题；`import expand`、`parse`、`load contracts` 仍是主要剩余性能目标。

2026-07-09 再追加：当前 compiler cleanup 又消除了两处 source expansion 重复工作：没有 `@expand_tuple` 的 source 走 owned-copy fast path，imported macro/contract 递归加载使用已经展开的 source，不再二次 expand。安装版真实 ECS profile 当前为：

```text
parallel_table_erased.sla focused generated-SA: import expand 1303ms, load contracts 320ms, import aliases 0ms
parallel_query.sla focused generated-SA: import expand 893ms, load contracts 245ms, import aliases 3ms
```

这仍不是最终性能目标；剩余大项仍是 true shallow scan / lazy body parsing，以及 reachable-only contract loading。

2026-07-09 三追加：当前 compiler cleanup 又关闭了一条 contract-loading 重复 I/O 路径。`src/plugin.zig` 在 import expansion 阶段收集已经 resolved 的非 SLA imports（`.sa/.sai/.sal`），后续 `loadImportedContractsFromResolvedImports()` 直接使用 `ResolvedImport.source` 加载 contracts/imported macros，不再对这些已输出的非 SLA imports 做第二次 resolve/read。新增回归会在 expansion 后删除 `.sa` 和 `.sai` 源文件，验证 contract loading 仍使用已解析 source。安装版真实 ECS profile 当前为：

```text
parallel_table_erased.sla focused generated-SA: import expand 962ms, load contracts 198ms, import aliases 0ms
parallel_query.sla focused generated-SA: import expand 809ms, load contracts 270ms, import aliases 5ms
```

这仍不是完整的 reachable-only contract loading：contract source 仍会被扫描/解析，真实剩余大项仍是 true shallow scan / lazy body parsing，以及只为可达模块/符号构建 contract 数据。

2026-07-09 四追加：当前 compiler cleanup 增加了一个 imported-module lazy parsing 子切片。`src/parser.zig` 支持 parser options 和 token-balanced block skip；`SlaModuleTable.getOrParse()` 解析 imported `.sla` module 时设置 `parse_test_bodies = false`，因为 imported module 的 `@test` declarations 当前不会 flatten 到 root expansion。新增回归在 imported module 的 `@test` body 中放入 parser-invalid 语法，验证 Module Table import expansion 仍成功并 materialize imported function。安装版真实 ECS profile 当前为：

```text
parallel_table_erased.sla focused generated-SA: parse 408ms, import expand 963ms, load contracts 212ms, import aliases 0ms
parallel_query.sla focused generated-SA: parse 323ms, import expand 707ms, load contracts 266ms, import aliases 5ms
```

这只是 imported `@test` body 的 lazy-skip，不是完整函数体懒解析。`parallel_query.sla` 的 `import expand` 有实测改善；`parallel_table_erased.sla` 基本持平并有 parse 噪声。剩余真实性能目标仍是 uncalled imported function body lazy parsing，以及 full reachable-only contract loading。

2026-07-09 五追加：当前 compiler cleanup 又减少了一条 root parse duplicate-work 路径。`src/parser.zig` 的 parser options 拆成 `parse_function_bodies`、`parse_macro_bodies`、`parse_test_bodies`；递归 `.sla` import type pre-scan 现在只收集 imported type/module names，不再解析 imported function/macro/test bodies。新增回归会从含 parser-invalid function body 的 imported file 中读取 struct 类型名，验证 root parser 仍能识别 imported struct literal。安装版真实 ECS profile 当前为：

```text
parallel_table_erased.sla focused generated-SA: parse 234ms, import expand 868ms, load contracts 204ms, import aliases 0ms
parallel_query.sla focused generated-SA: parse 259ms, import expand 683ms, load contracts 271ms, import aliases 5ms
```

这仍不是完整函数体懒解析：Module Table/import expansion 阶段仍会 materialize 或扫描大量未调用 imported function bodies，contract loading 仍未做到 full reachable-only。当前可确认的收益是 parser 的 imported type pre-scan 不再重复解析 body；剩余真实性能目标仍是 uncalled imported function body lazy materialization，以及只为可达模块/符号构建 contract 数据。

2026-07-09 六追加：当前 compiler cleanup 把浅解析再推进到 `sa sla check` 路径。`SlaModuleTable` 新增可配置 parser options；默认 build/test 路径仍保留 imported function body parsing，而 `sa sla check` 的 import Module Table 使用 `parse_function_bodies = false` 和 `parse_test_bodies = false`，继续保留 imported macro bodies。新增回归会导入一个 body 内含 parser-invalid 语法的函数，验证 check 仍能从 imported signature 完成。

安装版真实 ECS check 复验：

```text
world_table_erased.sla check: pass, elapsed=1.65 maxrss=105088
system_param_table_erased.sla check: pass, elapsed=3.77 maxrss=125056
```

这只关闭 check-mode 解析 imported function body 的重复工作；不改变 build/test generated-SA 的当前 profile 结论。generated-SA 仍需要真正的 reachable body materialization 和 reachable-only contract loading。

2026-07-09 七追加：当前 compiler cleanup 对 `load contracts` 做了一个队列级裁剪。plain `.sa` imports 如果没有 `[MACRO]`、没有 `@import`、也没有 `@expand_tuple`，仍会保留为输出 import，但不再进入 TypeChecker contract/imported-macro loading queue；`.sai`、`.sal`、含 macro/import/tuple expansion 的 `.sa` 仍会加载。contract loader 也会在 expanded source 不含 `@import` 时跳过逐行 import scan，不含 `[MACRO]` 时跳过 imported macro scan。新增回归覆盖 macro-free source fast path，并扩展 resolved non-SLA import reuse：一个 plain `.sa` helper 在 expansion 后被删除，contract loading 仍只依赖 queued macro `.sa` 和 `.sai`。

安装版真实 ECS generated-SA profile 当前为：

```text
parallel_table_erased.sla focused generated-SA: parse 198ms, import expand 798ms, load contracts 204ms, import aliases 0ms
parallel_query.sla focused generated-SA: parse 305ms, import expand 808ms, load contracts 283ms, import aliases 5ms
```

安装版真实 ECS check 复验：

```text
world_table_erased.sla check: pass, elapsed=1.36 maxrss=104832
```

这仍不是 full reachable-only contract loading：当前只是避免把完全不提供 contract/macro surface 的 plain `.sa` 放入 contract-loading 队列。`parallel_query.sla` 本轮 profile 仍有噪声，说明主要剩余成本仍在实际 contract parsing/scanning 和 imported body materialization。

2026-07-09 八追加：当前 compiler cleanup 把浅解析推进到非 test-codegen build 路径。`SlaModuleTable` 现在保存 module source 和 function body 是否已解析；非测试 build import expansion 可先用 imported signatures 浅解析模块，再只对含有可达 function/method body 的模块原地 full-parse materialize，并重新计算可达性以补上同模块/helper/transitive 调用。新增回归 `sla build codegen skips parsing non contributing imported function bodies` 会导入一个未贡献输出的 `.sla` 文件，其中函数体包含 parser-invalid 语法，验证普通 build codegen 仍能成功并只输出实际可达符号。

重要边界：这个两阶段 shallow-then-materialize 当前只启用于 `prune_for_test_codegen = false` 的非测试 build 路径；test-codegen 仍保留之前的 full-parse 策略。原因是实际 `sla_ecs` focused test profile 显示在测试路径启用两阶段策略会 double-parse 过多模块，导致 `import expand` 明显回退。因此这次改动是架构上的非测试 build 懒解析入口，不是 focused generated-SA 测试延迟目标的最终修复。

安装版真实 ECS focused generated-SA profile 当前为：

```text
parallel_table_erased.sla focused generated-SA: parse 254ms, import expand 875ms, load contracts 238ms, import aliases 0ms
parallel_query.sla focused generated-SA: parse 270ms, import expand 754ms, load contracts 246ms, import aliases 4ms
```

这批数字相对上一轮有噪声，不能过度解读为性能改善；它们主要证明当前实现没有重新引入前端/SAB 阻塞。剩余真实性能目标仍是 test-codegen 可用的 uncalled imported function body lazy materialization，以及 full reachable-only contract loading。

2026-07-09 九追加：当前 compiler cleanup 对 test-codegen imported-macro preload 队列做了可达性裁剪。此前 `prune_for_test_codegen` 为了让 imported `.sa` macro direct callees 参与 reachability，会在真正计算可达性前加载 root imports 以及所有 imported `.sla` modules 的非 SLA imports；这会让完全不贡献当前 focused test 的死模块也提前扫描/解析 `.sai/.sal/.sa`。现在 import expansion 先只预加载 root 非 SLA imports，计算一次 reachability，再只为当前 contributing imported modules 加载非 SLA imports；如果新加载的 imported macros 带来 direct callees，则重新计算 reachability，直到没有新 contract imports。新增回归覆盖两边：死 imported module 中 parser-invalid `.sai` 不再被加载；contributing imported module 自己 import 的 macro 仍会加载，并保留 macro direct callee。

安装版真实 ECS focused generated-SA profile 当前为：

```text
parallel_table_erased.sla focused generated-SA: parse 281ms, import expand 1178ms, load contracts 272ms, import aliases 0ms
parallel_query.sla focused generated-SA: parse 256ms, import expand 688ms, load contracts 223ms, import aliases 4ms
```

这仍不能宣称性能目标完成：`parallel_table_erased.sla` 本轮 `import expand/load contracts` 有噪声上升，`parallel_query.sla` 有局部改善。当前可确认的是 test-codegen 的 imported-macro preload 不再无差别加载死 SLA module 的 contract/macro imports。剩余真实性能目标仍是 uncalled imported function body lazy materialization，以及更完整的 reachable-only contract scanning。

2026-07-09 十追加：当前 compiler cleanup 又收窄了 imported module contract 队列。此前 “contributing module” 同时包含类型贡献和函数/const/macro 贡献；如果 focused test 只使用 imported module 的 struct/enum/trait/type alias，该模块自己的 `.sai/.sal/.sa` imports 仍可能进入 pre-typecheck imported-macro preload 或最终 contract-loading queue。现在 `src/plugin.zig` 将这两类贡献分开：type-only imported module 仍会 flatten 所需类型声明，但不会加载该模块中只服务于死函数/死宏的非 SLA contract imports；只有可达 function/method body 或被引用的 const/macro surface 会触发这些 imports。新增回归 `sla test codegen skips contract loading for type only imported modules` 覆盖 imported struct 被 root test 使用、但同模块 dead `.sai` 语法无效的场景。

安装版真实 ECS focused generated-SA profile 当前为：

```text
parallel_table_erased.sla focused generated-SA: parse 240ms, import expand 890ms, load contracts 199ms, import aliases 0ms
parallel_query.sla focused generated-SA: parse 297ms, import expand 754ms, load contracts 270ms, import aliases 4ms
```

这仍是队列级 correctness/perf cleanup，不是完整 reachable-only contract loading。`parallel_table_erased.sla` 本轮较上一轮噪声样本改善，`parallel_query.sla` 则回到较高 load-contract 数字；不能据此声称 latency target 已关闭。剩余真实性能目标仍是 test-codegen 可用的 uncalled imported function body lazy materialization，以及按符号/模块的 contract scanning。

2026-07-09 十一追加：当前 compiler cleanup 又收窄了 focused test-codegen 的 SLA 宏体可达性。此前 syntactic reachability 会把所有 local/imported `.sla` `macro_decl` body 当作初始 root 扫描，导致未调用宏体内的 helper function/type 也被加入 reachable set，并可能在 TypeChecker/monomorphizer 阶段处理死宏体。现在只有实际 call 到本地 SLA macro 时，才把 macro name 记录为 referenced symbol root；随后 `scanReferencedSymbolRoots()` 扫描该 macro body。未引用的 macro declaration 会在 import expansion 和 pre-typecheck pruning 阶段被过滤掉。新增回归 `sla test codegen prunes unreferenced sla macro bodies` 覆盖 root 与 imported module 中未使用宏体引用 typecheck-invalid helper 的场景。

安装版真实 ECS focused generated-SA profile 当前为：

```text
parallel_table_erased.sla focused generated-SA: parse 248ms, import expand 952ms, load contracts 244ms, import aliases 0ms, pre-typecheck reachable decl filter 8ms, elapsed=4.87 maxrss=113920
parallel_query.sla focused generated-SA: parse 220ms, import expand 712ms, load contracts 239ms, import aliases 3ms, pre-typecheck reachable decl filter 7ms, elapsed=4.05 maxrss=104576
```

这属于死宏体语义剪枝，不是完整性能目标关闭。当前可以确认未调用 SLA macro 不再把 helper body 拉进 focused test-codegen 的可达图和类型检查；剩余真实性能目标仍是 test-codegen 可用的 uncalled imported function body lazy materialization，以及更完整的 reachable-only contract scanning。

下一步建议：

1. 把下一轮性能验收门槛换成真实 `sla_ecs` profile：`parallel_query.sla` 和 `parallel_table_erased.sla` focused generated-SA 的 SLA 前端阶段已从历史约 1.9s 降到当前约 1.2-1.3s，但仍应继续压到几百毫秒级，再谈整体命令耗时。
2. 继续实现真正的浅层扫描/懒解析：当前代码已跳过 imported tests，在非测试 build 路径支持浅解析后 materialize 可达模块，并让 test-codegen imported-macro preload 只加载 root + contributing module 的 contract imports；但 focused test-codegen 仍会解析大量未触达函数体，contract 数据也尚未做到完整按符号/模块可达性裁剪。这些才是 `import expand`、`parse`、`load contracts` 的主耗时。`import aliases` 已降到近零，已解析非 SLA imports 也不再被重读，但仍应保留 profile gate 防止回归。
3. 继续复跑 `world_table_erased.sla`、`system_param_table_erased.sla`、`parallel_table_erased.sla`、`examples/parallel_query.sla` 的 generated-SA focused/profile gates，避免性能修复重新引入前端 check/import 回归。
4. 默认/SAB `8701` 已在当前 compiler cleanup 切片中复验通过；后续仍应保留这些 focused strict/default gates，防止性能改动重新引入 SAB 后端回归。

## 2026-07-13 namespace-local helper binding checkpoint

Selective reachable-body materialization exposed a remaining namespace collision: if `dep.sla` and `sibling.sla` both define `entry()` calling a local `helper()`, reachability can correctly select `dep__helper` and `sibling__helper`, but flattening duplicate raw `helper` declarations previously caused TypeChecker `Redeclaration`.

Current correction:

- namespace-only reachable imported functions no longer require duplicate raw function declarations;
- while checking an imported alias function, TypeChecker resolves a raw call against the current namespace alias first;
- `resolved_call_symbols` retains the historical raw target, while `resolved_call_alias_metadata` carries the namespace/module identity consumed by both SA and SAB emitters;
- regression `sla test codegen qualifies same named imported helper reachability` asserts both alias helper declarations and both module-qualified SA call targets.

Serial verification passed: same-name helper 2/2, selective reachable bodies 1/1, Module Table 15/15, imported alias metadata 2/2, `zig build -j1 --summary all` 7/7, `zig build test -j1 --summary all` 210/210, official dev install/help.

Installed real ECS focused generated-SA profiles also pass, but this sample is a performance regression rather than closure:

```text
parallel_query.sla: parse 291ms, import expand 868ms, load contracts 0ms, import aliases 4ms, elapsed 4.34
parallel_table_erased.sla: parse 246ms, import expand 1156ms, load contracts 0ms, import aliases 0ms, elapsed 5.23
```

Profile detail shows the remaining tail in import root resolution and repeated reachability/materialization extension, including several passes over the large `world_table_erased.sla` module. Therefore the real latency target remains open. This checkpoint also does not claim full namespace isolation for imported const initializers, SLA macro bodies, types, or every raw AST binding; those belong in the Typed HIR/module symbol identity work.
