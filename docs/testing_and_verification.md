# Testing and Verification Gate Guide

> This is the English counterpart of the Chinese document [测试与验证门禁指南](./testing_and_verification_cn.md).

> **Document version**: v0.1 / 2026-07-01
> **Status**: Based on the verification gate standards in `tasks.md` and `progress.md`
> **Related**: [`architecture_cn.md`](./architecture_cn.md), [`roadmap_status_cn.md`](./roadmap_status_cn.md)

---

## 1. Testing Framework

The Sla language has built-in testing support using `@test` declarations:

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

### 1.1 `@test` Syntax

```
@test [ignored] [should_panic] "name"() {
    // 测试体
}
```

- `ignored` — marks the test as skipped (not run)
- `should_panic` — the test is expected to trigger a panic (panic counts as a pass, no panic counts as a failure)
- The test body is a void-returning, parameterless block
- The name must be a string literal

### 1.2 Running Tests

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

# SAB 路径即直接路径（无回退可禁用；未覆盖特性直接报错）
sa sla test tests/test_unit_basic.sla --test-backend sab
```

### 1.3 Test Backends

| Backend | Command | Description |
|---------|---------|-------------|
| `auto` (default) | Direct SAB (the only emission path), unsupported features fail loudly | Recommended for daily use |
| `sab` | Explicitly requires the SAB path; errors if unsupported | Verifies the direct path in CI |
| `sa` | Legacy SA-text backend (generates `.test.sa`) | For explicitly debugging the text path |

---

## 2. No-Fallback Testing

**No-fallback** is now the unconditional behavior of the SAB path and a core indicator of Y-shaped architecture completeness: the SA-compatible fallback was removed on 2026-09-28 (commit `e96e6b39`), and any unsupported feature now fails loudly with `UnsupportedSabDirectFeature`; there is no silent fallback. The historical `SLA_SAB_NO_FALLBACK=1` switch is no longer read by the source code, and the variable has been removed from the commands below. Therefore a no-fallback sweep is simply the ordinary pass rate of the SAB path.

### 2.1 Running the Full No-Fallback Sweep

```bash
# 本地扫描命令
rm -f /tmp/sla-sweep-failures.log
passed=0; total=0
for f in tests/test_unit_*.sla; do
    total=$((total+1))
    if timeout 120s ./zig-out/bin/sla-local-cli sla test "$f" --test-backend sab --jobs 1 --trace-panic >/tmp/sla-sweep-one.log 2>&1; then
        passed=$((passed+1))
    else
        printf 'FAIL %s\n' "$f" | tee -a /tmp/sla-sweep-failures.log
        tail -30 /tmp/sla-sweep-one.log | tee -a /tmp/sla-sweep-failures.log
    fi
done
printf 'PASS %s/%s\n' "$passed" "$total"
```

### 2.2 Host (Installed Plugin) Sweep

```bash
SA_PLUGIN_DEV=1 sa plugin install --dev .
passed=0; total=0
for f in tests/test_unit_*.sla; do
    total=$((total+1))
    if SA_PLUGIN_DEV=1 timeout 120s sa sla test "$f" --test-backend sab --jobs 1 --trace-panic >/tmp/host-sweep-one.log 2>&1; then
        passed=$((passed+1))
    else
        printf 'FAIL %s\n' "$f" | tee -a /tmp/host-sweep-failures.log
    fi
done
printf 'HOST PASS %s/%s\n' "$passed" "$total"
```

### 2.3 Debugging Unsupported Surfaces

Use trace mode to see which features are unsupported:

```bash
SLA_SAB_TRACE_UNSUPPORTED=1 timeout 180s \
    ./zig-out/bin/sla-local-cli sla test tests/test_unit_xxx.sla \
    --test-backend sab --jobs 1 --trace-panic
