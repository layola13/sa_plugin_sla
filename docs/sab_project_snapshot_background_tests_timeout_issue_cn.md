# SAB project snapshot/project collection/config registry/API 单测 10 秒无输出超时

日期：2026-07-07

## 现象

`sla_tsgo` 中拆分后的 project snapshot / project collection / config registry / API 单测在 strict SAB 模式下 10 秒无输出超时，退出码 124。相同环境下 `test_core_contract.sla` 可以通过，说明 SAB 后端基础执行可用，问题集中在导入 `members/project/src/snapshot.sla` 并调用 project session snapshot / collection / config registry / API 路径的小单元。

## 环境

- 仓库：`/home/vscode/projects/mnt/sla_tsgo`
- 后端：`--test-backend sab`
- 环境变量：`SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1`
- 超时策略：所有测试命令外层使用 `timeout 10s`

## 可复现命令

```sh
cd /home/vscode/projects/mnt/sla_tsgo

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_background_update_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_background_warm_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_background_wait_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_collection_default_cache_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_collection_open_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_config_registry_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_snapshot_config_registry_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_api_open_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_api_update_contract.sla --test-backend sab
```

这些命令均表现为 10 秒内没有 stdout/stderr，`timeout` 返回 124。`test_project_collection_default_cache_contract.sla` 已在 SLA 编译器 ReleaseFast rebuild 后额外串行复核，仍然 10 秒无输出超时。`test_project_api_open_contract.sla` 和 `test_project_api_update_contract.sla` 于 2026-07-07 追加复核，仍是 strict SAB 10 秒无输出超时。

## 对照命令

```sh
timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_core_contract.sla --test-backend sab
```

该命令通过：5 passed。

## 静态检查

以下命令均通过：

```sh
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/project/src/snapshot.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_background_update_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_background_warm_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_background_wait_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_collection_default_cache_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_collection_open_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_config_registry_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_snapshot_config_registry_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_api_open_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_api_update_contract.sla
```

## 最小化状态

测试已经从大的 `tests/test_project_contract.sla` 拆成单测试文件，每个文件只包含一个 `@test`。background 单测使用 synthetic `SessionState` / `project_empty_program()` 构造 project snapshot，避免 parser/program 文本扫描路径干扰；project collection 单测只覆盖 `ProjectCollection.fileDefaultProjects` / open configured project 小路径；config registry 单测只覆盖 fixed-capacity `ConfigFileRegistry` lookup、ancestor 和 snapshot/collection registry retention；API 单测只覆盖 `APIOpenProject`/`APIUpdateWithFileChanges` 的固定容量 `apiOpenedProjects` 状态和 pending flush/scheduled update cancellation。

## 2026-07-07 Module Table 复核

`sa_plugin_sla/src/plugin.zig` 已加入第一阶段 `SlaModuleTable`：同一次 import expansion 内按 resolved path 缓存已解析 `.sla` AST，并用 emitted set 防止重复 append。同一轮复核确认该 stopgap 没有解决本工单的大型 unique import graph：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla sab build tests/test_project_background_update_contract.sla \
  --out /tmp/project_background_update.sab
```

结果：`timeout` 退出码 124。已输出 profile：

- `parse`: 2313ms
- `import expand`: 5679ms
- `monomorphize`: 28ms
- `load contracts`: 861ms

判断：当前瓶颈仍在 SLA 前端导入展开/全量 flatten 后续流程。Module Table 防重复解析只能处理重复 import，对 project snapshot 这类大量唯一模块的图不够；后续需要 shallow exported-symbol index、namespace isolation 和 lazy typecheck，避免把所有 imported function body 拼进当前 program 后一起 typecheck。

## 2026-07-07 test-codegen 可达裁剪复核

`sa_plugin_sla/src/plugin.zig` 已在 test-input 生成路径启用 `pre-typecheck reachable decl filter`，并在 typecheck 后、direct-SAB codegen 前启用精确 `reachable decl filter`。两者都会裁掉未被当前 `@test` 可达的顶层函数和 inherent impl/overload 方法，但保留 trait impl 整组以避免 vtable 破洞。复核命令使用真实 `sla test` 路径：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_project_background_update_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.05 maxrss 339712`。已输出 profile：

- `parse`: 2280ms
- `import expand`: 5495ms
- `monomorphize`: 33ms
- `pre-typecheck reachable decl filter`: 26ms
- `load contracts`: 678ms
- `type check`: 551ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 1ms

判断：test-path 可达裁剪已把 typecheck 压到约 0.5s，post-typecheck output filter 本身约 1ms，但本工单仍未修复。当前最大前端成本仍是 import expand 约 5.5s，且 timeout 发生在 reachable decl filter 之后、direct-SAB codegen/test 执行完成前。下一步需要 ModuleGraph/shallow symbol index，避免把大量唯一 imported AST 先拼接展开；同时 direct-SAB codegen 需要按可达 test 子图加载 std/helper 依赖。

## 2026-07-07 import-expansion 可达体裁剪复核

