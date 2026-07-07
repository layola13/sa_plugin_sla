# Vec<JoinHandle<T>> generated-SA MemoryLeak issue

日期：2026-07-06

状态：已修复并验证。`sla_ecs` 下游仅作为问题来源和未来回归证据，不修改 SLA 编译器源码。

## 摘要

`sla_ecs` 为实现 Bevy `TaskPool::scope` 风格的 arbitrary-N worker scheduling，需要把动态数量的 `thread::spawn` 返回值存入 `Vec<JoinHandle<T>>`，之后循环 `join()` 消费所有 handle。

当前 SLA 类型检查允许 `Vec<JoinHandle<i32>>`。历史上默认/SAB 后端可以通过最小 index-join 探针，但生成 SA 后端会在函数退出时报 `MemoryLeak`。主根因不是 JoinHandle 容器槽本身，而是 while 条件里的 `len(handles) as i64` cast 结果被普通二元表达式当成调用参数形态处理，未释放物化出来的 cast 临时寄存器。后续 10s 本地复验又暴露了同一 fixture 的 SA-text `JoinHandle.join()` receiver 二次 cleanup：`THREAD_JOIN_STATUS ..., *handle` 已消费 receiver storage，`join()` lowering 末尾不能再发 `!handle`，只能把实际 receiver register 标记为 consumed。

## 2026-07-06 修复复验

当前本地探针：

```text
/home/vscode/projects/sa_plugins/sa_plugin_sla/tests/test_unit_join_handle_vec_direct.sla
```

generated-SA 后端通过：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_unit_join_handle_vec_direct.sla \
  --test-backend sa --jobs 1 --trace-panic
```

结果：

```text
[PASS] join handle vec index join
test result: ok. 1 passed; 0 failed; 0 skipped
```

默认/SAB 后端通过：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_unit_join_handle_vec_direct.sla \
  --jobs 1 --trace-panic
```

结果：

```text
[PASS] join handle vec index join
test result: ok. 1 passed; 0 failed; 0 skipped
```

修复点：`src/lowering_rules.zig` 新增共享 `isPointerCarrierCastType()` / `castResultMaterializesTemp()`，`src/codegen.zig` 的 SA-text 普通二元表达式现在按表达式结果寄存器是否物化为临时值来释放操作数，而不是沿用调用参数 cleanup 判断。指针/借用 carrier cast 仍不会被误释放为普通临时。`JoinHandle.join()` 的 SA-text lowering 现在只释放 status/handle 临时值，并将实际 receiver register 标记 consumed，避免 loop-body cleanup 或 join 末尾对已消费 handle 再发 `!handle`。

新增回归：

- `tests/test_unit_join_handle_vec_direct.sla` 覆盖 `Vec<JoinHandle<i32>>` push、index 读取、`join().unwrap()` 循环汇总。
- `src/codegen.zig` 单测 `binary expression releases materialized cast result` 扫描生成 SA，确认 `len(values) as i64` 这类 cast 结果在二元表达式后有对应 `!tmp` cleanup。

验证：

- `zig build --summary all` 通过。
- `zig build test --summary all`：93/93 通过。
- `zig build test -Dtest-filter="binary expression releases materialized cast result" --summary all` 通过。
- local rebuilt CLI 10s SA-text：`tests/test_unit_join_handle_vec_direct.sla` 1/1 通过，约 1.41s。
- local rebuilt CLI 10s strict direct-SAB no-fallback：同 fixture 1/1 通过，约 1.68s。
- `sa plugin install --dev .` 通过。
- `SA_PLUGIN_DEV=1 sa sla help` 通过。
- installed CLI SA-text 与 strict direct-SAB no-fallback：同 fixture 1/1 通过。

结论：当前最小可复现的 generated-SA `Vec<JoinHandle<T>>` MemoryLeak 已修复。更大的 downstream arbitrary-N executor 仍应在 `sla_ecs` 恢复业务侧测试后作为下游回归证据补跑。

## 复现探针

临时探针曾放在：

```text
/home/vscode/projects/sla_ecs/tests/tmp_join_handle_vec_probe.sla
```

探针内容核心如下：

