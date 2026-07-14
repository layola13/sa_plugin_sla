# Typed HIR / LoweringPlan 单一语义来源架构

状态：目标架构已确认，迁移进行中。当前 `lowering_rules.zig` 已承载若干共享 plan，但 SA-text 与 direct-SAB emitter 仍保留高级语义判断；本文件不是完成声明。

## 最终流水线

```text
Parser
  -> Typed HIR
  -> LoweringPlan
       -> SA debug/text serializer
       -> SAB binary serializer
```

`Typed HIR` 必须固定符号绑定、具体类型、调用目标、布局和能力语义。`LoweringPlan` 必须固定参数物化、借用/移动、临时值、释放、聚合传输、控制流合流和调用结果形状。两个 emitter 只能分配后端名称/编号并序列化 plan，不得重新决定这些语义。

## 强制不变量

- 同一个 AST/HIR 节点只产生一份语义计划；SA 与 SAB 不得分别推导所有权或 ABI 行为。
- emitter 不得根据局部字符串、寄存器是否存在或输出格式重新分类借用、移动、Copy、临时值和释放。
- ABI 布局来自共享 typed layout；禁止在两个 emitter 中维护独立 field/aggregate offset 决策。
- namespace/module symbol identity 在 Typed HIR 中完成，不能依赖 flatten 后 raw name 的 first-wins 兼容行为。
- direct SAB 保持直接结构化输出，不通过 SA 文本中转。

## 分阶段迁移

1. `CallLoweringPlan`：合并静态调用目标、alias、参数语义、结果形状和调用后 lifecycle。本轮已加入 `StaticCallLoweringPlan`，并让 SA/direct-SAB 共享 `void` 结果判断；完整参数计划仍开放。
2. `AggregateLoweringPlan`：统一 struct/tuple/array/enum 布局、field transfer、update、Copy/move/deep-copy 和 cleanup。
3. `ControlFlowLoweringPlan`：统一分支/循环/try/match 的 capability state、phi cleanup、early exit 和 result transfer。
4. `Typed HIR` 持久化：TypeChecker 输出稳定的 typed symbol/layout/call/lifecycle annotations，逐步移除 emitter 对 AST 的高级语义查询。
5. emitter 纯化：为两个 emitter 建立禁止新增语义分支的审计规则，并按类别删除重复逻辑。

## 跨仓源码导入归零

最终验收要求：`sa_plugin_sla` 构建不得通过相对路径或绝对路径直接编译其他仓库的 `src/*`。当前 `build.zig` 仍直接引用 `../../sci/src/plugin_bridge.zig`，因此该目标未完成。

迁移方向：把 SCI bridge/SAB API 变成带版本的独立包或已安装 SDK 接口，由 manifest/lockfile 声明依赖；`sa_plugin_sla` 只消费公开 API/库和版本化 `sa_std` artifact，不读取 sibling repo 源码。

验收搜索：

```bash
rg -n '\.\./\.\./[^ ]*/src|/home/vscode/projects/.*/src|root_source_file = .*\.\./' build.zig src tools
```

期望跨仓源码命中为 0。测试 fixture 或一次性生成工具若需要外部输入，必须显式标为 dev-only，不能进入插件正常构建图。

## 完成标准

- 调用、临时值、所有权释放和聚合布局四类代表性路径均由共享 plan 驱动，并有 SA/SAB parity 回归。
- `codegen.zig` 与 `sab_codegen.zig` 对上述语义不再存在独立分类函数或同义分支。
- 跨仓源码导入搜索为 0，干净环境可仅凭声明依赖构建、测试和 dev install。
- real `sla_ecs` profile、docs issue 串行门禁、官方 dev install/help 与 strict SAB no-fallback corpus 均通过。