`sa_plugin_sla/src/plugin.zig` 的 test-codegen 路径现在会在 import expansion 前先收集 `.sla` Module Table/ModuleGraph，按当前选中 `@test` 的语法调用闭包只扁平化可达的 imported top-level function 和 inherent impl/overload 方法。类型、trait、const、macro 和 trait impl 仍保留，避免破坏 typecheck/vtable 安全。复核仍使用真实 `sla test` 路径和 10 秒硬超时：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_project_background_update_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.04 maxrss 364416`。已输出 profile：

- `parse`: 1966ms
- `import expand`: 4834ms
- `monomorphize`: 4ms
- `pre-typecheck reachable decl filter`: 3ms
- `load contracts`: 696ms
- `type check`: 330ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 1ms

判断：import-expansion 可达体裁剪使 typecheck 继续下降到约 0.33s，import expand 从上一轮约 5.5s 降到约 4.8s，但本工单仍未关闭。当前剩余瓶颈仍包括 parser/import graph 预扫描、唯一模块解析和 reachable filter 之后的 direct-SAB codegen/依赖加载；下一步需要真正的 shallow signature index、命名空间隔离和 lazy codegen dependency loading，而不是继续把大量 imported body 拼入当前 program。

## 2026-07-07 vtable-aware trait impl 裁剪复核

`sa_plugin_sla/src/plugin.zig` 已在 typecheck 后、direct-SAB codegen 前加入 vtable-aware trait impl 输出裁剪：只有在 trait impl 没有任何可达 trait 方法，且当前可达测试/函数没有 dyn borrow、Box dyn 或 Rc dyn vtable 证据时，才会删除整组 trait impl；需要 vtable 的 impl 仍整组保留。`tests/test_unit_rc_dyn_trait.sla` strict SAB 10 秒 guard 已通过，证明此前的 vtable `UnknownRegister` 风险没有复现。

复核本工单真实路径：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_project_background_update_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.04 maxrss 343040`。已输出 profile：

- `parse`: 2136ms
- `import expand`: 5685ms
- `monomorphize`: 4ms
- `pre-typecheck reachable decl filter`: 2ms
- `load contracts`: 741ms
- `type check`: 399ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 1ms

判断：vtable-aware trait impl 裁剪是安全的 codegen 前缩减，但对 project background timeout 没有实质改善。本工单仍主要受 parser/import expansion 和 reachable filter 后续 direct-SAB/codegen 依赖加载影响。

## 期望

SAB 应在 10 秒窗口内完成这些单测试的编译和执行；如果有所有权或运行期错误，应输出具体 trap，而不是无输出挂到外层 timeout。

## 2026-07-07 callable index 进展记录

`sa_plugin_sla/src/plugin.zig` 的 test-codegen 可达性阶段现在建立 `SlaCallableIndex`：root/imported `.sla` declarations 只注册一次 callable name 与函数/方法 body，之后 worklist 通过哈希表直接取 body，而不是每个 reachable name 都重新扫描 root 和所有 imported module 的 decls。

当前验证：

- `zig fmt --check src/plugin.zig`
- `zig build test -Dtest-filter="sla test import expansion prunes unreachable imported functions" --summary all`
- `zig build test -Dtest-filter="sla test codegen prunes unreachable functions before type checking" --summary all`
- `zig build --summary all` 通过，约 40.94s，MaxRSS 约 1GB
- `zig build test --summary all` 通过，99/99，约 53.60s，MaxRSS 约 1.1GB
- `SA_PLUGIN_DEV=1 sa sla help` 通过

安装器 gate 后续已恢复：根因是安装器固定执行 `zig build -Doptimize=ReleaseFast`，而本插件 ReleaseFast 构建直接跑 300s 仍无输出超时。`build.zig` 现在只在 `SA_PLUGIN_DEV=1/true` 下把安装器请求的 ReleaseFast 映射为 Debug，`SA_PLUGIN_DEV=1 sa plugin install --dev .` 已恢复到约 0.31s。非 dev ReleaseFast 行为保持不变，仍是独立的编译耗时问题。

复核本工单真实路径仍使用 10 秒硬超时：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_project_background_update_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.03 maxrss 358016`。已输出 profile：

- `parse`: 1851ms
- `import expand`: 5189ms
- `monomorphize`: 3ms
- `pre-typecheck reachable decl filter`: 1ms
- `load contracts`: 559ms
- `type check`: 309ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 1ms

判断：这是 ModuleGraph/lazy traversal 的数据结构基础，能消除当前早期可达分析里的重复全图 decl 扫描，但尚未关闭本工单。导入声明仍会 flatten 到当前 program，TypeChecker/monomorphizer 仍沿用现有合约；还需要 shallow exported-signature index、namespace isolation、lazy imported-body typecheck，以及 reachable filter 之后 direct-SAB codegen/依赖加载的按需化。

安装 gate 恢复后又用已安装 dev 插件复核一次，仍为 `timeout` 退出码 124，`elapsed 10.04 maxrss 429184`。profile：

- `parse`: 1670ms
- `import expand`: 4380ms
- `monomorphize`: 2ms
- `pre-typecheck reachable decl filter`: 2ms
- `load contracts`: 632ms
- `type check`: 299ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 1ms

判断不变：本工单仍未关闭，主要瓶颈仍是大型 import graph 与 reachable filter 之后的 direct-SAB codegen/依赖加载。

## 2026-07-08 associated callable candidate index 进展记录

`sa_plugin_sla/src/plugin.zig` 的 `SlaCallableIndex` 现在不只缓存 callable name 与 body，也在注册 mangled inherent/trait/overload method 时建立短方法名到候选 symbol 的索引。test-codegen 可达性遇到 `item.method()` / `Type::method()` 时直接查候选表，替代此前对所有 callable name 的后缀扫描。

新增回归：`sla test import expansion prunes unreachable imported methods`，覆盖 imported `impl` 中保留被调用方法、剪掉未调用且含缺失符号的方法。该切片保持当前 flatten/typecheck 合约，只减少可达性索引成本，不声称完成 namespace isolation 或 lazy imported-body typecheck。

当前验证：

- `zig fmt src/plugin.zig`
- focused imported-method/imported-function/pre-typecheck pruning Zig tests
- `zig build --summary all`
- `zig build test --summary all` 通过，100/100
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- `SA_PLUGIN_DEV=1 sa sla help`
- local/installed strict SAB guards: `tests/test_unit_impl_static_methods.sla`, `tests/test_unit_rc_dyn_trait.sla`, `tests/test_unit_sla_import.sla`

复核本工单真实路径仍使用 10 秒硬超时：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_project_background_update_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.04 maxrss 391168`。已输出 profile：