```sla
@import "sa_std/thread.sa"

fn join_handle_vec_probe_worker_a() -> i32 { return 2; }
fn join_handle_vec_probe_worker_b() -> i32 { return 3; }

@test "join handle vec probe"() {
    let handles: Vec<JoinHandle<i32>> = Vec::new();
    let first = thread::spawn(|| join_handle_vec_probe_worker_a());
    let second = thread::spawn(|| join_handle_vec_probe_worker_b());
    handles.push(first);
    handles.push(second);
    let total: i32 = 0;
    let i: i64 = 0;
    while i < len(handles) as i64 {
        let handle = handles[i];
        total = total + handle.join().unwrap();
        i = i + 1;
    }
    if total != 5 { panic(24200); };
}
```

类型检查通过：

```sh
cd /home/vscode/projects/sla_ecs
SA_PLUGIN_DEV=1 sa sla check tests/tmp_join_handle_vec_probe.sla
```

结果：

```text
Sla Compiler: Successfully parsed and verified syntax and types of tests/tmp_join_handle_vec_probe.sla.
```

生成 SA 后端失败：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/tmp_join_handle_vec_probe.sla \
  --test-backend sa --jobs 1 --trace-panic
```

失败输出：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "join handle vec probe"():
  line 16311 (expanded 1267):     return
  register: tmp_12
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":"tests/tmp_join_handle_vec_probe.test.sa","line":1267,"source_line":16311,"register":"tmp_12","actual_mask_name":"Active","function":"@test \"join handle vec probe\"():","message":"live registers remain at function exit"}
```

## 历史 pop 变体失败

改成尾部读取、join 后 pop：

```sla
while len(handles) as i64 > 0 {
    let index = len(handles) as i64 - 1;
    let handle = handles[index];
    total = total + handle.join().unwrap();
    handles.pop();
}
```

历史复现中，类型检查仍通过，但生成 SA 后端仍失败：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "join handle vec probe"():
  line 17047 (expanded 1289):     return
  register: tmp_11
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":"tests/tmp_join_handle_vec_probe.test.sa","line":1289,"source_line":17047,"register":"tmp_11","actual_mask_name":"Active","function":"@test \"join handle vec probe\"():","message":"live registers remain at function exit"}
```

## 历史影响

修复前，`sla_ecs` 只能使用固定局部变量保存 `JoinHandle`，例如 pair/triple/quad pthread batch：

```sla
let first_handle = thread::spawn(^|| first(first_ptr));
let second_handle = thread::spawn(^|| second(second_ptr));
return first_handle.join().unwrap() + second_handle.join().unwrap();
```

这条固定 arity 路线已在 generated-SA 后端验证通过。当前最小 `Vec<JoinHandle<T>>` index-join 编译器 repro 已修复；下游若恢复 arbitrary-N worker scheduling，还需要在 `sla_ecs` 业务测试中重新验证更完整的 executor 路线。

## 历史初步判断与当前结论

历史怀疑点如下，当前最小 repro 已确认主要触发点是 `len(handles) as i64` cast 临时在普通二元比较后未释放，不是 JoinHandle 容器槽位状态本身：

- `Vec<T>` 对 affine / owning 元素类型的 index move-out 后，容器槽位所有权状态没有被标记为 consumed；
- `JoinHandle<T>.join()` 消费 handle 后，原 `Vec` 元素或临时寄存器仍被 verifier 视为 active；
- `Vec.pop()` 只调整长度，但没有释放或消费非 Copy/owning 元素的 register state；
- generated-SA verifier 对 `Vec<JoinHandle<T>>` 这类 std/thread affine handle 缺少专门 drop / consume lowering。

后续若下游恢复更复杂 arbitrary-N worker scheduling，仍可继续确认以下更大语义面，但它们不再是当前最小 repro 的阻塞项：

- `Vec<T>` 是否支持非 Copy / affine owning 元素类型；
- 从 `Vec<T>` index 读取时的语义是 borrow、copy 还是 move；
- `pop()` 对 owning 元素是否需要返回值或显式 drop；
- `JoinHandle<T>` 是否需要在 Vec 元素析构/移除时做特殊状态迁移，避免 active register 残留。
