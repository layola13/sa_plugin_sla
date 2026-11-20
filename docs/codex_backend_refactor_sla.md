# SLA Refactoring and Improvement Order for the Codex Backend (with Improving SLA/SA Itself as the Primary Task)

> This is the English counterpart of the Chinese document [Codex 后端的 SLA 重构与改进顺序（以改进 SLA/SA 自身为首要任务）](./codex_backend_refactor_sla_cn.md).

> Compiled on the basis of real, completed code research, rather than possibly outdated descriptions in the SALA help site.
>
> Main research subjects include:
>
> - Real backend modules in `D:\projects\codex-ultra\apps\server\src` (subscription registry, Writer leases, cross-platform bridges, API runtime, etc.)
> - `E:\projects\sla\sci\sa_std\core\{waker,task,future,option,result}.sa`, `async_demo/src/main.sla`
> - `E:\projects\sla\sci\src\runtime\sa_net_uring.zig`, `sa_net_primitives.zig`
> - `E:\projects\sla\sa_plugin_http_client\src\http_v2_api.zig`, `sa_plugin_http_server\src\vite_api.zig`
> - `E:\projects\sla\evaluation_sla_vs_codex.md`, `E:\projects\sla\improvement_plan_cn.md`
>
> The core premise of this document is: if the backend of this program must be refactored in SLA, the primary task is to **first transform SLA/SA to the point where it can express and run such a backend**, rather than translating TypeScript from the outset.

---

## 1. Premises and Conclusions First

Judging from the real code, the SLA language itself and the compiler skeleton can already carry **large synchronous projects**, and also possess complete asynchronous state-machine compilation capability (the `.await`, `Poll/Waker/RawWakerVTable/Task/Executor` macro surfaces all exist). But the **capabilities needed to drive a Codex-style backend** — cross-platform async I/O, waker-driven executors, timer integration, thread-safe primitives, a mature serialization/protocol layer, and process/lease/resource lifecycle management — are not yet maturely implemented on the SLA side.

So the conclusions are:

- The SLA of today cannot directly replace this program's backend Bun/Node async runtime.
- If the task goal is "refactor the backend in SLA", then the real first step is to **transform SLA/SA itself**, and only then gradually absorb backend modules.
- Before the language and runtime capabilities are up to par, any attempt such as "directly rewriting the subscription registry" will get stuck on the executor, timers, async networking, or serialization capabilities.

---

## 2. Definition of Transformation Goals

### 2.1 Goals for SLA/SA

By the end of each phase, SLA needs to possess the following **verifiable capabilities**:

1. **Async executor**: no longer a polling array; wakers are genuinely wired up; able to wait on large numbers of suspended tasks with low CPU idle overhead.
2. **Timer integration**: delayed wakeups are handled inside the executor, not by busy polling.
3. **Cross-platform async networking**: at minimum, non-blocking outbound and inbound TCP/WS also works on Windows.
4. **Async resource lifetimes**: once the `&mut self / &mut T` phase lands, it becomes possible to write correct, data-race-free, double-free-free code for async Mutexes/channels/leases, etc.
5. **Serialization/deserialization equivalents**: able to cleanly handle JSON, JSON-RPC, and metadata structures, without obvious lifetime conflicts or MemoryLeaks.
6. **Concurrency primitives**: mpsc, async locks, inter-task notification, etc., sufficient to express patterns such as subscription retries, lease renewal, and reference-counted bridge release.

### 2.2 Goals for the Backend

The ultimate goal is not to translate all code uniformly, but to:

- First retain the existing Node/Bun host runtime's event loop and process model, using SLA as a **sandbox task language** or as the **implementation language for some backend components**;
- As SLA/SA's runtime and ecosystem gradually mature, progressively migrate modules of ever-greater lifecycle complexity into SLA;
- Always ensure that the semantics of subscriptions, leases, bridge lifecycles, and transient-disconnection recovery are not lost or degraded.

---

## 3. Overall Order of Transformation and Improvement (SLA/SA First)

The whole effort is divided into 5 major phases. The primary outcome of each phase is an improvement in SLA/SA's own capabilities; only when the acceptance conditions within a phase are met is the next phase of real backend migration allowed to begin.