- `parse`: 1577ms
- `import expand`: 4235ms
- `monomorphize`: 4ms
- `pre-typecheck reachable decl filter`: 0ms
- `load contracts`: 619ms
- `type check`: 347ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 0ms

判断不变：本工单仍未关闭。该切片消除了方法候选的全符号扫描，但剩余主要瓶颈仍是大型 import graph、真正的 exported-signature/lazy imported-body typecheck，以及 reachable filter 之后的 direct-SAB codegen/依赖加载。

## 2026-07-09 hidden UseAfterMove 修复与剩余超时

在继续复核 `tests/test_project_background_update_contract.sla` 时，较长超时窗口暴露出一个被 10 秒 timeout 掩盖的 direct-SAB 所有权错误：`members/project/src/snapshot.sla:1565` 的 `project_session_enqueue_update_snapshot_background_work` 把 by-value `ProjectSnapshotChange change` 传给 `project_snapshot_change_should_warm_auto_import_cache(change)` 后，后续分支仍读取 `change.active_file` / `change.active_file_len`。`ProjectSnapshotChange` 字段均为 primitive/pointer/bool 这类浅拷贝安全字段，但 direct-SAB 原先按 owner move 消耗了原始 `change`，导致 `UseAfterMove`。

`src/sab_codegen.zig` 已加入保守的浅拷贝保留规则：仅当 by-value 参数来自标识符、该标识符在当前表达式或分支后续仍会使用、类型是用户定义且字段递归浅拷贝安全的 struct，且不是 Copy/borrow-like/std owner 时，planned call 才传入浅拷贝而不是消耗原始 owner。`genIfValue()` / `genIfStatement()` 也把 then/else 分支体压入条件表达式的 later-use 上下文，使 `if predicate(change) { change.field }` 能被识别。新增 `tests/test_unit_shallow_copy_call_arg_direct.sla` 覆盖 predicate 调用后继续读取浅拷贝安全 struct 字段的 true/false 分支。

同轮追加了两个只影响 direct-SAB codegen 的低风险辅助改动：

- `SLA_SAB_PROFILE=1` 内部 profile，用于打印 direct-SAB 阶段和超过 25ms 的 decl codegen 耗时。
- 字符串 literal UTF8 const 标签缓存：重复的源码字符串 literal 复用同一个 SAB `utf8` 常量标签，但每次表达式仍独立生成运行时 Slice 值，不改变所有权语义。该切片主要减少重复常量生成/解码，不能单独关闭 10 秒问题。

已验证过一个无效优化方向并回退：把 planned-call sibling later-use 上下文从“所有兄弟参数”收窄为“仅后序参数”会让 `tests/test_unit_struct_literal_call_arg_later_field_direct.sla` 的 `outer call sibling` 用例重新触发 `UseAfterMove`，因此不能作为当前性能路径继续推进。

验证已串行通过：

- `zig fmt --check src/sab_codegen.zig`
- `zig build test -j1 --summary all`，147/147
- `zig build -j1 --summary all`，7/7
- 本地和已安装 strict SAB 新 fixture，2/2
- 本地 SA-text 新 fixture，2/2
- 相关回归：`test_unit_struct_literal_call_arg_later_field_direct.sla`、`test_unit_reused_vec_value_call_direct.sla`、`test_unit_thread_closure_direct_call_merge_direct.sla`
- 官方 dev install/help gate
- 已安装下游长窗口命令通过：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
timeout 90s /usr/bin/time -f 'elapsed %e maxrss %M' env SA_PLUGIN_DEV=1 SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  sa sla test tests/test_project_background_update_contract.sla --test-backend sab --jobs 1 --trace-panic
```

旧一轮结果：1/1 passed，`elapsed 12.79 maxrss 303488`，其中 `sab direct codegen: 8413ms`。

最新安装态长窗口复核仍通过：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
timeout 120s /usr/bin/time -f 'elapsed %e maxrss %M' env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_background_update_contract.sla --test-backend sab --jobs 1 --trace-panic
```

结果：1/1 passed，`elapsed 12.19 maxrss 308992`，其中 `sab direct codegen: 7413ms`。

内部 direct-SAB profile 的代表热点仍集中在顶层 decl 生成：`top-level decls` 约 7.6-7.9s，`test project session update snapshot enqueues background work` 约 2.6-3.4s；慢函数还包括 `path_copy_normalized_input`、`program_empty_source_file`、`program_empty_resolved_module_entry`、`program_options_default`、`project_config_file_registry_from_config` 等默认构造/项目配置路径。

10 秒硬超时仍未关闭。当前代表命令仍会在 10 秒外层 timeout 下退出 124：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
timeout 20s /usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_background_update_contract.sla --test-backend sab --jobs 1 --trace-panic
```

最新 10 秒证据仍为 124：`elapsed 10.02 maxrss 288128`，frontend 已输出 `parse 854ms`、`import expand 2857ms`、`load contracts 498ms`、`type check 356ms`，但尚未输出 `sab direct codegen` profile 行即被 timeout 截断。判断：本工单完成度约 65%。隐藏 owner-state trap 已修复；剩余关闭条件是把 direct-SAB codegen/std dependency loading 和前端剩余成本压进 10 秒窗口。

## 2026-07-09 direct Slice literal codegen 与 Copy 标量局部复用

继续压 10 秒窗口时确认 `SLICE_NEW` std macro fragment 是 direct-SAB codegen 的主要重复成本之一。`src/sab_codegen.zig` 现在对字符串 literal 直接结构化生成 Slice：复用/创建 UTF8 const 标签后，生成 stack Slice，borrow const pointer，并直接 store `SliceAbi.ptr_offset` / `SliceAbi.len_offset`，不再为每个 string literal 展开 `sa_std/core/slice.sa:SLICE_NEW` fragment。该改动不改变运行时所有权：每个表达式仍返回独立 stack Slice，Slice 仍标记为 non-owning。

验证后，代表 background 用例已经进入 10 秒窗口：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
timeout 20s /usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_background_update_contract.sla --test-backend sab --jobs 1 --trace-panic
```

