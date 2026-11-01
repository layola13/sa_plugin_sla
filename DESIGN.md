# DEF 深 drop 批 — 设计注记

基点：sci main `8979c4e1`（本机 staging 实取二盒 rig 的 `1d93041a`，与 8979c4e1 的
已知差异仅 `src/emit_c.zig` 的 task-form 机器段——集成交付记录载明该提交 diff
仅 emit_c.zig +979/−5；本批不动该段）、sla master `d470dff0`（staging 与二盒
rig 树 md5 互核一致）。
证据：`~/workspace/slaredis-triage/TRIAGE.md`（缺陷 A）+ 本批基线实测（下表）。
与既有工作的关系：本批即 R8-FIX 报告 §8.2「深 drop 覆盖族」的修复线
（`~/workspace/def-r8fix-local/REPORT.md` §8.2），由分诊的产品级证据
（SET 1 KiB ≈91.9 KB/op 留存、GET 256 KiB 6.32 MB/op、OOM）升级立项。

## 1. 基线实测（二盒 rig，`sa build-exe` 宿主路线，300 轮）

| 探针 | 形状 | 峰值 RSS | 判读 |
|---|---|---|---|
| probe_a | 局部 Vec\<u8\> 克隆后 drop | 1,832 kB | 平台化——浅 drop 在此路线已工作（VEC_FREE 已发射且 @sa_vec_free→libc free 生效） |
| probe_b | Vec\<Vec\<u8\>\> 整体 drop | 4,943,308 kB | 漏：只发一条浅 VEC_FREE（外层），元素缓冲全漏 |
| probe_c | 堆结构体字段重赋值 `(*h).buf = clone` | 4,939,740 kB | 漏：store 前不释放旧字段值（与分诊 4,939,796 kB 吻合至 0.1%） |

未决差异（登记，不阻塞）：分诊在一盒（sci 8979c4e1）测 probe_a 峰值
2,472,444 kB，与本表不符。可能源：构建路线不同（SAB 直通在二盒 rig 上对
probe_a 报 UnsupportedSabDirectFeature，分诊路线未载明）或 sci 版本差。
待一盒空窗或取得 8979c4e1 树后复核；B/C 两形状在两 rig 数字同量级互证，
不影响本批修复面。

C 路线（`sa build-c`）由代码坐实全漏：emit_c 前导 `sa_alloc` 为 bump、
`sa_free` 为空操作（见 §3），与发射层是否发 free 无关。

## 2. 根因分层（四层，逐层处置）

1. **SLA 发射·浅 drop**：Vec/String 的作用域清理只发 `VEC_FREE`
   （=@sa_vec_free，只释放元素缓冲区 + Vec 结构体本身），元素若为 owned
   类型（Vec/String/含 owned 字段的结构体）从不逐个 drop。结构体值清理
   同理只释放结构体寄存器，owned 字段从不 drop。（§8.2 本体）
2. **SLA 发射·重赋值不释放**：字段/下标/整变量重赋值在 store/rebind 前
   不 drop 旧值——`x = Vec::new()` 复位惯用法（slaredis 全部复位点）每轮
   漏掉旧缓冲全量。
3. **sci C 发射器分配器**：`sa_alloc` bump + `sa_free` 空操作，已释放块
   永不复用；C 路线下第 1/2 层的 free 发射全部落空。
4. **原生 LLVM 路线分配器**：`alloc`→libc malloc、`sa_mem_free`→libc
   free（`src/runtime/sa_std.zig` 的 `sa_mem_free` 注释明载），发射到位
   即复用——本批 sci 侧不动此面，修复后以探针复证。
   解释器（`sa run`）为真释放语义（R8-FIX §3），修复后复证登记。
   **wasm 发射未查证**——列未覆盖面，修复后须实测登记，不许默认同理。

## 3. sci 侧设计：C 前导分配器复用（emit_c.zig 的 sa_alloc/sa_free）

现状布局：每块前置 8 字节头，头内低 4 字节存块尺寸（已对齐、含头外净荷
尺寸口径见现行 `sa_alloc` 实现），`sa_free` 空操作。
改法（保持布局与语义不变式）：
- 头改为 {size: u32, magic: u32}；magic 取固定常量标记「活块」，free 时
  改写为「空闲」标记并把块链入侵入式空闲链表（链表 next 存块净荷首 8
  字节，块最小净荷 8 字节由现行对齐保证）。
- `sa_alloc`：先查空闲链表 first-fit，命中且剩余 ≥ 32 字节时切分；
  命中块按现行语义整块清零（现行实现对新块逐字节清零，复用块保持同一
  保证）；未命中走 bump（原路径不动）。
