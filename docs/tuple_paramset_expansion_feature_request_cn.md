# Tuple / ParamSet 展开能力 feature request

状态：需求待设计。下游 `sla_ecs` 在追齐 Bevy ECS `ParamSet` tuple parity 时，已经暴露出手写宽度展开不可持续：普通 `TableErasedWorld` 已写到 7 组 disjoint pair-mut query，relationship wrapper 也写到 7 组，observer wrapper 到 6 组。继续手写到 Bevy 当前上限 8 可以短期补洞，但会制造大量重复 SLA 源码和 SAB 编译压力；如果未来需要 16、32、100 组，同样模式会彻底失控。

本文只记录 SLA 编译器 / 语言层 feature request，不要求在 `sla_ecs` 继续堆手写展开，也不修改 SLA 编译器源码。

## 背景

Bevy ECS 由于 Rust 没有稳定 variadic generics，用宏枚举实现 `ParamSet` tuple：

```rust
// bevy/crates/bevy_ecs/src/system/system_param.rs
all_tuples_enumerated!(impl_param_set, 1, 8, P, p);
```

这代表 Bevy 官方 API 支持 `ParamSet<(P0, ..., P7)>`，但并不表示业务代码应该大量写 8 个系统参数。实际使用里 2 到 4 个更常见，8 是覆盖复杂系统的 API 上限。`sla_ecs` 为了对齐行为，当前只能显式手写：

- `TableErasedSevenPairMutParamSet<...>` struct
- `table_erased_*_seven_pair_mut_param_set(...)` 构造器
- `table_erased_run_seven_pair_mut_param_set_system(...)` runner
- `table_erased_run_seven_pair_mut_param_set_system_auto(...)` runner
- 普通 / relationship / observer 三套路由和测试

这些代码形状高度机械，业务信息很少，但会显著放大源码、SAB IR、cleanup/verifier 压力。之前 `sla_ecs` 还因为生成 `.test.sa` 文件累积到数百万行而拖慢仓库操作，已经改为禁止依赖 generated-SA 作为完成证据。

## 需求目标

需要一种 SLA 语言或编译器层能力，用声明式方式表达“对 tuple / 参数列表宽度 N 展开同一模板”，并让 SAB/default 后端直接处理这种结构，避免下游手写或持久化巨大生成源码。

核心目标：

- 支持基于索引的泛型 tuple / 参数列表展开，至少覆盖 Bevy 当前 `1..=8` 上限。
- 支持未来调高上限，例如 `1..=16`、`1..=32`，不需要下游复制粘贴业务代码。
- 展开产物应由编译器内部处理，不应要求下游提交或保留 `.test.sa` / 大型 generated-SA 文件。
- SAB 后端需要能在展开后保持函数指针、泛型实例、聚合字段 cleanup、move/drop 状态正确。
- 错误定位应能指回模板源位置和展开索引，而不是只给大型 `.sab` 行号。

## 建议语义

具体语法可以由编译器侧设计，但能力上建议覆盖以下模式。

### 1. tuple/参数组声明展开

期望可以表达“一个 ParamSet 包含 N 个 query 字段”：

```sla
@expand_tuple_width(1, 8, P, p)
struct ParamSet<P...> {
    @for_each_index(i in P)
    p{i}: Query<P{i}>,
}
```

等价于手写：

```sla
struct ParamSet2<P0, P1> {
    p0: Query<P0>,
    p1: Query<P1>,
}

struct ParamSet3<P0, P1, P2> {
    p0: Query<P0>,
    p1: Query<P1>,
    p2: Query<P2>,
}
```

这里的语法只是示意，重点是编译器要理解“宽度参数”和“按索引生成字段/泛型/实参”。

### 2. 构造器展开

期望可以表达构造器按字段回填：

```sla
@expand_tuple_width(1, 8, P, p)
fn param_set<P...>(@for_each_index(i in P) p{i}: Query<P{i}>) -> ParamSet<P...> {
    return ParamSet<P...> {
        @for_each_index(i in P) p{i}: p{i},
    };
}
```

### 3. runner 展开

`sla_ecs` 当前最痛的是 runner 的重复 query 构造和 writeback。需要能表达：

```sla
@expand_tuple_width(1, 8, Pair, pair)
fn run_pair_mut_param_set<Pair...>(world: World, run: fn(ParamSet<Pair...>) -> ParamSet<Pair...>) -> World {
    @for_each_index(i in Pair)
    let q{i} = world_query_pair_mut<Pair{i}.A, Pair{i}.B>(world, pair{i}.first_type_id, pair{i}.second_type_id);

    let p0 = param_set<Pair...>(@for_each_index(i in Pair) q{i});
    let p1 = run(p0);

    @fold(world as w, i in Pair)
    w = apply_pair_mut_updates<Pair{i}.A, Pair{i}.B>(w, p1.q{i});

    return w;
}
```

这类写法需要编译器支持：

- 展开 `let` 局部变量。
- 展开函数形参和泛型实参。
- 展开 struct literal 字段。
- 展开顺序 fold，确保 writeback 顺序稳定。

## 最小下游示例