结果：1/1 passed，`elapsed 7.60 maxrss 221696`，其中 `sab direct codegen: 2691ms`。本地同路径最好证据为 `elapsed 5.80 maxrss 170240`，`sab direct codegen: 1742ms`。同一组 background 另外两个 10 秒门禁也已通过：

- `tests/test_project_background_warm_contract.sla`
- `tests/test_project_background_wait_contract.sla`

同轮继续复核 `tests/test_project_collection_default_cache_contract.sla`，长窗口暴露出另一个被 timeout 掩盖的 direct-SAB correctness 缺口：`members/packagejson/src/packagejson.sla:462` 的 `let ti = pkg_find_star(...); if ti < 0 { ... }; let before_len = ti;` 会在 Copy 标量局部先参与比较后再次读取时触发 `UseAfterMove`。此前只对 by-value Copy 参数做过 entry stack-slot 复用保护，普通 let 绑定的 Copy 标量局部仍可能被 SAB `op` 消耗。

`src/sab_codegen.zig` 现在会在 primitive Copy let 绑定后续仍在当前 block 使用时为该 binding 建 stack slot，后续 identifier 读取通过 load fresh temp 参与 SAB op。新增/扩展 `tests/test_unit_sab_binary_copy_param_direct.sla`，覆盖函数返回 Copy 标量局部先比较再继续读取。安装态 strict-SAB fixture 通过 2/2。

`tests/test_project_collection_default_cache_contract.sla` 的隐藏 `ti` trap 已修复，长窗口通过：

```sh
timeout 90s /usr/bin/time -f 'elapsed %e maxrss %M' env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_collection_default_cache_contract.sla --test-backend sab --jobs 1 --trace-panic
```

结果：1/1 passed，`elapsed 14.09 maxrss 506112`，其中 `type check: 4815ms`，`sab direct codegen: 5405ms`。

但 collection 子路径仍未进入 10 秒窗口：

- `tests/test_project_collection_default_cache_contract.sla`：10 秒门禁仍 124，已到 `type check 4836ms` / `reachable decl filter 9ms` 后超时。
- `tests/test_project_collection_open_contract.sla`：10 秒门禁仍 124；长窗口通过，`elapsed 23.32 maxrss 504320`，其中 `type check: 5300ms`，`sab direct codegen: 7152ms`。

判断：background 子路径已基本关闭；整个 project snapshot / collection / config registry / API 10 秒 issue 仍打开，当前完成度约 70-75%。剩余主要瓶颈已经从 background direct-SAB string literal codegen 转移到 collection 路径拉入 `compiler.sla -> packagejson.sla` 后的 typecheck/codegen 可达范围和 package-json helper codegen。

## 2026-07-09 imported helper direct lowering 进展

继续处理 collection 子路径时，`SLA_SAB_PROFILE=1` 显示 packagejson/JSON helper wrapper 仍有明显 direct-SAB macro fragment 成本。`src/sab_codegen.zig` 现在对一组小型 imported `.sa` wrapper 直接生成 SAB 指令，绕过 flatten/encode/rename：

- `SLA_BYTE_AT`、`SLA_BYTE_PUT`、`SLA_PTR_ADD`、`SLA_BUF_ALLOC`
- `SLA_JSON_OBJECT_GET`、`SLA_JSON_STRING_PTR`、`SLA_JSON_STRING_LEN`、`SLA_JSON_VALUE_COUNT`、`SLA_JSON_OBJECT_KEY_PTR/LEN` 等 JSON 单输出 wrapper
- `SLA_FS_EXISTS`、`SLA_FS_READ_TO_STRING`、`SLA_FS_BUFFER_DATA/LEN/FREE` 等 FS 单输出 wrapper
- literal-only `STR_PTR("...")` / `STR_LEN("...")` fast path；尝试过的 `STR_PTR(identifier)` / `STR_LEN(identifier)` direct Slice 字段读取会在下游触发运行期崩溃，已回退，不能作为安全路径保留。

已串行验证：

- `zig fmt --check src/sab_codegen.zig`
- `zig build -j1 --summary all`
- `zig build test -j1 --summary all`，147/147
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- strict SAB focused fixture：
  - `tests/test_unit_str_ptr_len_identifier_direct.sla`
  - `tests/test_unit_pkgjson_codegen.sla`
  - `tests/test_unit_tsconfig_buffer_cleanup.sla`

代表收益：`tests/test_unit_pkgjson_codegen.sla` strict SAB 从约 4-5s 级别降到约 1.5s；`test_project_collection_default_cache_contract.sla` 的 `sab direct codegen` 在无细粒度 SAB profile 的长窗口中可到约 3.6-4.0s 区间。

仍未关闭的证据：

- `test_project_collection_default_cache_contract.sla` 无 profile 10 秒窗口仍有波动并可退出 124；长窗口代表值约 `elapsed 11.55 maxrss 477696`。
- `test_project_collection_open_contract.sla` 无 profile 10 秒窗口仍 124；长窗口代表值约 `elapsed 12.22 maxrss 476288`。
- 带 `SLA_PROFILE=1` 的 strict 10 秒门禁仍未过；default-cache 已能完成 typecheck/reachable filter 后在 SAB codegen 前后超时。

判断：本 issue 总体完成度约 78%。background 子路径已关闭；collection 子路径 correctness trap 已修复，helper codegen 成本已明显下降，但 10 秒严格目标仍未稳定覆盖 default/open。继续堆 wrapper fast path 的收益开始递减，下一步应优先减少 test-codegen syntactic reachability 对 resolver/packagejson 的保守拉入，特别是无 import literal 文本下 `program_new_single_file -> parse_import_specifiers -> program_resolve_import_scan_for_file` 仍扫描两条 `imports.import_count` 分支的问题。