- `sa_free`：校验指针落在 bump 区内且头 magic 为活块标记才入链，否则
  静默忽略（静态区/外部指针防御，与现行空操作的宽容性一致）。
- 不做合并（coalescing）：v1 已知限制，登记。负载以同尺寸反复分配为主
  （探针/服务器缓冲），first-fit 同尺寸命中即 O(1) 链头附近命中。
- 影响面：emit_c 前导文本变化 ⇒ 所有 build-c 产物字节变化（预期内）；
  GPU 提取器消费同一 C 发射，sa_alloc 的对外语义（清零、对齐、尺寸头
  位置）逐项保持，task-form 自有内存协议不经 sa_free（其协议内无 free
  调用——实现时以 grep 复核）。GPU 盒（四盒）恢复后须冒烟复证，列待办。

## 4. SLA 侧设计：深 drop 发射（codegen.zig + sab_codegen.zig 双路同形）

### 4.1 判定（lowering_rules 共享计划）
新增 `planValueDrop(ty) -> DropPlan`，两 codegen 共用：
- `.none`：Copy 标量、借用、裸指针等——维持现状。
- `.buffer`：Vec\<T\>/String 且 T 为 .none——维持现状（VEC_FREE）。
- `.deep`：Vec\<T\> 且 plan(T)=.buffer/.deep；结构体且至少一字段 plan≠.none；
  枚举 payload 含 owned（本批只登记 match 提取绑定一形，见 §5）。
DropPlan 为递归描述（元素 plan / 字段 plan 列表），发射器据此展开。

### 4.2 发射形（内联展开，不新增 std 函数）
- Vec 深 drop（文本路）：在既有 VEC_FREE 之前插入元素循环——
  `len=load v+Vec_len`、`buf=load v+Vec_ptr`、i 循环逐元素按元素 plan
  释放：元素为指针形 owned（Vec/String/堆结构体指针）时 `elem=load
  buf+i*8 as ptr` 后递归；元素为值形结构体时元素地址 `buf+i*elem_size`
  处就地字段 drop（不释放元素存储）。标签/临时名用 codegen 既有计数器
  保证唯一。SAB 路以同一计划在其指令发射面同形展开（其既有
  `emitOwnedBufferFree` 泛化为 `emitDeepDrop(reg, plan)`）。
- 结构体深 drop：按声明序逐 owned 字段 load 后递归 drop；结构体自身
  存储的释放仍归既有路径（栈槽/堆指针由现有 release 处置），本层只补
  字段——避免与既有所有权记账双重释放。
- String：与 Vec\<u8\> 同表示（STRING_BUF_FREE≡VEC_FREE），plan=.buffer。

### 4.3 重赋值释放（probe_c + 复位惯用法）
在赋值发射点（文本路 genAssign 对应段 / SAB 路 genAssign），当目标
place 的 plan≠.none 时，在求值 RHS **之后**、store/rebind **之前**，
对目标 place 的旧值发射 drop（深度按 §4.5 的污染状态决定）。由检查器
标注驱动（§4.5），发射层不自行推断活性：
- 字段/下标赋值：检查器已强制根符号非 uninitialized（UseBeforeInit，
  type_checker.zig assign 段），即目标字段必有已初始化旧值；
- 整变量赋值：检查器在 assign 处理点记录标注时的符号状态——
  `.consumed` 的绑定（REG-BR-6 允许移出后重赋值）**不标注**，旧值已
  不存在，drop 即双重释放；
- RHS 与目标为同一 place（`x = x` 形，检查器已有同名特判）不标注。

### 4.5 污染（taint）分析——深 drop 的安全性前提（实证后增补）
前置探针实证（rig 上 `sa sla check` 全过）：SLA 允许 owned 字段/元素
的**按值读出且不消费原 place**——`let v = h.buf; h.buf = …`（P1）、
`let v = outer[0]; outer[0] = …`（P3）、移出后重读（P4）、同下标
重复移出（P5）均合法；发射形为指针浅拷贝、槽位不清零（别名语义）。
故朴素深 drop 会对已别名读出的元素/字段双重释放。本批对策 = 检查器
污染分析（保守、只过度抑制、永不漏标）：
- **污染事件**：place 链（字段/下标投影，根为标识符）的最终值以
  owned 非 Copy 类型被**按值消费**（let 初始化、按值实参、return、
  结构体/枚举字面量字段、赋值 RHS、二元运算数、闭包捕获等消费性
  父节点）。中间投影（`outer[2][7]` 的 `outer[2]`）、借用位置
  （`&place`、方法 receiver、len 等借用内置）不污染。