```
Phase 0  现状实勘与基准确立
Phase 1  语言侧关键缺口 repair（重点在 &mut / 泛型函数 / JSON 生命周期）
Phase 2  异步运行时重写（轮询数组 → waker 驱动执行器 + 定时器）
Phase 3  跨平台异步网络 + 协议/序列化层 + 并发原语
Phase 4  沙箱/进程模型 + 后端可迁移单元的验证
Phase 5  后端分层迁移（只在前面阶段通过后才动）
```

The following details, phase by phase, the **specific tasks for improving SLA/SA, the real files involved, and the acceptance conditions**.

---

## 4. Phase 0 — Current-State Survey and Baseline Establishment

### 4.1 Goals

- Precisely preserve a baseline of SLA's real current capabilities, to avoid misjudging progress later.
- Establish acceptance criteria from the behavior of real Codex backend modules, especially the subscription state machine, lease renewal, retry backoff, and transient-disconnection recovery.

### 4.2 What Must Be Done

1. Produce an SLA end-to-end regression baseline checklist, including:
   - Whether `async_demo/src/main.sla` compiles and runs through;
   - Whether minimal usage examples for every public macro in `sci/sa_std/core/waker.sa`, `task.sa`, and `future.sa` compile;
   - Whether the C functions exposed by `sa_plugin_http_client/src/http_v2_api.zig` can be called from the SLA side (if there is an entry point);
   - Whether the echo server demo of `sci/src/runtime/sa_net_uring.zig` really runs on Linux.
2. Produce a behavioral baseline checklist for the Codex backend:
   - The delay and retry semantics of `watch -> ensureSubscribed -> retry -> markSubscribed` in `threadSubscriptionRegistry.ts`;
   - The TTL and instance-conflict behavior of `acquire / renewAll / reclaimDeadProcessLeases` in `threadWriterLeaseStore.ts`;
   - The semantics of calling `bridge.stop()` only on the final release in `sharedThreadBridgeRegistry.ts`;
   - The reconnect/transient-disconnection replay behavior in `agyBridge.ts` / `codexBridge.ts` / `remoteThreadLifecycle.ts`.
3. Convert the above behaviors into **small standalone examples** that every later SLA-side phase can use for acceptance.

---

## 5. Phase 1 — Language-Side Key Gap Repair (This Is the Actual Starting Point for Transforming SLA/SA)

### 5.1 Why This Is the First Thing to Do

The current code, evaluation documents, and improvement plan all show that the SLA language itself still has several hard defects that directly block backend development:

- `&mut T / &mut self` has not yet been introduced (explicitly listed in the evaluation document as a Phase 2 item that reports a parse-time error);
- Generic free functions trigger a MemoryLeak trap in the SAB backend;
- Trait-bound generics produce "Undefined call";
- JSON DOM usage has lifetime conflicts and memory leaks, and cannot be used cleanly at the user level;
- The official async demo's `Box future` argument lowering is defective, causing compilation failure.

The backend is full of **mutable borrows, async resources, complex generics, and JSON messages**; if these hard defects are not filled, the code written later will either fail to compile or be unsafe to run.

### 5.2 Specific SLA/SA Transformation Tasks for Phase 1

#### 5.2.1 Phased Landing of `&mut`

Goals:

- Design and implement at least Phase 0~1 level `&mut` support in `sa_plugin_sla`, so that signatures for resources such as async Mutexes/leases/channels can be written;
- It is not required to support all patterns in one step, but at least allow async resources to be expressed under "mutable exclusive access" semantics.

Real files involved (examples; the codebase is authoritative):

- The parts of `sci/` responsible for borrow checking, symbols, and the type table;
- `sa_plugin_sla/src/lowering_rules.zig` (much of the dyn/`&mut`-related lowering is likely here);
- Any module responsible for the representation and code generation of `&mut` types in SA.

Acceptance conditions:

- A minimal async Mutex `lock`-style example compiles;
- Referee reports no UseAfterMove / DoubleFree / MemoryLeak.

#### 5.2.2 Correctness Repair for Generic Functions and Trait-Bound Generics

Goals:

- Fix the problem where generic free functions cause a MemoryLeak trap in the SAB backend;
- Fix the problem where trait-bound generics cause "Undefined call";
- Ensure that value types widely used in the backend, such as `Vec<T>`, iterator chains, and generic structs, work stably.

Real files involved:

- SA's generic instantiation, code generation, and type-table code;
- The generic-related paths of the flattener / LLVM-C backend / interpreter in `sci/`;
- The parts of `sa_plugin_sla` responsible for type checking and lowering.