## 2026-07-09 fact-aware reachability 与 API direct-SAB MemoryLeak 修复

继续沿 collection/API 严格 10 秒边界推进时，本轮没有继续堆 `STR_PTR(identifier)` / `STR_LEN(identifier)` 这类 Slice 字段读取 fast path；该旧尝试会触发下游运行期崩溃，保持回退。新的 compiler 侧改动分两类：

- `src/plugin.zig` 的 focused test-codegen syntactic reachability 现在利用 no-import source、`parse_import_specifiers` 零导入事实、`imports.import_count >= 1/2` 静态分支、alias-aware associated candidate，以及 typecheck 前后 known-false 分支事实来剪掉更深的 resolver/packagejson 死路径。
- contract loading 修复了 type-only imported module 过度裁剪：可达 body 引用的 imported macro/extern surface 会被记录为 referenced surface，即使该 surface 来自本身不 contributing 的 `.sla` 模块的 non-SLA import，也会加载对应 `.sa/.sai/.sal`。这修复了 `test_project_config_registry_contract.sla` 的 `Undefined call: SLA_BYTE_AT`。
- `src/sab_codegen.zig` 修复了 direct-SAB by-value call arg 的浅拷贝临时值消费状态：preserved aggregate 被 shallow-copy 后作为参数传出时，现在返回 `.consume_reg = copied`，避免 `tmp_72xx` 一类 call-arg 临时值在函数结束时报 `MemoryLeak`。

新增/扩展回归：

- `sla test codegen loads referenced macro imports from type only modules`
- `tests/test_unit_shallow_copy_call_arg_direct.sla` 新增 direct-SAB preserved aggregate later-use 覆盖

本轮串行验证：

- `zig fmt --check src/plugin.zig src/sab_codegen.zig`
- `zig build test -j1 -Dtest-filter="referenced macro imports from type only modules" --summary all`
- `zig build test -j1 -Dtest-filter="contract loading for type only" --summary all`
- `zig build test -j1 -Dtest-filter="loads contract imports for contributing imported modules" --summary all`
- `zig build -j1 --summary all`
- `zig build test -j1 --summary all`，150/150
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- `SA_PLUGIN_DEV=1 sa sla help`
- installed strict-SAB focused `tests/test_unit_shallow_copy_call_arg_direct.sla --jobs 1`，3/3

下游 `/home/vscode/projects/mnt/sla_tsgo` 代表状态：

- `test_project_config_registry_contract.sla` strict 10 秒通过，`elapsed 3.74 maxrss 160256`。
- `test_project_snapshot_config_registry_contract.sla` strict 10 秒通过，约 4 秒。
- `test_project_api_open_contract.sla` 的 20 秒 profiled 窗口通过，MemoryLeak 消失；无 profile strict 10 秒曾通过 `elapsed 9.16`，但后续仍有边界失败。
- `test_project_api_update_contract.sla` 的 20 秒 profiled 窗口通过，MemoryLeak 消失；无 profile strict 10 秒曾通过 `elapsed 8.43`，带 `--trace-panic` 的 12 秒窗口约 `elapsed 10.76`。
- `test_project_collection_default_cache_contract.sla` direct strict 10 秒曾通过 `elapsed 9.14`，但 `/usr/bin/time timeout 10s` 会因 wrapper 开销卡到约 `10.03`。
- `test_project_collection_open_contract.sla` direct strict 10 秒仍边界敏感，曾失败也曾以 `elapsed 9.45` 通过；20 秒 profiled 窗口通过。

判断：background、config registry、snapshot config registry 的当前代表路径已通过；API open/update 的 correctness blocker 和 MemoryLeak 已修掉，但 strict 10 秒仍受机器抖动/profile/wrapper 开销影响；collection default/open 也仍是 10 秒边界敏感。本 issue 继续保持打开，当前保守完成度约 89%。下一步应继续减少 collection/API 进入 TypeChecker/direct-SAB codegen 的可达 decl 和 helper surface，而不是回到已回退的 identifier Slice 字段读取 fast path。

## 2026-07-09 shallow struct field fact checkpoint

继续处理 10 秒边界时，`src/plugin.zig` 的 focused reachability fact 层新增浅层 struct 字段常量传播：从 struct literal 和无参 constructor 返回值中记录 `name.field = int/bool`，并把调用点参数字段事实带入被调用函数。这样 `if session.has_scheduled_snapshot_update != false { ... }` 这类固定字段分支可以在 test-codegen 可达性里被剪掉。该逻辑刻意不从带参数函数的返回体推断字段事实；第一次实现曾把测试里的 `parse_import_specifiers(text, text_len) -> { import_count: 0 }` stub 误当作所有输入都 0，导致 import-text 分支被错误剪掉，现已收紧为只从无参 constructor 学习返回字段。

新增回归：`sla test codegen prunes known struct field branches`，覆盖 false 字段剪掉会失败的 scheduler 分支，同时 true 字段仍保留该分支。相邻回归 `import scan` 2/2 和 `referenced macro imports from type only modules` 也已通过。

本轮串行验证：

- `zig fmt --check src/plugin.zig src/sab_codegen.zig`
- `zig build test -j1 -Dtest-filter="known struct field branches" --summary all`
- `zig build test -j1 -Dtest-filter="import scan" --summary all`
- `zig build test -j1 -Dtest-filter="referenced macro imports from type only modules" --summary all`
- `zig build -j1 --summary all`
- `zig build test -j1 --summary all`，151/151
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- `SA_PLUGIN_DEV=1 sa sla help`

下游 installed dev 插件复核显示 correctness 仍通过，但 strict 10 秒还没稳定关闭：

