# Codex 后端的 SLA 重构与改进顺序（以改进 SLA/SA 自身为首要任务）

> 编制依据：真实已完成代码调研，而非 SALA 帮助站中可能过时的说明。
>
> 主要调研对象包括：
>
> - `D:\projects\codex-ultra\apps\server\src` 中的真实后端模块（订阅注册表、Writer 租约、跨平台桥、API 运行时等）
> - `E:\projects\sla\sci\sa_std\core\{waker,task,future,option,result}.sa`、`async_demo/src/main.sla`
> - `E:\projects\sla\sci\src\runtime\sa_net_uring.zig`、`sa_net_primitives.zig`
> - `E:\projects\sla\sa_plugin_http_client\src\http_v2_api.zig`、`sa_plugin_http_server\src\vite_api.zig`
> - `E:\projects\sla\evaluation_sla_vs_codex.md`、`E:\projects\sla\improvement_plan_cn.md`
>
> 本文档的核心前提是：如果必须用 SLA 重构本程序后端，首要任务是**先把 SLA/SA 改造到能够表达和运行这种后端的程度**，而不是一开始就翻译 TypeScript。

---

## 1. 前提与结论先行

从真实代码来看，SLA 语言本人和编译器骨架已经可以承载**大型同步工程**，也具备完整的异步状态机编译能力（`.await`、`Poll/Waker/RawWakerVTable/Task/Executor` 宏面都已存在）。但 **能够驱动 Codex 风格后端的能力**——跨平台异步 I/O、waker 驱动的执行器、定时器集成、线程安全原语、成熟的序列化协议层、进程/租约/资源生命周期管理——在 SLA 侧还没有成熟实现。

所以结论是：

- 现在的 SLA 还不能直接替代本程序后端的 Bun/Node 异步运行时。
- 如果任务目标是“用 SLA 重构后端”，那真正的第一步是**改造 SLA/SA 自身**，再逐步把后端模块接纳进来。
- 在语言和运行时能力未达标之前，任何“直接重写订阅注册表”之类的尝试都会卡在执行器、定时器、异步网络或序列化能力上。

---

## 2. 改造目标的定义

### 2.1 对 SLA/SA 的目标

到各阶段结束时，SLA 需要具备如下**可验证能力**：

1. **异步执行器**：不再是轮询数组；waker 被真正接通；能够低 CPU 空转地等待大量挂起任务。
2. **定时器集成**：延时唤醒在执行器内部完成，而不是忙轮询。
3. **跨平台异步网络**：至少在 Windows 上也能非阻塞地做 TCP/WS 的出站和入站。
4. **异步资源生命周期**：`&mut self / &mut T` 阶段落地后，能为异步 Mutex/通道/租约等写出正确、无数据竞争、无双重释放的代码。
5. **序列化/反序列化等价物**：能干净地处理 JSON、JSON-RPC、元数据结构，不出现明显生命周期冲突或 MemoryLeak。
6. **并发原语**：mpsc/异步锁/任务间通知等，足以表达订阅重试、lease 刷新、引用计数式桥释放等模式。

### 2.2 对后端的目标

最终目标不是平均地翻译所有代码，而是：

- 先保留现有 Node/Bun 宿主运行时的事件循环和进程模型，把 SLA 用作**沙箱任务语言**或**部分后端组件的实现语言**；
- 随着 SLA/SA 的运行时和生态逐步成熟，再逐步将生命周期越来越复杂的模块迁移进 SLA；
- 始终保证订阅、租约、桥生命周期、瞬断恢复这些语义不丢失、不退化。

---

## 3. 改造与改进的总顺序（SLA/SA 优先）

整个工作分为 5 个大的阶段。每个阶段的首要成果都是 SLA/SA 本身的能力提升，只有当阶段内的验收条件达成，才允许开始下一阶段的真后端迁移。

```
Phase 0  现状实勘与基准确立
Phase 1  语言侧关键缺口 repair（重点在 &mut / 泛型函数 / JSON 生命周期）
Phase 2  异步运行时重写（轮询数组 → waker 驱动执行器 + 定时器）
Phase 3  跨平台异步网络 + 协议/序列化层 + 并发原语
Phase 4  沙箱/进程模型 + 后端可迁移单元的验证
Phase 5  后端分层迁移（只在前面阶段通过后才动）
```