Acceptance conditions:

- A minimal example of the form `serialize::to_json<T>(value: T)` compiles (even if currently simple in function);
- Generic functions do not cause MemoryLeak / Undefined call in real tasks.

#### 5.2.3 A Clean Path for JSON Lifetimes and Memory Management

Goals:

- Provide a way of using JSON DOM that does not conflict with managed lifetimes;
- Achieve a full "parse → read fields → release" flow without MemoryLeak or UseAfterMove;
- Lay the foundation for the later protocol-layer transformation.

Acceptance conditions:

- Write a small SLA program that parses JSON from a byte array, reads several fields, and releases correctly when done;
- No leaks and no dangling pointers under the real allocator.

---

## 6. Phase 2 — Async Runtime Rewrite (Polling Array → Waker-Driven Executor + Timers)

### 6.1 Current Situation (from the Real Code)

- The Executor in `sci/sa_std/core/task.sa` is still in the form of a **fixed array + sequential polling**:
  - `EXECUTOR_NEW` takes `tasks_ptr + len`
  - `EXECUTOR_POLL_ONE` fetches tasks by index and calls `TASK_POLL`
  - `EXECUTOR_RUN_UNTIL_COMPLETE` polls continuously until all tasks are ready
- The `block_on` implementation in `async_demo/src/main.sla` is also a one-shot synchronous poll, and simply calls `panic(93)` if not ready;
- Concurrency in the demo relies on **one thread per session**, not on event-loop driving.

This means the current SLA async still cannot support:

- Large numbers of suspended subscription waits;
- Timed retry backoff;
- Long-lived WebSocket idle waits;
- Lease renewal timers.

### 6.2 Specific SLA/SA Transformation Tasks for Phase 2

#### 6.2.1 Turning the Task Queue into a Dynamically Growable, Re-queueable Structure

Goals:

- Change the executor's internal task storage from a fixed array to a dynamic queue (first `Vec<Task>`, later consider higher-performance structures);
- Allow a task to remain in a "waiting set" after `poll` returns Pending, instead of being scanned sequentially on every round.

Acceptance conditions:

- With N sleeping tasks suspended on a single executor, CPU usage is no longer at the polling level;
- Completed tasks can be correctly removed.

#### 6.2.2 Actually Wiring Up the Waker Path

Goals:

- When `poll` returns Pending, the task records the waker in the corresponding waiting context;
- When an event/timer fires, `wake()` is called to put the task back into the runnable queue;
- The existing clone/wake/wake_by_ref/drop macros in `RawWakerVTable` are genuinely used by the runtime.

Real files involved:

- The existing VTable skeleton in `sci/sa_std/core/waker.sa`;
- The Context/Poll combinators in `sci/sa_std/core/future.sa`;
- The executor implementation (possibly in `sci/sa_std/core/task.sa` or a future new runtime module).

Acceptance conditions:

- A `sleep_ms`-style task does not busy-poll the CPU while waiting;
- A woken task resumes execution correctly.

#### 6.2.3 Integrating Timer Capability

Goals:

- Integrate basic timers into the executor, so that `sleep_ms`, `sleep_until`, timeout combinators, etc. work without blocking threads;
- Interface with waker wakeups: when a timer expires, re-queue the corresponding task.

Acceptance conditions:

- Hundreds or thousands of timed tasks run stably without unbounded memory growth;
- The timing error of timed wakeups is within an acceptable range.

#### 6.2.4 Compatibility Layer: Do Not Rip Out Existing Large Projects

Goals:

- Keep old macro interfaces such as `EXECUTOR_NEW / EXECUTOR_POLL_ONE` in `task.sa`, with the new queue used internally;
- Allow large synchronous projects such as `sla_ecs` to keep using their original concurrency model, without forcing a wholesale conversion to async.

Acceptance conditions:

- Large numbers of existing `sla_ecs` tests continue to pass;
- The async executor is an added capability, not a forced replacement.

---

## 7. Phase 3 — Cross-Platform Async Networking + Protocol/Serialization Layer + Concurrency Primitives

### 7.1 Background

Currently:

- Async networking on the SLA side is only provided on Linux via `sa_net_uring.zig` as an io_uring multi-reactor;
- On Windows there is only blocking Winsock;
- There is no IOCP/epoll/kqueue implementation anywhere in the repository;
- WebSocket frame reading in `sa_plugin_http_client/src/sa_std_net.zig` actually uses a **synchronous `stream.read` loop**;
- The serialization layer and concurrency primitives (mpsc, async locks, etc.) are also immature in SLA std.

For this backend, Windows is the primary runtime platform; outbound/inbound networking, WebSocket, reconnection, and full-duplex streaming messages all depend on async I/O. If this is not solved, the backend simply cannot be expressed in SLA on the target platform.

### 7.2 Specific SLA/SA Transformation Tasks for Phase 3

#### 7.2.1 Windows Async Networking Capability

Goals:

- Provide usable async TCP/WS I/O capability on Windows;
- It may be IOCP or some acceptable alternative async model, but it must not be purely blocking calls.

Acceptance conditions:

- An async echo server / client example runs on Windows;
- No thread is blocked as a whole by every individual read/write.

#### 7.2.2 Interfacing the Executor with the Network Reactor

Goals:

- Let I/O completion events produced by `sa_net_uring` (Linux) or a Windows async networking module wake waiting SLA tasks via wakers;
- Implement an abstraction with semantics similar to `AsyncRead/AsyncWrite`.

Real files involved:

- The reactor main loop and ticket event handling in `sci/src/runtime/sa_net_uring.zig`;
- The waker insertion/wakeup path on the executor side;
- The currently synchronous frame reading in `sa_plugin_http_client` should be gradually transformed into a form that can work with the async runtime.

Acceptance conditions:

- Waiting on socket reads/writes does not consume CPU;
- Concurrent I/O across multiple connections can be scheduled uniformly.

#### 7.2.3 Serialization/Deserialization Equivalents

Goals:

- Provide JSON encode/decode capability that can be used cleanly in SLA;
- Support at least JSON-RPC-style message construction and parsing;
- Handle the serialization needs of the backend's many metadata, configuration, and event structures.

Acceptance conditions:

- Nested JSON can be serialized/deserialized without lifetime conflicts or memory leaks;
- It can map to the backend's existing JSON-RPC message structures.

#### 7.2.4 Concurrency Primitives

Goals:

- Provide mpsc channels (or equivalents), async Mutex/RwLock, inter-task notification, etc.;
- Be able to express the combination of "waiting on a retry timer + event notification" in the subscription state machine.

Acceptance conditions:

- Small examples with concurrent communication can be written and operate correctly under the event-driven executor.

---

## 8. Phase 4 — Sandbox/Process Model + Validation of Backend-Migratable Units

### 8.1 Background

This backend is not only WebSocket and JSON; it also includes:

- Child process management (agy / Codex CLI / SSH / remote Bun, etc.);
- Cross-process and even cross-host thread routing, bridge lifecycles, and the semantics of closing a resource only on the final release;
- SQLite leases, process liveness detection, and reclamation of dead-process leases.

All of these require operating-system-level capabilities. SLA must either provide them itself or provide them through FFI/plugins plus the host runtime. The following choices are not an either/or, but a layering: **express control flow in SLA wherever possible, and rely on the host runtime's native capabilities where necessary**.

### 8.2 Specific SLA/SA Transformation/Integration Tasks for Phase 4

#### 8.2.1 Process Management and Lifecycle Abstraction

Goals:

- Provide an abstraction that can start child processes, read/write their stdio, wait for exit, and detect liveness;
- On Windows, be able to perform process liveness checks (semantics similar to `process.kill(pid, 0)`);
- Be able to express the lifecycle of the `AgyCompatibleProcessManager` kind: "start → send prompt → read event stream → write input → handle exceptions".

Involved approaches:

- If necessary, first wrap the host runtime's (Node/Bun) process capabilities into a boundary callable from SLA;
- In the long term, if SLA is to independently carry the backend, such capabilities need native or semi-native implementations.

Acceptance conditions:

- A child process can be started from SLA, sent a line of input, read structured output from, and have errors handled;
- Child-process liveness can be detected, and an unexpected process exit triggers the corresponding async task wakeup.

#### 8.2.2 Reference-Counted Resource Release Semantics

Goals:

- Express on the SLA side semantics similar to `SharedThreadBridgeRegistry`'s "only truly stop on the final release";
- As `&mut`/Drop gradually mature, be able to use the type system to guarantee release ordering and uniqueness.