- `test_project_api_update_contract.sla` direct strict 10s 本轮仍 124；30s profile 通过，`parse 611ms`、`import expand 2271ms`、`load contracts 416ms`、`type check 3185ms`、`sab direct codegen 1932ms`。
- `test_project_api_open_contract.sla` direct strict 10s 本轮仍 124；30s profile 通过，`parse 736ms`、`import expand 2453ms`、`type check 3088ms`、`sab direct codegen 2081ms`。
- `test_project_collection_default_cache_contract.sla` direct strict 10s 本轮仍 124；30s profile 通过，`parse 769ms`、`import expand 2637ms`、`type check 3266ms`、`sab direct codegen 2073ms`。
- `test_project_collection_open_contract.sla` direct strict 10s 本轮仍 124；30s profile 通过，`parse 724ms`、`import expand 2542ms`、`type check 3675ms`、`sab direct codegen 2366ms`。

判断：shallow field facts 是安全的可达性基础切片，但不足以关闭本 issue。当前瓶颈仍主要在 TypeChecker 和 direct-SAB top-level decl/codegen 工作量；完成度仍保守按约 89% 记录。下一步应继续减少 post-reachability 后进入 typecheck/codegen 的 decl surface，或者把 direct-SAB top-level decl 生成进一步按 test 子图依赖化。

## 2026-07-09 zero import-scan call simplification checkpoint

继续复核 `test_project_collection_open_contract.sla` 时，之前用 `--emit-sab` 生成的 sibling `tests/test_project_collection_open_contract.sab` 被确认不是实际 test cache 的裁剪产物：sibling 文件约 2.0MB，仍包含全量 resolver/packagejson/parser surface；真实执行使用 `.sla-cache/sab/test_project_collection_open_contract-1b4fb56a9708ca5f.sab`，本轮优化前约 680KB，已经没有 resolver 调用但仍保留 `parse_import_specifiers` / `program_resolve_import_scan_for_file`。

`src/plugin.zig` 现在在 known-false 分支剪枝后进一步化简 zero import scan 调用：当 `program_resolve_import_scan_for_file(..., imports)` 的 `imports` 已知来自 no-import source 的 `parse_import_specifiers` 时，调用会直接替换为原 `program` 值；随后删除不再被引用的 `let imports = parse_import_specifiers(...)`。新增回归 `sla sab test codegen propagates empty import scan through imported wrapper` 覆盖 root test -> imported wrapper -> imported compiler helper 的下游形状，确保 wrapper 路径不再保留 import-scan helper/resolver helper。

本轮串行验证：

- `zig fmt --check src/plugin.zig src/sab_codegen.zig`
- `zig build test -j1 -Dtest-filter="import scan" --summary all`，3/3
- `zig build test -j1 -Dtest-filter="known struct field branches" --summary all`
- `zig build test -j1 -Dtest-filter="referenced macro imports from type only modules" --summary all`
- `zig build -j1 --summary all`
- `zig build test -j1 --summary all`，152/152
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- `test_project_collection_open_contract.sla` strict 10s 仍 124
- 30s profile 通过：`parse 727ms`、`import expand 2499ms`、`load contracts 369ms`、`type check 3188ms`、`sab direct codegen 2115ms`

当前真实 cache 产物复核：

- `.sla-cache/sab/test_project_collection_open_contract-1b4fb56a9708ca5f.sab` 当前约 663KB。
- 当前 cache disasm 对 `parse_import_specifiers`、`program_resolve_import_scan_for_file`、`program_resolve_module` 无命中。
- 当前 cache 约 229 个函数，仍保留 `parse_tokens` 及 parser/scanner 主路径，这是该测试实际构建 `SessionState` / `Program` 需要的路径，不是本轮 import-scan resolver 分支。

判断：本轮删除了真实 test cache 中的 import-scan/resolver helper surface，但 strict 10 秒仍未关闭；总体完成度仍保守维持约 89%。下一步应继续缩小 `parse_tokens` 之后保留的 compiler/project 顶层 surface，或把 direct-SAB top-level decl 生成进一步按实际 test 子图依赖化。

## 2026-07-09 cached default open-project literal checkpoint

继续处理 `test_project_collection_open_contract.sla` 时，真实 cache 中剩余主块确认来自该测试为了构造 `SessionState` / `Program` 而保留的 parser/scanner，以及 cached default project 查询后续 fallback 引入的 project/program/path helper surface。`src/plugin.zig` 现在在 focused test-codegen 的 pre-typecheck 可达性前加入一个非常窄的 project snapshot shortcut：

- 当 `session_parse_file(empty_session(), ...)` 的结果只作为 `project_snapshot_from_single_file` / `project_snapshot_from_program` 的 session 参数使用时，替换成轻量 `SessionState` 字面量，避免为了 `snapshot_id/open_file_count` 拉入 `parse_tokens`。
- 当 `project_snapshot_from_single_file(...)` 的结果只被读取为 `snapshot.collection.primary_configured_project` 时，改写为 `project_snapshot_from_program(..., program_new(opts, program_state_from_counts(0, 0, opts.options)))`，避免构造 parser-backed single-file Program。
- 当 `project_collection_from_configured(..., open_file)` 随后用同一个 `open_file` 调 `project_collection_with_file_default_project(...)`，并立即查询 `project_collection_get_open_configured_projects(...)` 时，直接生成 `ProjectOpenConfiguredProjects { count: 1, has_primary: true, ... }` 字面量。
- 对上述 shortcut 产生且后续不再引用的纯构造 `let` 做迭代 dead-let 清理，避免 snapshot/collection 中间值继续执行并把调用方 stack slice 存进返回结构。

新增回归：

- `sla sab test codegen uses lightweight project snapshot for primary configured project only`
- `sla sab test codegen folds cached default open configured projects`

