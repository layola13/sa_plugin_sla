# SAB call target 与实参 materialization 共享 lowering 问题

## 状态

- 状态：已验证修复 / 保留为回归守卫工单
- 影响方：`sa_plugin_sla` SAB backend，尤其是 thread closure / escaped closure 中的普通函数调用
- 发现来源：`/home/vscode/projects/sla_ecs/lib/parallel.sla`
- 当前建议：`parallel.sla` 已重新纳入 host direct-SAB guard；后续若改动 call lowering / thread closure / SAB call serialization，必须继续跑 strict SAB 和 disasm guard。

## 2026-07-06 复核结论

本 issue 的历史非法形态未再复现，按当前 compiler 状态标记为已修复。验证命令：

```bash
sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test /home/vscode/projects/sla_ecs/lib/parallel.sla --test-backend sab --jobs 1
SA_PLUGIN_DEV=1 sa sla sab build /home/vscode/projects/sla_ecs/lib/parallel.sla --out /tmp/parallel_docs_issue.sab
SA_PLUGIN_DEV=1 sa sla sab disasm /tmp/parallel_docs_issue.sab --out /tmp/parallel_docs_issue.disasm.sa
rg -n 'call [^\n]*"?@[^\s,"]*\(' /tmp/parallel_docs_issue.disasm.sa
```

结果：strict direct-SAB 测试 1/1 passed；非法 call-target grep 无匹配。相关 disasm 行保持 target 与参数分离：

```sa
call r490,"@sla__ecs_parallel_sum_i32_chunk","tmp_52"
call r499,"@sla__ecs_parallel_sum_i32_chunk","tmp_59"
```

## 问题现象

历史 repro 中，SLA 代码形如：

```sla
thread::spawn(^|| ecs_parallel_sum_i32_chunk(captured_vec))
```

在 SAB 输出 / 反汇编中可能把函数调用目标和实参拼成同一个 call target，例如：

```sa
call rX,"@sla__ecs_parallel_sum_i32_chunk(tmp_2)"
```

这是非法形态。正确形态必须把 callee identity 与参数分离：

```sa
call rX,"@sla__ecs_parallel_sum_i32_chunk","tmp_2"
```

或在文本等价表示中保持：target 是纯符号 `@sla__ecs_parallel_sum_i32_chunk`，`tmp_2` 是单独的参数 / register operand。

## 当前观察

在当前已安装插件环境中，以下命令已经不再复现非法 call target：

```bash
cd /home/vscode/projects/sla_ecs
SA_PLUGIN_DEV=1 sa sla test lib/parallel.sla
SA_PLUGIN_DEV=1 sa sla sab build lib/parallel.sla
SA_PLUGIN_DEV=1 sa sla sab disasm .sla-cache/sab/parallel-74306cc660ccac57.sab --out /tmp/parallel.disasm.sa
rg -n 'call [^\n]*"?@[^\s,"]*\(' /tmp/parallel.disasm.sa
```

本轮检查中，非法 grep 无输出；相关 disasm 行为：

```sa
call r490,"@sla__ecs_parallel_sum_i32_chunk","tmp_52"
call r499,"@sla__ecs_parallel_sum_i32_chunk","tmp_59"
```

这说明安装态当前结果已经把目标符号和参数分开。本文件保留为回归守卫记录：完成标准不应只依赖一次人工 disasm，后续 call-lowering 相关改动必须继续跑上面的 guard。

## 根因判断

问题不应在 SAB 后端做字符串替换修复。正确架构应是：

```text
SLA AST / typecheck
  -> shared lowering plan
      - call target normalization
      - argument materialization order
      - borrow / reference argument lowering
      - ownership cleanup
  -> SA text serializer
  -> SAB structured serializer
```

也就是说，SA text 与 SAB backend 都应消费同一个 call lowering plan。后端只负责最终序列化，不应各自重新推导 callee/args，更不能让 SAB backend 接受已经带 `(...)` 的 target string。

## 建议修复项

1. [x] host regression：`parallel.sla` strict direct-SAB no-fallback passes.
2. [x] disasm guard：不存在 `@.*(` call target；callee identity 与参数分离。
3. [ ] 后续架构硬化：在共享 call lowering plan 中显式记录 `target_symbol` 纯符号 invariant，并在 SA text / SAB serializer 入口保留断言或错误路径。
4. [ ] 后续更小 focused fixture：thread closure 捕获局部变量后调用普通函数，例如 `thread::spawn(^|| worker(captured))`，用于替代/补充 `parallel.sla` 这个较大的 host guard。
5. [x] 未采用 SAB-only string rewrite；当前修复路径仍以结构化 call target/arg 分离为守卫。

## `sla_ecs` 侧处理策略

`sla_ecs` 当前任务推进不应直接修改 SLA 编译器实现。涉及该类问题时：

- compiler bug 写入 `sa_plugin_sla/docs/`；
- ECS 侧实现优先使用 SA backend 验证；
- 只有当任务明确要求 SAB 或 compiler 修复时，才进入 compiler 源码修改与 dev plugin reinstall 流程。