下面是一个可以作为最小编译器测试的 SLA 风格示例，避免依赖完整 `sla_ecs`：

```sla
struct Query<T> { value: T }

struct Pos { x: i32 }
struct Vel { x: i32 }
struct Marker { value: i32 }

@expand_tuple_width(1, 3, P, p)
struct ParamSet<P...> {
    @for_each_index(i in P)
    p{i}: Query<P{i}>,
}

@expand_tuple_width(1, 3, P, p)
fn param_set<P...>(@for_each_index(i in P) p{i}: Query<P{i}>) -> ParamSet<P...> {
    return ParamSet<P...> { @for_each_index(i in P) p{i}: p{i} };
}

fn use_two(param: ParamSet<Pos, Vel>) -> ParamSet<Pos, Vel> {
    param.p0.value.x = param.p0.value.x + 1;
    param.p1.value.x = param.p1.value.x + 2;
    return param_set<Pos, Vel>(param.p0, param.p1);
}

@test "expanded tuple param set width two"() {
    let p = param_set<Pos, Vel>(Query<Pos> { value: Pos { x: 10 } }, Query<Vel> { value: Vel { x: 20 } });
    let r = use_two(p);
    if r.p0.value.x != 11 { panic(91001); };
    if r.p1.value.x != 22 { panic(91002); };
}
```

## 单元测试建议

编译器侧建议至少增加以下测试，全部优先用默认/SAB 后端验证，不使用 generated-SA 作为完成依据。

### 测试 1：宽度 1/2/3 生成 struct 与构造器

目标：证明泛型参数、字段、构造器实参、struct literal 字段都能按宽度展开。

断言：

- `ParamSet<Pos>` 可访问 `p0`。
- `ParamSet<Pos, Vel>` 可访问 `p0`、`p1`。
- `ParamSet<Pos, Vel, Marker>` 可访问 `p0`、`p1`、`p2`。

### 测试 2：展开函数指针参数

目标：证明展开出来的 `ParamSet<P...>` 可以作为函数指针入参和返回值。

示例：

```sla
fn run_param_set<P...>(param: ParamSet<P...>, run: fn(ParamSet<P...>) -> ParamSet<P...>) -> ParamSet<P...> {
    return run(param);
}
```

断言：传入 `fn use_two(ParamSet<Pos, Vel>) -> ParamSet<Pos, Vel>` 后，SAB call target 正确，cleanup 不泄漏。

### 测试 3：顺序 fold writeback

目标：证明展开代码中的顺序写回稳定，不能被并发或优化重排。

示例：

```sla
@for_each_index(i in P)
state = write_slot(state, i, param.p{i}.value);
```

断言：写回日志顺序为 `0, 1, 2, ...`。

### 测试 4：错误定位包含展开索引

目标：展开模板内部类型错误时，诊断能指向模板源码和具体展开索引。

示例：在 `p{i}.missing_field` 上制造错误。

期望错误包含：

- 模板源文件行列。
- 展开宽度。
- 当前 `i` 值。

### 测试 5：上限压力测试不落盘 generated-SA

目标：宽度 8 和宽度 16 的展开可以通过 SAB/default 编译测试，不生成或要求提交 `.test.sa`。

断言：

- `sa sla test tests/test_tuple_expansion.sla --trace-panic` 通过。
- 测试后仓库内没有新增 tracked 或落盘依赖的 `*.test.sa`。

## `sla_ecs` 验收场景

该 feature 完成后，`sla_ecs` 应能把当前手写的：

- `TableErasedTwoPairMutParamSet` 到 `TableErasedSevenPairMutParamSet`
- `TableErasedRelationshipTwoPairMutParamSet` 到 `TableErasedRelationshipSevenPairMutParamSet`
- `TableErasedObserverTwoPairMutParamSet` 到 `TableErasedObserverSixPairMutParamSet`

逐步替换为单一模板或少量模板声明，并扩到 Bevy 当前 limit 8。验收命令优先使用默认/SAB 多线程：

```bash
cd /home/vscode/projects/sla_ecs
timeout 240s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased_relationship.sla --trace-panic
timeout 240s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased_observer.sla --trace-panic
```

普通 `lib/system_param_table_erased.sla` 当前还有独立 SAB cleanup issue 记录在 `docs/sab_system_param_removed_components_memoryleak_issue_cn.md`；tuple expansion feature 不应掩盖该 cleanup 问题，但也不应让展开能力依赖 generated-SA 路径。

## 非目标

- 不要求一开始实现任意无限 variadic generics。
- 不要求业务代码真的使用 100 个 system params。
- 不要求改变 Bevy parity 的 API 上限判断；下游可以继续以 Bevy 当前 `1..=8` 为目标。
- 不要求 SLA 编译器直接理解 ECS 语义；这里只需要泛型 tuple/参数列表展开机制。

## 优先级建议

优先级：高。

理由：继续在 `sla_ecs` 手写 tuple limit 8 属于低价值重复劳动，会增加 SAB 编译压力和维护成本。语言/编译器层有了声明式展开能力后，ECS、query data、system params、tuple filters、AnyOf、bundle tuple、schedule tuple 等重复结构都可以复用同一机制。