Acceptance conditions:

- A bridge-registry example can be written that triggers a cleanup callback on the final release.

#### 8.2.3 Lease/Lock Conflict Model Validation

Goals:

- Be able to express in SLA a lease model with TTL, instance-conflict detection, and dead-process reclamation;
- If the SLA DB plugin does not yet have this capability, the host SQLite can be wrapped first, with gradual evolution later.

Acceptance conditions:

- The core semantics of `threadWriterLeaseStore.ts` can be reproduced:
  - Instance conflict / expiry override determination at acquire time
  - Timed renew
  - Dead-process lease reclamation

---

## 9. Phase 5 — Layered Backend Migration (Only After Prerequisite Phases Pass)

### 9.1 Migration Order Principles

Migration cannot be done in file-translation order; it must be done in order of **lifecycle complexity from low to high**:

1. The smallest units of pure computation / protocol encode-decode;
2. LLM API requests + SSE/WS streaming reads (but features such as retry/TLS/outbound async require Phase 3 to be completed first);
3. Services with relatively simple state, such as configuration / directories / model selection;
4. The highest-complexity modules — subscription registries, Writer leases, bridge lifecycles, remote thread routing — are migrated last.

### 9.2 Specific Strategy for Each Migration Block

- Do not switch the whole of `apps/server/src` to SLA in one shot;
- When migrating each module, first implement an equivalent **independently testable core state machine** in SLA;
- If underlying capabilities (executor, networking, serialization, process) are not yet fully mature, still provide boundary services through the host runtime, with SLA writing only the control flow and state;
- After a migration completes, run regression against the baseline examples left from Phase 0, to ensure subscription/lease/reconnect semantics have not degraded.

---

## 10. Key Acceptance Checklist for This Backend

During SLA/SA transformation, the following real backend behaviors should be used as acceptance criteria as early and as often as possible:

- **Subscription state machine**
  - `watch` invokes `ensureSubscribed`
  - `ensureSubscribed` calls `thread/resume` when a lease is obtained and the client is ready
  - On a writer conflict, mark `leaseBlocked` and stop retrying
  - On failure, retry with exponential backoff
  - `unwatch/removeTurnHold` triggers re-evaluation of whether to unsubscribe
  - `reAttachAll` re-establishes subscriptions when the client becomes ready again

- **Writer leases**
  - On-conflict upsert semantics of the SQLite table
  - Ownership at `instance_id` granularity
  - Renew/expiry determination based on `expires_at`
  - Reclaim leases left by dead processes at startup
  - Timed `renewAll`

- **Bridge lifecycle**
  - Do not `stop` prematurely when there are multiple references
  - The final release triggers `bridge.stop()` and `onLastRelease`

- **Cross-platform bridges and transient disconnections**
  - Startup, input, event parsing, and error handling for child processes / remote sessions
  - Reconnection and event replay on transient disconnections, without re-executing ambiguous writes

These behaviors are the hard metrics for determining whether "the SLA transformation has really reached the point where it can take on the backend".

---

## 11. Risks and Realistic Constraints

- SLA's async capability is currently more like state-machine compilation capability than a complete runtime; using it directly to write subscription/lease systems will get stuck on wakers, timers, and cross-platform I/O;
- `&mut` is closely tied to async RAII; delayed-release async locks/channels/leases all require mutable exclusive semantics;
- If JSON serialization cannot be used cleanly, the backend's message layer will be very fragile;
- The absence of async networking on Windows means a backend written in SLA effectively cannot be run on the local machine;
- The ownership/borrow model differs from Rust/TypeScript experience, and SLA's ownership system's behavior under real backend loads needs to be verified gradually through small milestones.

---

## 12. Summary

1. If this backend must be refactored in SLA, **the primary task is to transform SLA/SA itself**, not to translate TypeScript directly.
2. The order of transformation should be:  
   **language-side hard-defect repair (&mut/generics/JSON lifetimes) → async runtime rewrite (waker + timers) → cross-platform async networking + serialization + concurrency primitives → sandbox/process/lease abstractions → then layered backend migration**.
3. Every phase should use this backend's real lifecycle semantics (subscriptions, leases, bridge release, transient-disconnection recovery) as its acceptance baseline.
4. Until the first three phases are verified, core modules such as the subscription registry, Writer leases, and remote thread routing should not be migrated.