下面逐阶段详细说明**改进 SLA/SA 的具体任务、涉及真实文件、验收条件**。

---

## 4. Phase 0 — 现状实勘与基准确立

### 4.1 目标

- 精确留存当前 SLA 真实能力的基线，避免后面误判进度。
- 拿 Codex 后端真实模块的行为建立验收标准，特别是订阅状态机、租约刷新、重试退避、瞬断恢复。

### 4.2 必须做的事

1. 给出一份 SLA 端到端回归基线清单，包括：
   - `async_demo/src/main.sla` 能否编译并跑通；
   - `sci/sa_std/core/waker.sa`、`task.sa`、`future.sa` 中每个公开宏的最小使用样例是否能编译；
   - `sa_plugin_http_client/src/http_v2_api.zig` 暴露的 C 函数能否从 SLA 侧调用（如果有入口）；
   - `sci/src/runtime/sa_net_uring.zig` 的 echo server demo 是否在 Linux 上真的能跑。
2. 给出 Codex 后端的行为基准清单：
   - `threadSubscriptionRegistry.ts` 中 `watch -> ensureSubscribed -> retry -> markSubscribed` 的延时和重试语义；
   - `threadWriterLeaseStore.ts` 中 `acquire / renewAll / reclaimDeadProcessLeases` 的 TTL 和实例冲突行为；
   - `sharedThreadBridgeRegistry.ts` 的最后一次 release 才调用 `bridge.stop()` 的语义；
   - `agyBridge.ts` / `codexBridge.ts` / `remoteThreadLifecycle.ts` 中的重连/瞬断回放行为。
3. 把上面这些行为转换为**小型独立样例**，后面 SLA 端的每个阶段都要能用它们来验收。

---

## 5. Phase 1 — 语言侧的关键缺口 repair（这才是改造 SLA/SA 的起点）

### 5.1 为什么这是第一件要做的事

目前代码、评估文档和改进计划都显示，SLA 语言本身还存在若干会直接阻塞后端开发的硬伤：

- `&mut T / &mut self` 尚未引入（评估文档中明确列为解析期报错的 Phase 2 项）；
- 泛型自由函数在 SAB 后端会触发 MemoryLeak trap；
- trait-bound 泛型出现“Undefined call”；
- JSON DOM 使用存在生命周期冲突与内存泄漏，用户层无法干净使用；
- 官方 async demo 的 `Box future` 参数 lowering 存在缺陷导致编译失败。

后端里充满了**可变借用、异步资源、复杂泛型、JSON 消息**，如果这些硬伤不填，后面写出的代码要么编译不过，要么无法安全运行。

### 5.2 Phase 1 的具体 SLA/SA 改造任务

#### 5.2.1 `&mut` 阶段性落地

目标：

- 在 `sa_plugin_sla` 中设计并实现至少 Phase 0~1 级别的 `&mut` 支持，使得异步 Mutex/租约/通道等资源的签名可以写出来；
- 并不要求一步到位支持所有模式，但至少允许异步资源在“可变独占访问”语义下表达。

涉及真实文件（示例，实际以代码库为准）：

- `sci/` 中负责借用检查、符号、类型表的部分；
- `sa_plugin_sla/src/lowering_rules.zig`（大量 dyn/`&mut` 相关 lowering 都可能在这里）；
- 任何负责 SA 中 `&mut` 类型的表示与代码生成的模块。

验收条件：

- 能编译通过一个最小异步 Mutex `lock` 风格的例子；
- Referee 不报告 UseAfterMove / DoubleFree / MemoryLeak。

#### 5.2.2 泛型函数与 trait-bound 泛型的正确性 repair

目标：

- 修复 SAB 后端中泛型自由函数导致 MemoryLeak trap 的问题；
- 修复 trait-bound 泛型导致“Undefined call”的问题；
- 确保 `Vec<T>`、迭代器链、泛型结构体这类在后端中广泛使用的值类型能稳定工作。

涉及真实文件：

- SA 的泛型实例化、代码生成、类型表相关代码；
- `sci/` 中 flattener / LLVM-C 后端 / 解释器中与泛型相关的路径；
- `sa_plugin_sla` 中负责类型检查与 lowering 的部分。

验收条件：

