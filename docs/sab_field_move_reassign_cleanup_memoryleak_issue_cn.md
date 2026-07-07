# SAB field move + local reassign cleanup MemoryLeak issue

状态：待修复。下游 `sla_ecs` 在新增 `lib/parallel_mut_writeback.sla` 时复现：generated-SA 后端通过，但默认/SAB 后端对“从 struct 字段取出 owner 到局部变量，再把该局部变量赋回字段”的写法报 `MemoryLeak`。本文只记录 issue，不修改 SLA 编译器源码。

## 触发背景

`sla_ecs/lib/parallel_mut_writeback.sla` 新增 Bevy-style mutable World writeback plan：复用 `parallel_mut_safety.sla` 的安全批次，然后按批次提交显式 component/resource/message 写入 intent。

初始测试中为了构造“缺失 intent”的负例，使用了类似写法：

```sla
let p0 = ecs_parallel_mut_writeback_plan_new();
let safety = ecs_parallel_mut_safety_plan_add(
    p0.safety,
    ecs_parallel_mut_system_spec(0, access, false, false, true)
);
p0.safety = safety;
let run = ecs_parallel_mut_writeback_run(ecs_parallel_mut_writeback_world_new(), p0, 4);
```

这里 `p0.safety` 是 owner 字段，`safety` 是临时局部 owner，最后再写回 `p0.safety`。

## generated-SA 通过

```bash
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_mut_writeback.sla \
  --test-backend sa --jobs 1 --trace-panic
```

结果：`15 passed; 0 failed; 0 skipped`。

## 默认/SAB 失败

```bash
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_mut_writeback.sla \
  --jobs 1 --trace-panic
```

失败信息：

```text
error[MemoryLeak]: live registers remain at function exit
  register: safety
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/parallel_mut_writeback-d074f15419f0d7b3.sab","line":4805,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"safety","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 当前规避

下游已改成 helper 直接在函数内部更新字段，避免把 owner 字段移动到测试局部再赋回：

```sla
fn ecs_parallel_mut_writeback_plan_add_without_intent(
    plan: EcsParallelMutWritebackPlan,
    spec: EcsParallelMutSystemSpec
) -> EcsParallelMutWritebackPlan {
    plan.safety = ecs_parallel_mut_safety_plan_add(plan.safety, spec);
    return plan;
}
```

规避后默认/SAB 与 generated-SA 均通过：

```bash
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_mut_writeback.sla \
  --test-backend sa --jobs 1 --trace-panic
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_mut_writeback.sla \
  --jobs 1 --trace-panic
```

结果：两者均 `15 passed; 0 failed; 0 skipped`。

## 判断

- generated-SA 能处理该 owner 字段 move/reassign 模式。
- SAB 在局部 `safety` 已写回字段后仍把该寄存器视为 `Active`，疑似 field move/reassign cleanup 状态没有正确消费或释放局部 owner。
- 当前 `.sab` verifier 错误无 SLA 源行映射，但 register 名称足以定位到上述局部变量。

## 后续建议

修复 SAB 后建议补一个最小单测，覆盖：

1. struct owner 字段移动到局部变量；
2. 局部变量经函数返回新 owner；
3. 该局部 owner 赋回原 struct 字段；
4. 函数退出时局部不应再作为 live owner 泄漏。

同时重跑：

```bash
cd /home/vscode/projects/sla_ecs
SA_PLUGIN_DEV=1 sa sla test lib/parallel_mut_writeback.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test lib/parallel_mut_writeback.sla --test-backend sa --jobs 1 --trace-panic
```
