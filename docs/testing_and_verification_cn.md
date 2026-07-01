# 测试与验证门禁指南

> **文档版本**：v0.1 / 2026-07-01
> **状态**：基于 `tasks.md` 和 `progress.md` 中的验证门禁标准
> **关联**：[`architecture_cn.md`](./architecture_cn.md)、[`roadmap_status_cn.md`](./roadmap_status_cn.md)

---

## 1. 测试框架

Sla 语言内置测试支持，使用 `@test` 声明：

```sla
@test "basic arithmetic" {
    let result = 1 + 2;
    assert(result == 3);
}

@test ignored "work in progress" {
    // 被 @test ignored 标记的测试被跳过
}

@test should_panic "division by zero" {
    let x = 1 / 0;
}
```

### 1.1 `@test` 语法

```
@test [ignored] [should_panic] "name"() {
    // 测试体
}
```

- `ignored` — 标记测试为跳过（不运行）
- `should_panic` — 测试应触发 panic（panic 算通过，不 panic 算失败）
- 测试体是 void 返回、无参数的块
- 名称必须是字符串字面量

### 1.2 运行测试

```bash
# 默认后端（SAB，推荐）
sa sla test tests/test_unit_basic.sla

# 指定后端
sa sla test tests/test_unit_basic.sla --test-backend sab   # 明确 SAB
sa sla test tests/test_unit_basic.sla --test-backend sa    # 传统 SA 文本路径

# 过滤测试
sa sla test tests/test_unit_basic.sla --filter "arithmetic"

# 查看性能计时
SLA_PROFILE=1 sa sla test tests/test_unit_basic.sla

# 禁用回退（仅直接路径通过）
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_basic.sla --test-backend sab
```

### 1.3 测试后端

| 后端 | 命令 | 说明 |
|------|------|------|
| `auto`（默认） | 先尝试直接 SAB，失败则用 SA 兼容回退 | 推荐日常使用 |
| `sab` | 明确要求 SAB 路径，不支持则报错 | CI 中验证直接路径 |
| `sa` | 传统 SA 文本后端（生成 `.test.sa`） | 调试回退路径用 |

---

## 2. No-Fallback 测试

**No-fallback** 模式是 Y 型架构完成度的核心指标。当设置 `SLA_SAB_NO_FALLBACK=1` 时，SAB 路径不会回退到 SA 兼容编码器，任何不受支持的特性会直接报错而非静默回退。

### 2.1 运行 No-Fallback 全面扫描

```bash
# 本地扫描命令
rm -f /tmp/sla-sweep-failures.log
passed=0; total=0
for f in tests/test_unit_*.sla; do
    total=$((total+1))
    if SLA_SAB_NO_FALLBACK=1 timeout 120s ./zig-out/bin/sla-local-cli sla test "$f" --test-backend sab --jobs 1 --trace-panic >/tmp/sla-sweep-one.log 2>&1; then
        passed=$((passed+1))
    else
        printf 'FAIL %s\n' "$f" | tee -a /tmp/sla-sweep-failures.log
        tail -30 /tmp/sla-sweep-one.log | tee -a /tmp/sla-sweep-failures.log
    fi
done
printf 'PASS %s/%s\n' "$passed" "$total"
```

### 2.2 Host（已安装插件）扫描

```bash
SA_PLUGIN_DEV=1 sa plugin install --dev .
passed=0; total=0
for f in tests/test_unit_*.sla; do
    total=$((total+1))
    if SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 timeout 120s sa sla test "$f" --test-backend sab --jobs 1 --trace-panic >/tmp/host-sweep-one.log 2>&1; then
        passed=$((passed+1))
    else
        printf 'FAIL %s\n' "$f" | tee -a /tmp/host-sweep-failures.log
    fi
done
printf 'HOST PASS %s/%s\n' "$passed" "$total"
```

### 2.3 不支持的表面调试

使用跟踪模式查看哪些特性触发了回退：

```bash
SLA_SAB_TRACE_UNSUPPORTED=1 SLA_SAB_NO_FALLBACK=1 timeout 180s \
    ./zig-out/bin/sla-local-cli sla test tests/test_unit_xxx.sla \
    --test-backend sab --jobs 1 --trace-panic
```

---

## 3. 9 步验证门禁

每个功能增量（feature slice）在标记为 100% 完成之前，必须通过以下所有门禁。这是从 `tasks.md` 中提取的正式标准。