- 能编译通过 `serialize::to_json<T>(value: T)` 风格的最小例子（即便目前功能简单）；
- 泛型函数不在真实任务中导致 MemoryLeak / Undefined call。

#### 5.2.3 JSON 生命周期与内存管理的干净路径

目标：

- 提供一种不和托管生命周期冲突的 JSON DOM 使用方式；
- 能做到“解析 → 读字段 → 释放”全程不出现 MemoryLeak 和 UseAfterMove；
- 为后续的协议层改造打下基础。

验收条件：

- 写一个 SLA 小程序：从字节数组解析 JSON，取若干字段，完成后正确释放；
- 在真实分配器下无泄漏、无悬挂指针。

---

## 6. Phase 2 — 异步运行时重写（轮询数组 → waker 驱动执行器 + 定时器）

### 6.1 当前情况（从真实代码看）

- `sci/sa_std/core/task.sa` 中的 Executor 还是**固定数组 + 顺序轮询**的形式：
  - `EXECUTOR_NEW` 接收 `tasks_ptr + len`
  - `EXECUTOR_POLL_ONE` 按索引取任务并 `TASK_POLL`
  - `EXECUTOR_RUN_UNTIL_COMPLETE` 不断轮询直到所有任务就绪
- `async_demo/src/main.sla` 的 `block_on` 实现也是一次性同步轮询，若未就绪直接 `panic(93)`；
- demo 中的并发是靠**每个 session 一个线程**，而不是事件循环驱动。

这意味着现在的 SLA async 还不能支撑：

- 大量挂起的订阅等待；
- 定时重试退避；
- 长时间的 WebSocket 空等；
- lease 刷新定时器。

### 6.2 Phase 2 的具体 SLA/SA 改造任务

#### 6.2.1 任务队列变成可动态增长、能重新入队的结构

目标：

- 把执行器内部的任务存储从固定数组改为动态队列（先 `Vec<Task>`，后续再考虑更高性能结构）；
- 允许任务在 poll 返回 Pending 后保留在某个“等待集合”里，而不是每一轮都被顺序扫描。

验收条件：

- 单执行器上挂起 N 个睡眠任务时，CPU 占用不再是轮询那种级别；
- 任务完成后能被正确取出。

#### 6.2.2 真正接通 waker 通路

目标：

- 当 `poll` 返回 Pending 时，任务把 waker 记录到对应的等待上下文中；
- 事件/定时器触发时调用 `wake()`，使任务重新进入可运行队列；
- `RawWakerVTable` 中已有的 clone/wake/wake_by_ref/drop 宏真正被运行时使用。

涉及真实文件：

- `sci/sa_std/core/waker.sa` 中已有的 VTable 骨架；
- `sci/sa_std/core/future.sa` 中的 Context/Poll 组合子；
- 执行器实现（可能在 `sci/sa_std/core/task.sa` 或未来的新 runtime 模块中）。

验收条件：

- `sleep_ms` 风格任务在等待期间不忙轮询 CPU；
- 唤醒后的任务能正确继续执行。

#### 6.2.3 定时器能力集成

目标：

- 执行器中集成基本定时器，使 `sleep_ms`、`sleep_until`、超时组合子等能在不阻塞线程的情况下工作；
- 与 waker 唤醒衔接：定时器到期时把对应的任务重新入队。

验收条件：

- 成百上千个定时任务能稳定运行并不导致内存无限增长；
- 定时唤醒的时间误差在可接受范围。

#### 6.2.4 兼容层：不要把已有大工程全部掰掉

目标：

- 在 `task.sa` 中保留旧的 `EXECUTOR_NEW / EXECUTOR_POLL_ONE` 等宏接口，内部走新队列；
- 允许 `sla_ecs` 这样的大型同步工程继续使用原有并发模型，不强迫它整体变成异步。

验收条件：

- `sla_ecs` 大量现有测试继续通过；
- 异步执行器是新增能力，不是强制替换。

---

## 7. Phase 3 — 跨平台异步网络 + 协议/序列化层 + 并发原语

### 7.1 背景

目前：

- 异步网络在 SLA 侧仅在 Linux 上通过 `sa_net_uring.zig` 提供了 io_uring 多 reactor；
- Windows 上只有阻塞式 Winsock；
- 全库范围内没有 IOCP/epoll/kqueue 实现；
- `sa_plugin_http_client/src/sa_std_net.zig` 中 WebSocket 帧读取竟然使用**同步 `stream.read` 循环**；
- 序列化层和并发原语（mpsc/异步锁等）在 SLA std 中也尚不成熟。