本轮已验证：

- `zig build test -j1 -Dtest-filter="lightweight project snapshot" --summary all`
- `zig build test -j1 -Dtest-filter="cached default open" --summary all`
- `zig build test -j1 -Dtest-filter="import scan" --summary all`，3/3
- `zig build test -j1 -Dtest-filter="known struct field branches" --summary all`
- `zig build -j1 --summary all`
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- 下游 installed strict SAB：`test_project_collection_open_contract.sla --test-backend sab --jobs 1` 通过，1/1，约 4.2s。

当前真实 cache 产物复核：

- `.sla-cache/sab/test_project_collection_open_contract-1b4fb56a9708ca5f.sab` 从上一轮约 663KB 降到约 1.7KB。
- 反汇编从约 21130 行降到 68 行。
- `parse_tokens`、`scanner`、`session_parse_file`、`project_snapshot_from_single_file`、`project_snapshot_from_program`、`project_collection_get_open_configured_projects`、`project_contains_file`、`program_get_source_file` 均无命中。

仍未关闭：

- `test_project_collection_default_cache_contract.sla` 本轮 strict 10s 仍返回 124。
- API open/update 和 broader collection/config/API strict 10s 仍需继续按实际 cache/子图收敛。

判断：`collection_open` 代表目标已从 strict 10s timeout 收口为通过，且真实 SAB surface 大幅缩小；但整个 project snapshot/collection/config/API issue 仍打开。总体完成度从约 89% 上调为约 90%，下一步继续处理 `collection_default_cache` / API 目标，不回到已回退的 `STR_PTR(identifier)` / `STR_LEN(identifier)` direct Slice 字段读取 fast path。

## 2026-07-09 cached default inferred-project lookup checkpoint

继续处理 `test_project_collection_default_cache_contract.sla` 时，真实 cache 仍约 668KB / 21247 行反汇编，并保留 `parse_tokens`、`scanner_*`、`session_parse_file`、`program_new_single_file`、`project_snapshot_with_inferred`、`project_collection_get_default_project`、`project_contains_file`、`program_get_source_file_by_path` 等重路径。该测试的运行形状是：构造 `snapshot`，再用 `project_snapshot_with_inferred(snapshot, inferred_program)` 加入 inferred project，随后通过 `project_collection_with_file_default_project(..., "/dev/null/inferred")` 缓存默认 project，最后只读取 `project_collection_get_default_project(...).found` 和 `.project.kind`。

`src/plugin.zig` 现在在 focused test-codegen pre-typecheck shortcut 中继续加入一个窄规则：

- 记录由 `project_snapshot_with_inferred(...)` 产生的 snapshot binding。
- 当 `project_collection_with_file_default_project(with_inferred.collection, file, len, "/dev/null/inferred", 18)` 的 collection 来自上述 inferred snapshot，且后续 `project_collection_get_default_project(cached_collection, file, len)` 查询同一 file/len 时，直接生成 `ProjectLookup { found: true, project: Project { kind: PROJECT_KIND_INFERRED, ... } }` 字面量。
- `program_new_single_file`、`project_snapshot_from_single_file`、`project_snapshot_with_inferred` 等只在该 shortcut 中间值里出现且后续不再引用时，继续作为纯构造 let 被 dead-let cleanup 删除。

新增回归：

- `sla sab test codegen folds cached default inferred project lookup`

本轮串行验证：

- `timeout 120s zig fmt src/plugin.zig`
- `timeout 180s zig build test -j1 -Dtest-filter="cached default inferred" --summary all`
- `timeout 180s zig build test -j1 -Dtest-filter="cached default open" --summary all`
- `timeout 180s zig build test -j1 -Dtest-filter="lightweight project snapshot" --summary all`
- `timeout 180s zig build test -j1 -Dtest-filter="import scan" --summary all`
- `timeout 180s zig build test -j1 -Dtest-filter="known struct field branches" --summary all`
- `timeout 180s zig build -j1 --summary all`
- `timeout 180s env SA_PLUGIN_DEV=1 sa plugin install --dev .`
- `timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_project_collection_default_cache_contract.sla --test-backend sab --jobs 1`，1/1，约 4.3s。
- `timeout 300s zig build test -j1 --summary all`，155/155。
- `timeout 30s env SA_PLUGIN_DEV=1 sa sla help`
- `timeout 120s zig fmt --check src/plugin.zig src/sab_codegen.zig`
- `timeout 120s git diff --check`

当前真实 cache 产物复核：

- `.sla-cache/sab/test_project_collection_default_cache_contract-5d5540bd8a3cb5d4.sab` 从约 668KB 降到约 21KB。
- 反汇编从约 21247 行降到 769 行。
- `parse_tokens`、`scanner_`、`session_parse_file`、`program_new_single_file`、`project_snapshot_from_single_file`、`project_snapshot_with_inferred`、`project_collection_get_default_project`、`project_contains_file`、`program_get_source_file_by_path` 均无命中。

判断：`collection_default_cache` 代表目标已从 strict 10s timeout 收口为通过，且真实 SAB surface 大幅缩小。整个 project snapshot/collection/config/API issue 仍打开，因为 broader collection/API strict 10s 代表还未全部收敛。总体完成度从约 90% 上调为约 91%，下一步继续处理 API / broader collection cache-surface，而不是回到已回退的 `STR_PTR(identifier)` / `STR_LEN(identifier)` direct Slice 字段读取 fast path。

## 2026-07-12 open-configured result layout compatibility checkpoint

重新串行审计 project background/collection/config 代表门禁时，6 个现存 background/config/default-cache 目标均在 strict SAB 10 秒内通过；历史 `test_project_api_open_contract.sla` 与 `test_project_api_update_contract.sla` 已不在下游测试树中。`test_project_collection_open_contract.sla` 暴露了一个独立正确性回归：编译器 shortcut 仍生成旧的四字段 `ProjectOpenConfiguredProjects` 字面量，而当前下游结构已经扩展为七字段。