```

---

## 3. 9-Step Verification Gates

Every feature increment (feature slice) must pass all of the following gates before it can be marked 100% complete. These are the formal standards extracted from `tasks.md`.

### Gate Checklist

| Step | Command | What Is Checked |
|------|---------|-----------------|
| **1. Code format** | `zig fmt` | Consistent code formatting |
| **2. Build** | `zig build --summary all` | Compiles with no errors |
| **3. Unit tests** | `zig build test --summary all` | All Zig unit tests pass |
| **4. Plugin install** | `sa plugin install --dev .` | Plugin is correctly installed into the SA environment |
| **5. CLI available** | `SA_PLUGIN_DEV=1 sa sla help` | Installed CLI commands are usable |
| **6. Local No-Fallback** | Local sweep (see §2.1) | New feature passes direct SAB |
| **7. Host No-Fallback** | Host sweep (see §2.2) | Passes direct SAB after installation |
| **8. SA-text parity** | `--test-backend sa` comparison | New feature's output matches the SA-text backend |
| **9. Regression check** | Stored regression test list | Existing features are not broken |
| **10. Diff check** | `git diff --check` | No whitespace problems, no unexpected changes |

### 3.1 Progress Report Template

After each completed feature increment, report in this format:

```
Feature: <name> 100%
Y/shared-lowering: <old>% -> <new>%
direct SAB fallback-removal: <old>% -> <new>%
no-fallback sweep: <passed>/<total>
host gate: passed
commit: <hash or pending>
```

---

## 4. Regression Tests

### 4.1 Current Regression Set

The following tests are confirmed to pass direct SAB no-fallback and must be re-verified after every new feature increment:

```bash
# 智能指针/RefCell
sa sla test tests/test_unit_borrow_temp_release_order.sla --test-backend sab
sa sla test tests/test_unit_refcell_struct_payload.sla --test-backend sab
sa sla test tests/test_unit_smart_pointer_struct_field_cleanup.sla --test-backend sab

# Option/Result
sa sla test tests/test_unit_option_methods.sla --test-backend sab
sa sla test tests/test_unit_option_direct.sla --test-backend sab
sa sla test tests/test_unit_result_direct.sla --test-backend sab

# 宏
sa sla test tests/test_unit_user_macro_direct.sla --test-backend sab
sa sla test tests/test_unit_pkgjson_codegen.sla --test-backend sab

# trait 静态分发
sa sla test tests/test_unit_trait_static_dispatch.sla --test-backend sab

# 外部回归（sla_ecs 项目）
sa sla test /home/vscode/projects/sla_ecs/lib/parallel.sla --test-backend sab
```

### 4.2 Direct-Path Regression Tests

When adding a new direct SAB lowering, it must include a Zig regression test that compiles via `compileSlaFileToSabWithOptions`, asserts success, and asserts that no `.test.sa` file is produced, ensuring the new feature really goes through direct SAB (the fallback mechanism has been removed and the old `.allow_fallback = false` option no longer exists):

```zig
test "sla sab backend lowers xxx directly" {
    // ...经 compileSlaFileToSabWithOptions 编译并断言返回 SAB 字节...
    // 检查解码后的 SAB 包含结构化指令，无逐指令原始文本
}
```

---

## 5. SAB Disassembly Debugging

Verify that no illegal call-target format appears in SAB artifacts:

```bash
# 检查 call target 是否包含参数（非法格式）
sa sla sab disasm <file.sab> | grep 'call .*@[^" ]\+('
# 正确格式返回无匹配：call rN,"@func","args"
# 非法格式包含：call rN,"@func(arg)"  ← 不应出现
```

---

## 6. Performance Profiling

```bash
# 启用阶段计时
SLA_PROFILE=1 sa sla test tests/test_unit_xxx.sla

# 获取 SAB 路径的详细计时
SLA_PROFILE=1 timeout 120s \
    ./zig-out/bin/sla-local-cli sla test tests/test_unit_xxx.sla \
    --test-backend sab --jobs 1 --trace-panic
```

Sample output:
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

## 7. CI Recommendations

Recommended CI flow:

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
      - run: sa sla test <regression-set> --test-backend sab
```
