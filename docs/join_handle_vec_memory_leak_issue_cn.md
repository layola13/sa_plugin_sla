# Vec<JoinHandle<T>> generated-SA MemoryLeak issue

日期：2026-07-06

状态：待修复。2026-07-06 复验：默认/SAB 后端已通过最小探针，但 generated-SA 后端仍报 `MemoryLeak`；`sla_ecs` 下游仅记录问题，不修改 SLA 编译器源码。

## 摘要

`sla_ecs` 为实现 Bevy `TaskPool::scope` 风格的 arbitrary-N worker scheduling，需要把动态数量的 `thread::spawn` 返回值存入 `Vec<JoinHandle<T>>`，之后循环 `join()` 消费所有 handle。

当前 SLA 类型检查允许 `Vec<JoinHandle<i32>>`。默认/SAB 后端当前可以通过最小 index-join 探针，但生成 SA 后端在函数退出时报 `MemoryLeak`。即使先从尾部读取 handle、`join()` 后再 `pop()`，历史复验仍有 active register 残留。这阻塞了下游在以 generated-SA 为主证据时直接实现“动态 N 个 worker handle 存入 Vec 后统一 join”的 executor 路线。

## 2026-07-06 当前复验

当前本地探针：

```text
/home/vscode/projects/sa_plugins/sa_plugin_sla/tests/test_unit_join_handle_vec_direct.sla
```

generated-SA 后端仍失败：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_unit_join_handle_vec_direct.sla \
  --test-backend sa --jobs 1 --trace-panic
```

输出：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "join handle vec index join"():
  line 16893 (expanded 1267):     return
  register: tmp_12
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":"tests/test_unit_join_handle_vec_direct.test.sa","line":1267,"source_line":16893,"register":"tmp_12","actual_mask_name":"Active","function":"@test \"join handle vec index join\"():","message":"live registers remain at function exit"}
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

结论：SAB 路径已有改善，但 generated-SA 仍不能作为 `Vec<JoinHandle<T>>` 动态 worker executor 的通过证据。`sla_ecs` 继续使用固定 arity pthread runner + dynamic catalog waves 路线。

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

## pop 后仍失败

改成尾部读取、join 后 pop：

```sla
while len(handles) as i64 > 0 {
    let index = len(handles) as i64 - 1;
    let handle = handles[index];
    total = total + handle.join().unwrap();
    handles.pop();
}
```

类型检查仍通过，但生成 SA 后端仍失败：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "join handle vec probe"():
  line 17047 (expanded 1289):     return
  register: tmp_11
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":"tests/tmp_join_handle_vec_probe.test.sa","line":1289,"source_line":17047,"register":"tmp_11","actual_mask_name":"Active","function":"@test \"join handle vec probe\"():","message":"live registers remain at function exit"}
```

## 影响

`sla_ecs` 目前只能使用固定局部变量保存 `JoinHandle`，例如 pair/triple/quad pthread batch：

```sla
let first_handle = thread::spawn(^|| first(first_ptr));
let second_handle = thread::spawn(^|| second(second_ptr));
return first_handle.join().unwrap() + second_handle.join().unwrap();
```

这条固定 arity 路线已在 generated-SA 后端验证通过。但只要需要 arbitrary-N worker scheduling，就必须能把动态数量的 `JoinHandle<T>` 存入容器并逐个消费；当前 `Vec<JoinHandle<T>>` 的 active register 泄漏阻塞了这条实现路线。

## 初步判断

可能问题点：

- `Vec<T>` 对 affine / owning 元素类型的 index move-out 后，容器槽位所有权状态没有被标记为 consumed；
- `JoinHandle<T>.join()` 消费 handle 后，原 `Vec` 元素或临时寄存器仍被 verifier 视为 active；
- `Vec.pop()` 只调整长度，但没有释放或消费非 Copy/owning 元素的 register state；
- generated-SA verifier 对 `Vec<JoinHandle<T>>` 这类 std/thread affine handle 缺少专门 drop / consume lowering。

建议编译器侧优先确认：

- `Vec<T>` 是否支持非 Copy / affine owning 元素类型；
- 从 `Vec<T>` index 读取时的语义是 borrow、copy 还是 move；
- `pop()` 对 owning 元素是否需要返回值或显式 drop；
- `JoinHandle<T>` 是否需要在 Vec 元素析构/移除时做特殊状态迁移，避免 active register 残留。