对于本后端来说，Windows 是主要运行平台，网络出站/入站、WebSocket、重连、全双工流式消息都依赖异步 I/O。如果不解决这个问题，后端根本无法在目标平台上用 SLA 表达。

### 7.2 Phase 3 的具体 SLA/SA 改造任务

#### 7.2.1 Windows 异步网络能力

目标：

- 在 Windows 上提供可用的异步 TCP/WS I/O 能力；
- 可以是 IOCP，也可以是某个可接受的替代异步模型，但不能是纯阻塞式调用。

验收条件：

- Windows 上能跑一个 echo server / client 的异步例子；
- 不会因为每个读写都阻塞整个线程。

#### 7.2.2 执行器与网络 reactor 的接合

目标：

- 让 `sa_net_uring`（Linux）或 Windows 异步网络模块产生的 I/O 完成事件，能通过 waker 唤醒等待中的 SLA 任务；
- 实现类似 `AsyncRead/AsyncWrite` 语义的抽象。

涉及真实文件：

- `sci/src/runtime/sa_net_uring.zig` 中的 reactor 主循环、ticket 事件处理；
- 执行器侧的 waker 插入/唤醒路径；
- `sa_plugin_http_client` 中目前的同步帧读取，应逐步改造为能配合异步运行时使用的形式。

验收条件：

- 套接字读写等待时不占用 CPU；
- 多连接下的并发 I/O 能被统一调度。

#### 7.2.3 序列化/反序列化等价物

目标：

- 提供能在 SLA 中干净使用的 JSON 编解码能力；
- 至少支持 JSON-RPC 风格的消息构造与解析；
- 能处理后端中大量元数据、配置、事件结构的序列化需求。

验收条件：

- 能序列化/反序列化嵌套 JSON，不出现生命周期冲突或内存泄漏；
- 能映射到后端现有的 JSON-RPC 消息结构。

#### 7.2.4 并发原语

目标：

- 提供 mpsc 通道（或等价物）、异步 Mutex/RwLock、任务间通知等；
- 能表达订阅状态机中的“等待重试定时器 + 事件通知”组合。

验收条件：

- 能写出带并发通信的小例子，在事件驱动执行器下正确运作。

---

## 8. Phase 4 — 沙箱/进程模型 + 后端可迁移单元的验证

### 8.1 背景

本后端不仅仅是 WebSocket 和 JSON，还包括：

- 子进程管理（agy / Codex CLI / SSH / remote Bun 等）；
- 跨进程甚至跨主机的线程路由、桥生命周期、最后一次 release 才关闭资源的语义；
- SQLite 租约、进程存活性检测、死进程 lease 回收。

这些都需要操作系统级能力。SLA 要么自己提供，要么通过 FFI/插件+宿主运行时来提供。以下选择不是二选一，而是分层：**尽量在 SLA 中表达控制流，必要时借助宿主运行时的原生能力**。

### 8.2 Phase 4 的具体 SLA/SA 改造/集成任务

#### 8.2.1 进程管理与生命周期抽象

目标：

- 提供一种能启动子进程、读写其 stdio、等待退出、检测存活性的抽象；
- Windows 上要能做进程存活性检查（类似 `process.kill(pid, 0)` 的语义）；
- 能表达 `AgyCompatibleProcessManager` 那种“启动 → 发提示 → 读事件流 → 写输入 → 异常处理”的生命周期。

涉及方式：

- 如有必要，先用宿主运行时（Node/Bun）的进程能力封装成可供 SLA 调用的边界；
- 长远看，若 SLA 要独立承担后端，这类能力需要有原生或半原生的实现。

验收条件：

- 能在 SLA 中启动一个子进程、发送一行输入、读取结构化输出、处理错误；
- 能检测子进程是否存活，并在进程意外退出时触发相应的 async 任务唤醒。

#### 8.2.2 引用计数式资源释放语义

目标：

- 在 SLA 侧表达类似 `SharedThreadBridgeRegistry` 的“最后一次 release 才真正 stop”的语义；
- 在 `&mut`/Drop 逐步成熟后，能用类型系统保证释放顺序与唯一性。

验收条件：