- **污染键**：绑定名（Vec/叶子 owned 绑定）与 `根名.字段.子字段`
  （字段 place）；名字键控与既有 cleanups 机制同纪律——同名不同
  绑定只会过度抑制（漏释放，安全方向），不会漏标。
- **drop 决策（清理点与重赋值点共用）**：
  - 未污染 owned place → 深 drop；
  - 已污染的叶子缓冲（String / Vec\<标量\>）→ **不 drop**（别名持有
    唯一缓冲，别名自己的清理负责释放）；
  - 已污染的 Vec\<owned 元素\> → 只浅 VEC_FREE（释放指针缓冲+结构体，
    不碰元素；已读出元素归别名，未读出元素随之漏——正确性优先，
    该形罕见且漏量有界于已读出个数之外的元素，登记为已知保守面）；
  - 已污染的结构体 → 逐字段递归套用本决策。
- 赋值成功后清除该 place 的污染（新值独占）；整绑定被移动/消费时
  污染随绑定消亡（清理点本就不发射）。
- 实现：type_checker 新增 `tainted_places` 集合 + `assign_drop_old`
  节点标注集，检查函数体时按上表填充；两 codegen 在 drop 发射点查
  询。此分析同时是 §4.2 深 drop 的启用条件——无标注支持的形状一律
  维持现状浅 drop，不许先上深 drop 再补标注。

### 4.4 与所有权记账的衔接
深 drop 只加在既有清理/释放决策点上（emitRelease 的 vec/string 分支、
releaseLocalsFrom/emitCleanupLocalDrop、赋值点），且沿用既有
consumed/released 登记（released_regs / consumed_bindings）防重复发射；
被移动走的值仍由既有 consumed 标记跳过——R8-FIX 的转移误标修复
（release-on-move 族）语义不回退：本批只给「确认为仍 owned」的值补
深层释放，不新造释放点决策。

## 5. 范围与分期

- **最小片（先行）**：§3 分配器复用 + §4.3 字段/整变量重赋值释放
  （plan=.buffer/.deep 均从）+ Vec\<Vec\<u8\>\> 深 drop（§4.2 元素为
  .buffer 的情形）。验收：探针 A/B/C 三件在 exe 与 c 两路 RSS 平台化。
- **扩展片**：结构体字段深 drop（§8.2 probe_struct_field 形）、
  Vec\<String\>、Vec\<结构体\>、嵌套三层 Vec、结构体含 Vec 字段的
  Vec 元素。
- **登记不并入**：match 提取绑定的 drop 发射（§8.2，发射点在 match 臂
  绑定处，独立形）、Rc/Arc 单元内 payload 深 drop（§8.2，依赖 Rc 单元
  布局与计数语义）、§8.3 按值聚合参数的清理、§8.1 溯源残族（另一族，
  需所有权溯源标记设计裁定，不在本批）。

## 6. 验收（四联）
1. 探针 A/B：修复前（二盒 pristine rig）RSS 爆涨 vs 修复后平台化，
   同轮同 rig 对照数字入终报；基线树（独立 pristine 副本）复证修复前
   失败——语料回归同口径。
2. 语料回归随修复提交：plugin_tests.zig 发射形断言（深 drop 序列在/
   不在）+ tests/ 值正确性用例（drop 后复用、重赋值后读新值、嵌套
   drop 后程序结果不变）；新用例须在修复前代码上失败（发射形断言
   天然满足；值用例以 RSS 探针为行为证据链）。
3. 既有套件失败名字集与基线逐一对照不新增：sla batched（规范口径：
   仓根 cwd、清 .sla-cache、SLA_NO_FRESHNESS_CACHE=1、
   SA_SLA_FIXTURE_DIR、SA_PLUGIN_DEV=1）+ sci sa-std-unit + sci C 发射
   相关测试集。
4. 改插件后重编重装 + 同轮 md5 双确认（built==installed）；sci 改
   sa_std 面时先 `zig build sa-std-static` + nm 核对（本批预期不新
   extern——sa_mem_free 已存在，不触发此条，终报注明）。

## 7. 落地附记（2026-11-02 完工，本机 rig；本地提交、未推送）

- **§1/§2 分层修正（实证推翻）**：probe_a 的 ≈8.24 MB/轮保留不在
  「原生构建不发 free + bump 不复用」层——本地隔离定位到
  `sa_std/alloc/vec.sa` 的 `@sa_vec_push` 扩容路径（与
  `@sa_vec_shrink_to` L_ZERO）漏 free 旧缓冲（sci `8b934a3` 修复，
  interposer 实验同时证明 alloc/@sa_mem_free 配对本身健全）。
  §1 的 box2 平台读数自此作废，以本机复测为准。
