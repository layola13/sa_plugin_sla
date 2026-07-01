# SLA Plugin Rc/Arc Clone Fix - Work Session Summary
**Date:** June 30, 2026

## 目标
修复 SAB 后端中 `Rc::clone(&rc1)` 和 `Arc::clone(&arc1)` 的 signal 11 崩溃问题。

## 问题根源分析

### 发现
1. **SA 文本后端工作正常**：使用 `RC_CLONE` 宏，测试通过
2. **SAB 后端失败**：生成内联引用计数操作而非宏调用，导致 signal 11

### 根本原因
- SA 文本后端在 `src/codegen.zig:10366` 有硬编码的 `Rc::clone` 特殊处理
- SAB 后端缺少对应处理，导致 `Rc::clone` 通过通用静态调用路径
- 通用路径生成的代码不正确（可能与借用处理有关）

## 实现的修复尝试

### 尝试 1: genAssociatedValueArg (未生效)
**文件:** `src/sab_codegen.zig:4299`, `src/lowering_rules.zig:259`
**思路:** 在 `genStdSurfaceCall` 中处理关联调用时，跳过 borrow 包装
**结果:** 未生效，因为 `Rc::clone` 不走 `genStdSurfaceCall` 路径

### 尝试 2: genRcArcCloneCall (未生效)  
**文件:** `src/sab_codegen.zig:4771`
**思路:** 在 `genCall` 调用链中早期拦截，直接发出宏
**结果:** 未生效，因为 `planStaticCall` 更早返回了调用计划

### 尝试 3: emitPlannedStaticCall 特殊处理 (部分实现)
**文件:** `src/sab_codegen.zig:4858`
**思路:** 在发出静态调用前检查是否为 Rc/Arc clone，如果是则用宏替换
**状态:** 代码已添加，但测试仍失败
**可能问题:**
- expr_ty 可能为 null
- Rc::clone 可能走了不同的代码路径
- 需要调试输出验证代码是否被执行

## 当前状态

### 测试结果
```
SA 文本后端: ✅ 2/2 passing
SAB 后端:    ❌ 1/2 passing (rc refcell struct payload shared mutation fails)
```

### 已修改文件 (未提交)
```
M  src/lowering_rules.zig  (+13 行: associatedRuleNeedsUnderlyingSmartPointer)
M  src/sab_codegen.zig     (+66 行: genRcArcCloneCall + emitPlannedStaticCall 修改)
M  progress.md             (添加调查记录)
M  tasks.md                (添加待办项)
A  WORK_SESSION_SUMMARY.md (本文件)
A  COMPLETION_STATUS.md    (状态文档)
```

### 构建状态
- ✅ Plugin 成功编译 (`zig build -Doptimize=ReleaseSmall`)
- ✅ 生成 `zig-out/lib/libsla.so` 和 `zig-out/bin/sla-local-cli`
- ⚠️  Plugin 安装超时（可能由于并发构建问题）

## 下一步行动

### 立即需要
1. **调试 emitPlannedStaticCall**
   - 添加 std.debug.print 输出确认代码执行
   - 验证 expr_ty 是否为 null
   - 验证类型检查逻辑（rcInnerType/arcInnerType）

2. **验证代码路径**
   - 确认 Rc::clone 确实调用了 emitPlannedStaticCall
   - 如果不是，找到实际的代码路径

3. **修复后验证**
   - SAB 反汇编应包含 `EXPAND RC_CLONE_OUT` 或类似宏调用
   - tests/test_unit_refcell_struct_payload.sla 应全部通过（2/2）
   - 检查其他失败测试是否也修复

### 中期目标
- 完成 Slice 1C.1 的 Rc/Arc clone 修复
- 解决 Slice 1D 的调用语法问题
- 提交合并的 Slice 1C+1D 修复

## 技术笔记

### SAB vs SA 文本后端差异
- SA 文本后端有许多硬编码的特殊情况处理
- SAB 后端试图更通用，但缺少关键的特殊情况
- 需要在 SAB 中复制这些特殊处理

### Rc::clone 的预期行为
```zig
// Input: Rc::clone(&rc1)
// Expected SAB:
EXPAND RC_CLONE_OUT out_reg, rc1_reg
// (NOT: call @rc_clone(borrow_reg))
```

### 调试技巧
- 使用 `SLA_SAB_NO_FALLBACK=1` 禁用 fallback
- 使用 `sa sla sab disasm` 检查生成的 SAB
- 对比 `sa sla build` 生成的 SA 文本
- 搜索 `RC_CLONE` 或 `EXPAND` 确认宏是否被使用

## 参考资料
- SA Rc 实现: `/home/vscode/projects/sci/sa_std/core/rc.sa`
- SA 文本 Rc::clone 处理: `src/codegen.zig:10366-10372`
- SAB 修复位置: `src/sab_codegen.zig:4858-4886`
- lowering_rules: `src/lowering_rules.zig:259-271`