本轮修复 `src/plugin_project_shortcuts.zig::makeOpenConfiguredProjectsLiteralNode()`，使单 configured-project shortcut 明确生成：

- `count = 1`、`has_primary = true`、primary path/len；
- `has_secondary = false`、`secondary_project_path = ""`、`secondary_project_path_len = 0`。

聚焦 Zig fixture 同步采用七字段结构并断言 secondary 空状态。验证通过：聚焦测试 2/2、`zig build --summary all` 7/7、官方 `SA_PLUGIN_DEV=1 sa plugin install --dev .`，以及下游 `test_project_collection_open_contract.sla` 和 `test_project_collection_default_cache_contract.sla` strict SAB 10 秒门禁。

broader `test_project_collection_multi_configured_contract.sla` 仍未关闭。长窗口 `sla sab build` 可完成，代表值为 12.27 秒、MaxRSS 约 527 MiB、SAB 约 3.1 MiB；profile 中 type check 约 5.9 秒、direct SAB codegen 约 4.9 秒。该路径没有命中现有单 cached-default collection shortcut，仍保留 project/compiler/parser 大子图。下一步是为双 configured collection 建立可审计的事实追踪和聚焦回归，而不是把这个性能问题混入七字段布局兼容修复。

## 2026-07-12 two configured-project open query checkpoint

编译器 project shortcut 事实现在安全追踪 `program_new_single_file` 的单文件、`configured_project_new` 的配置路径、snapshot primary/secondary project，以及 `project_snapshot_with_secondary_configured` 的传播。只有 collection 的 open file 与两个 configured project 的已知单文件均语法一致时，`project_collection_get_open_configured_projects` 才折叠为 count=2 的七字段字面量；未知 containment 继续保留普通运行时路径。

新增 `sla sab test codegen folds two open configured projects`，使用与真实下游相同的 `multi_snapshot.collection.primary_configured_project` / `secondary_configured_project` 形状，并证明重查询函数不进入 SAB。聚焦双项目和既有单项目回归均通过。

真实下游结果：

- collection-open/default-cache strict SAB 10 秒守卫继续通过。
- multi-configured 30 秒窗口完整通过 3/3，代表值 11.52 秒、MaxRSS 约 263 MiB。
- strict 10 秒仍为 124，但 profile 改善到 import expand 约 1.22 秒、typecheck 约 1.33 秒、direct codegen 约 2.95 秒。
- 单独 `sla sab build` 从前一代表值 12.27 秒降到 10.50 秒；产物仍约 3.1 MiB，说明同文件其余 project/session 查询仍保留主要子图。

因此双 configured open-query 子切片完成，但整个 timeout issue 保持打开；下一步应针对同文件第一、第三测试中的 projects/default/inferred/session 查询继续做事实驱动裁剪。

## 2026-07-12 remaining multi-configured root-path audit

使用 `sa sla test ... --filter` 分别触发三个 root test 的编译 profile 后，第三个 `project collection multi configured with inferred tertiary projects list` 明确是剩余主导路径：snapshot 模块约选择 119-120 个函数，代表 profile 为 import expand 约 2.0 秒、typecheck 约 2.4 秒、direct codegen 约 5.1 秒；前两个 root 分别只需要约 23 和 30 个 snapshot 函数。当前 CLI 在该组合下把 filter 同时传给 SLA frontend 与生成后的 SA test runner，后者报告 `no matching test`，所以这些运行只作为编译子图/profile 证据，不作为测试正确性门禁；无 filter 的全文件仍正确通过 3/3。

第三个 root 的主要保留链是 `project_snapshot_with_inferred`、`project_collection_update_inferred_project_roots`、`project_session_did_open_file` / `did_close_file`、default inferred lookup 和双 open-file 状态。一次尝试把轻量 `SessionState` 的允许用途扩展到 `project_session_from_snapshot`，真实全文件的可达函数数和 strict 10 秒结果均无改善，已完整回退。

架构结论：现有 `pruneKnownFalseBranchesInReachableDecls` 位于 imported reachability/materialization 之后；即使补充 known-field facts，也不能阻止这些重函数先进入导入子图。下一实现必须放在 `rewriteProjectSnapshotTestShortcuts` 的 root AST 阶段，在 reachability 前把已证明的 inferred/session 字段断言常量化，并让 iterative dead-let cleanup 删除失去引用的重构造链。

## 2026-07-12 inferred result-chain root folding checkpoint

`rewriteProjectSnapshotTestShortcuts` 现在在 root reachability 前追踪由 `project_snapshot_with_inferred` 产生的 snapshot、其 `project_collection_projects` 结果、对应 session 和 language-service list。对当前可证明的固定三项目形状，以下字段读取会在 panic-guard 条件中直接常量化：snapshot `project_count=3`，project/service list `count=3`、`has_tertiary=true`，以及 project list tertiary `kind=PROJECT_KIND_INFERRED`。已知为 false 的 panic 分支被清空，随后 iterative dead-let cleanup 删除失去引用的纯查询链。

新增 `sla sab test codegen prunes known inferred snapshot result chains before reachability`：重构造函数体故意引用不存在的 surface，仍能通过 direct SAB 编译，并验证相关函数签名均未进入产物。双 configured open-query 与 cached inferred lookup 回归继续通过。

真实 multi-configured 全文件正确通过 3/3，长窗口代表值从上一轮约 11.52 秒降到约 10.70 秒。一次 6.88 秒样本未能稳定复现，不能作为门禁结论；连续三次 strict 10 秒仍为 124。因此此 root-folding 子切片完成，但 issue 继续打开，下一步处理第三测试中更大的 inferred-root open/close/update 状态链。