- 能写一个桥注册表样例，在最后一次 release 时触发清理回调。

#### 8.2.3 租约/锁冲突模型验证

目标：

- 能在 SLA 中表达带 TTL、实例冲突检测、死进程回收的租约模型；
- 若 SLA DB 插件还不具备这能力，可先用宿主 SQLite 封装，待后续逐步演化。

验收条件：

- 能复现 `threadWriterLeaseStore.ts` 的核心语义：
  - acquire 时实例冲突/过期覆盖判断
  - 定时 renew
  - 死进程 lease 回收

---

## 9. Phase 5 — 后端分层迁移（只在前置阶段通过后才进行）

### 9.1 迁移顺序原则

不能按文件翻译的顺序迁移，而应按**生命周期复杂度由低到高**的顺序迁移：

1. 纯计算/协议编解码类的最小单元；
2. LLM API 请求 + SSE/WS 流式读取（但重试/TLS/出站异步等特性需在 Phase 3 完成后）；
3. 配置/目录/模型选择等状态较简单的服务；
4. 订阅注册表、Writer 租约、桥生命周期、远程线程路由这类最高复杂度模块，最后迁移。

### 9.2 每块迁移时的具体策略

- 不要把整个 `apps/server/src` 一次性换成 SLA；
- 每个模块迁移时，先在 SLA 中实现等价的**可独立测试的核心状态机**；
- 若底层能力（执行器、网络、序列化、进程）尚未完全成熟，仍然通过宿主运行时提供边界服务，SLA 侧只写控制流和状态；
- 迁移完成后，用 Phase 0 中留下的基准样例做回归，确保订阅/租约/重连语义没退化。

---

## 10. 针对本后端的重点验收 checklist

在 SLA/SA 改造过程中，应越早越多地用以下真实后端行为作为验收依据：

- **订阅状态机**
  - `watch` 唤起 `ensureSubscribed`
  - `ensureSubscribed` 在获得 lease 且客户端就绪时调用 `thread/resume`
  - 出 writer conflict 时标记 `leaseBlocked` 并停止重试
  - 在失败时按指数退避重试
  - `unwatch/removeTurnHold` 触发重新评估是否取消订阅
  - `reAttachAll` 在客户端恢复就绪时重新建立订阅

- **Writer 租约**
  - SQLite 表的 on-conflict upsert 语义
  - `instance_id` 粒度的拥有权
  - `expires_at` 基准的 renew/失效判断
  - 启动时回收死进程遗留 lease
  - 定时 `renewAll`

- **桥生命周期**
  - 多处引用时不提前 `stop`
  - 最后一次 release 触发 `bridge.stop()` 和 `onLastRelease`

- **跨平台桥与瞬断**
  - 子进程/远程会话的启动、输入、事件解析、错误处理
  - 瞬时断开时的重连与事件回放，不重复执行有歧义的写入

这些行为是判定“SLA 改造是否到了真的能接后端”的硬指标。

---

## 11. 风险与现实约束

- SLA 的 async 能力目前更像状态机编译能力而非完整运行时，直接拿来写订阅/租约系统会在 waker/定时器/跨平台 I/O 上卡死；
- `&mut` 与异步 RAII 密切相关，延迟释放的异步锁/通道/租约都需要可变独占语义；
- JSON 序列化若不能干净使用，后端消息层将非常脆弱；
- Windows 上的异步网络缺失会导致实际上无法在本机跑起 SLA 写的后端；
- 所有权/借用模型与 Rust/TypeScript 的经验不同，SLA 所有权系统在真实后端负载下的表现需要通过小 milestone 慢慢验证。

---

## 12. 小结

1. 如果必须用 SLA 重构这个后端，**首要任务是改造 SLA/SA 自身**，而不是直接翻译 TypeScript。
2. 改造顺序应是：  
   **语言侧硬伤 repair（&mut/泛型/JSON 生命周期） → 异步运行时重写（waker + 定时器） → 跨平台异步网络 + 序列化 + 并发原语 → 沙箱/进程/租约抽象 → 再分层迁移后端**。
3. 每个阶段都要以本后端真实的生命周期语义（订阅、lease、桥释放、瞬断恢复）作为验收基准。
4. 在前三个阶段未验证之前，不宜迁移订阅注册表、Writer 租约、远程线程路由这类核心模块。