### 门禁清单

| 步骤 | 命令 | 检查内容 |
|------|------|---------|
| **1. 代码格式** | `zig fmt` | 代码格式一致 |
| **2. 构建** | `zig build --summary all` | 编译通过，无错误 |
| **3. 单元测试** | `zig build test --summary all` | 所有 Zig 单元测试通过 |
| **4. 插件安装** | `sa plugin install --dev .` | 插件正确安装到 SA 环境 |
| **5. CLI 可用** | `SA_PLUGIN_DEV=1 sa sla help` | 安装后的 CLI 命令可用 |
| **6. 本地 No-Fallback** | 本地扫描（见 §2.1） | 新增功能通过 direct SAB |
| **7. Host No-Fallback** | 主机扫描（见 §2.2） | 安装后通过 direct SAB |
| **8. SA 文本对等性** | `--test-backend sa` 对比 | 新增功能与 SA 文本后端输出一致 |
| **9. 回归检查** | 存放回归测试列表 | 已有功能不被破坏 |
| **10. Diff 检查** | `git diff --check` | 无空格问题、无意外变更 |

### 3.1 进度报告模板

每个完成的功能增量后，按此格式报告：

```
Feature: <name> 100%
Y/shared-lowering: <old>% -> <new>%
direct SAB fallback-removal: <old>% -> <new>%
no-fallback sweep: <passed>/<total>
host gate: passed
commit: <hash or pending>
```

---

## 4. 回归测试

### 4.1 当前回归集

以下测试已确认通过 direct SAB no-fallback，必须在每次新功能增量后重新验证：

```bash
# 智能指针/RefCell
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_borrow_temp_release_order.sla --test-backend sab
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_refcell_struct_payload.sla --test-backend sab
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_smart_pointer_struct_field_cleanup.sla --test-backend sab

# Option/Result
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_option_methods.sla --test-backend sab
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_option_direct.sla --test-backend sab
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_result_direct.sla --test-backend sab

# 宏
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_user_macro_direct.sla --test-backend sab
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_pkgjson_codegen.sla --test-backend sab

# trait 静态分发
SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_trait_static_dispatch.sla --test-backend sab

# 外部回归（sla_ecs 项目）
SLA_SAB_NO_FALLBACK=1 sa sla test /home/vscode/projects/sla_ecs/lib/parallel.sla --test-backend sab
```

### 4.2 直接路径回归测试

当添加新的直接 SAB lowering 时，必须包含 `allow_fallback = false` 的 Zig 回归测试，确保新功能不能在静默回退下通过：

```zig
test "sla sab backend lowers xxx directly" {
    // ...构建 SAB 选项时使用 .{ .allow_fallback = false }...
    // 检查解码后的 SAB 包含结构化指令，无逐指令原始文本
}
```

---

## 5. SAB 反汇编调试

验证 SAB 工件中无非法调用目标格式：

```bash
# 检查 call target 是否包含参数（非法格式）
sa sla sab disasm <file.sab> | grep 'call .*@[^" ]\+('
# 正确格式返回无匹配：call rN,"@func","args"
# 非法格式包含：call rN,"@func(arg)"  ← 不应出现
```

---

## 6. 性能剖析

```bash
# 启用阶段计时
SLA_PROFILE=1 sa sla test tests/test_unit_xxx.sla

# 获取 SAB 路径的详细计时
SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 timeout 120s \
    ./zig-out/bin/sla-local-cli sla test tests/test_unit_xxx.sla \
    --test-backend sab --jobs 1 --trace-panic
```

输出示例：
```
[sla-profile] read source: 2ms
[sla-profile] source expand: 1ms
[sla-profile] parse: 12ms
[sla-profile] import expand: 45ms
[sla-profile] test filter prune: 1ms
[sla-profile] monomorphize: 8ms
[sla-profile] load contracts: 23ms
[sla-profile] type check: 15ms
[sla-profile] primary decl filter: 1ms
[sla-profile] sab direct codegen: 24ms
```

---

## 7. CI 建议

建议的 CI 流程：

```yaml
# 每个 PR 运行
jobs:
  test:
    steps:
      - run: zig fmt --check
      - run: zig build --summary all
      - run: zig build test --summary all
      - run: sa plugin install --dev .
      - run: SA_PLUGIN_DEV=1 sa sla help
      - run: SLA_SAB_NO_FALLBACK=1 sa sla test <regression-set> --test-backend sab
```