- **§3 增补（设计外三件，均为 C 路线实证所迫）**：① `@sa_mem_free`
  extern 绑定此前缺失（落 trapping stub，C 路线任何 free 不可跑）；
  ② v1 的 first-fit+切分会把唯一 1 MiB 块逐轮切碎致 bump OOM，
  改 best-fit + sa_free 相邻合并；③ 真 sa_free 使 emit_c 无条件
  `.release → sa_free` 的翻译开始误放活缓冲，加来源门
  （provCUpdate，镜像 interp 语义与 emit_js 既有门控）。emit_js 的
  `__sa_free` 经查为带 slab 回收的真 free + 同款来源门，无同病；
  interp 的 `.release` 按寄存器值标志（borrow/interior/const/
  stack）判免，语义基准在 sci `interp.zig`。
- **§4 落地形态**：检查器 `planValueDrop`（备忘录化、递归截断浅层）+
  `assign_drop_old` 标注 + §4.5 place-taint 通过（字段位串键、快照在
  cleanup/phi_cleanup 与标注赋值点）；双 codegen 同形发射（文本路
  `codegen.zig`、SAB 路 `sab_codegen.zig`）：Vec 元素栈槽索引循环、
  结构体字段就地 drop、重赋值旧值 drop（标识符/deref/字段/数组
  索引四路；SAB 路 Vec 索引赋值未并入）。污染查询含
  `dropTaintCoversAt`（精确/下位覆盖，祖先污染刻意不计）。
- **验收数字（原生路线，修复前→修复后峰值 RSS）**：probe_b120
  992,256 → 16,472 kB，b300 16,572 kB exit 0；probe_c120
  1,001,832 → 39,060 kB，c300 39,124 kB exit 0；probe_a300
  30,692 kB exit 0（vec 修复后平台）。C 路线：probe_d300 exit 0、
  probe_a300 exit 0（38,092 kB），B/C 缩放版 S/E 完整（harness 覆写
  SA_GAS_LIMIT=4e10、SA_MEM_BYTES=256 MiB）。
- **语料**：tests/ 三件（vec_nested / struct_field_reassign /
  vec_reassign）双后端全过——定位为腐化守卫（泄漏在功能尺度不可
  见，基线同样通过，如实登记）；泄漏门 = plugin_tests 发射断言
  （`sla deep drop emits element and field drops in sa codegen`，
  数 EXPAND VEC_FREE：嵌套 ≥2、字段重赋值 ≥2），在独立基线树
  （721e248）上单独失败、修复后通过，满足修复前失败纪律。
  注：`Box::new` 形态的字段重赋值不走深 drop（0 处），已证形态为
  probe_c 的 `Box::into_raw`——Box<T> 绑定字段 place 的旧值释放
  登记为未覆盖面。
- **套件对照**：sla batched 360/0 全绿；plugin zig 套件 335/338，
  失败集 {3 个 import-scan} 与基线树（334/337）逐一相同、为既存；
  sci 套件裁决见 sci 仓 STATUS.md（失败全部既存/环境类）。
  进程内 SAB test-input 路对本批形态有既存直降缺口
  （UnsupportedSabDirectFeature，落在方法调用表达式语句、嵌套索引
  cast 等无关构造上，与 import-scan 失败同族）——SAB 验证由 CLI
  路线 `sa sla test --test-backend sab` 承担且全过。
- **缓存教训（本批实证）**：宿主 `.sa_cache` 按源码哈希供旧产物、
  不随插件版本失效——探针/测试构建前必须清 `.sla-cache` 与
  `.sa_cache` 并设 SLA_NO_FRESHNESS_CACHE=1，否则会测到旧二进制
  （本批曾因此误读一次 989,040 kB 平台值，已作废重测）。
- **未覆盖面（如实登记）**：SAB 分支清理路（emitBranchCleanupForNode
  只发裸 release，连普通 Vec 缓冲亦然——既存浅层缺口）、文本路
  stack_alloc 绑定深字段、bindingStorageAddress 赋值路、SAB 路
  Vec 索引赋值旧值释放、Box<T> 绑定字段重赋值、match 提取绑定
  drop、Rc/Arc payload、§8.3 按值聚合参数清理（§5 原登记项不
  变）；sa_std 其余 grow 路径审计（vec.sa 之外）为后续登记项；
  emit_c 的 `sa_install_sigpipe_ignore` 独立链接缺定义为既存
  缺口（c-matrix 基线同败），另行登记 DEF。
