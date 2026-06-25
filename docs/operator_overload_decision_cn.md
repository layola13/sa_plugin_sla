# Sla 操作符重载设计决策

> **文档版本**：v0.1-草案 / 2026-06-15
> **状态**：能力评估 + 设计决议 + `@overload` 已落地（旧版占位分析已过期）
> **决议建议**：`@derive(Add/Sub/Mul/Neg/PartialEq/Eq/Hash/PartialOrd/Ord)` 负责自动派生，`@overload` 负责显式手写重载；两者可以共存，但 `@overload` 具有更高优先级
> **关联文档**：
> - [`macro_vs_rust_cn.md`](./macro_vs_rust_cn.md) `@derive` 编译器内建注解路线
> - [`mutability_decision_cn.md`](./mutability_decision_cn.md) Phase 1/2 时序
> - 4 个占位 demo：
>   - [`demos/rosetta/301_operator_overload_add/`](../demos/rosetta/301_operator_overload_add/)
>   - [`demos/rosetta/302_operator_overload_neg/`](../demos/rosetta/302_operator_overload_neg/)
>   - [`demos/rosetta/303_operator_overload_scalar_mul/`](../demos/rosetta/303_operator_overload_scalar_mul/)
>   - [`demos/rosetta/304_operator_overload_eq/`](../demos/rosetta/304_operator_overload_eq/)

---

## 1. 现状实测

### 1.1 当前实现状态

`src/type_checker.zig:1115-1138` 实测：

```zig
.binary_expr => |bin| {
    const l_ty = try self.checkExpr(bin.left, scope);
    const r_ty = try self.checkExpr(bin.right, scope);
    if (!self.typesEqual(l_ty, r_ty)) {
        return TypeError.TypeMismatch;
    }
    const ty = try self.allocator.create(ast.Type);
    switch (bin.op) {
        .add, .sub, .mul, .div, .mod => {
            if (!isNumericType(l_ty)) {
                return TypeError.TypeMismatch;   // ← 任何非数值类型直接报错
            }
            ty.* = l_ty.*;
        },
        .eq, .ne, .lt, .le, .gt, .ge => {
            ty.* = .{ .primitive = .boolean };    // ← 仅原生数值比较
        },
        ...
    }
},
```

**当前实现已支持 `@overload` 形式的 `+ - * /` 静态分发。**

这意味着 `vec1 + vec2`、`-vec`、`a * scalar` 这一类表达式，若被放在 `@overload` 块声明的目标类型上下文里，会在前端重写为静态函数调用并继续通过；裸写的 `overload` 仍然是编译错误。

`a == b` 这类比较是否走重载，仍由当前白名单和类型系统约束决定，不在这个 `@overload` 机制内自动开放。

### 1.2 现状对 rosetta 200+ demos 的影响

实测 grep 结果：
- `impl Add` / `trait Add` / `std::ops` 等关键字在 rosetta demos / tests / sa_std 中**返回 0 匹配**
- 301 个 rosetta demo **无任何操作符重载示例**

**用户当前仍可写命名函数；在需要更接近数学表达式时，也可以使用 `@overload`：**
```sla
let c = vec3_add(&a, &b);          // 替代 a + b
let n = vec3_neg(&v);              // 替代 -v
let scaled = vec3_mul_scalar(&v, 2.0);  // 替代 v * 2.0
let same = point_eq(&a, &b);       // 替代 a == b
```

### 1.3 痛点量化（基于 sa3d math 库估算）

如果 sa3d 全用命名函数：

| 表达式 | 命名函数版 | 字符增量 |
|--------|----------|---------|
| `v + dt * a` | `vec3_add(&v, &vec3_mul_scalar(&a, dt))` | +180% |
| `pos = pos + vel * dt + accel * 0.5 * dt * dt` | 4 层嵌套 `vec3_add/mul_scalar` | +300% |
| `n.dot(r) > 0.0` | `vec3_dot(&n, &r) > 0.0` | +30% |
| `if a == b` | `if point_eq(&a, &b)` | +40% |

**sa3d math 代码总体冗余度 +50-80%**。这就是为什么 Bevy / glam / nalgebra 全部用操作符重载——可读性是数学库的命脉。

---

## 2. 三种实现路径

### Option A：永久不引入

- ✅ SA "显式优于隐式" 哲学一致
- ✅ 零实施成本
- ❌ sa3d math 库可读性灾难
- ❌ Bevy 代码移植困难（每处 `a + b` 都要改 `Vec3::add(a, b)`）
- ❌ LLM 训练分布是 `a + b`，生成 `vec3_add(&a, &b)` 倾向低

**适用**：sla 永远不做 sa3d / Bevy 风路线（与现有规划冲突）。

### Option B：编译器内建 `@derive` 系列（推荐）

让用户标注：

```sla
@derive(Add, Sub, Mul, Neg, PartialEq)
struct Vec3 { x: f32, y: f32, z: f32 }
```

Sla 编译器扫到 `@derive(Add)` → 自动生成：

```sla
// 自动生成（用户不写）
impl Add for Vec3 {
    fn add(self: Vec3, other: Vec3) -> Vec3 {
        return Vec3 {
            x: self.x + other.x,
            y: self.y + other.y,
            z: self.z + other.z
        };
    }
}
```

Type checker 在 `binary_expr` 遇到非数值时**回退查 trait impl**，找到 `Add` 实现 → 改写为 `Vec3_add(&a, &b)` 调用。

**支持的 `@derive` 白名单**（v0.1 建议）：

| derive | 生成内容 | 适用场景 |
|--------|---------|---------|
| `@derive(Add)` | `impl Add for T`，同类型字段相加 | Vec / Matrix / Quat |
| `@derive(Sub)` | `impl Sub for T`，同类型字段相减 | 同上 |
| `@derive(Mul)` | `impl Mul for T`，同类型字段相乘（**元素乘**，非点积） | Vec 元素乘 |
| `@derive(Div)` | `impl Div for T` | 数学库 |
| `@derive(Neg)` | `impl Neg for T`，一元负 | Vec / Quat 反向 |
| `@derive(MulScalar)` | `impl Mul<f32>` + `impl Mul<Self> for f32` 双向 | Vec * scalar |
| `@derive(PartialEq)` | `impl PartialEq for T`，字段逐一比较 | 测试 / 集合查找 |
| `@derive(Eq)` | 标记可作 HashMap key | HashMap |
| `@derive(Hash)` | `impl Hash for T` | HashMap |
| `@derive(PartialOrd)` / `@derive(Ord)` | `impl PartialOrd/Ord for T`，字段字典序 | 排序 |

**Option B 优势**：
- ✅ 与现有 `@derive(Component/Bundle/Resource/Event)` 系列一致
- ✅ 工程量小（每个 derive ~2-3 天，10 个 derive ~ 1 个月）
- ✅ 用户体验等价 Rust
- ✅ 覆盖 sa3d math / ECS / 业务比较 99% 需求
- ✅ 不引入 trait 系统的复杂性（关联类型 / 参数化 trait）

### Option C：完整 operator trait 系统

让用户写完整 trait impl：

```sla
impl Add for Vec3 {
    type Output = Vec3;
    fn add(self, other: Vec3) -> Vec3 { ... }
}

impl Mul<f32> for Vec3 {
    type Output = Vec3;
    fn mul(self, s: f32) -> Vec3 { ... }
}
```

- ✅ 与 Rust 100% 形态一致
- ❌ 需要 sla trait 系统支持关联类型（`type Output`）
- ❌ 需要 sla trait 系统支持参数化（`Mul<f32>` vs `Mul<Vec3>`）
- ❌ 工程量大（~2-3 个月）
- ❌ 与 sla 极简哲学冲突
- ⚠️ 用户体验与 Option B 几乎相同

**不推荐**——Option B 已覆盖所有实际需求，且工程量小一个数量级。

---

## 3. 推荐：Option B 三阶段落地

### Stage 1（必做，1 周）

最小 4 个 derive，覆盖 sa3d math 与基础业务：

| derive | 周数 | 说明 |
|--------|------|------|
| `@derive(Add)` | 2 天 | 最常用 |
| `@derive(Sub)` | 1 天 | 与 Add 对称 |
| `@derive(Neg)` | 1 天 | 简单 |
| `@derive(PartialEq)` | 2 天 | 测试 + 业务必需 |

**完成后**：301、302、304 三个占位 demo 替换为真实实现。

### Stage 2（推荐，1 周）

补齐 math + HashMap 需求：

| derive | 周数 | 说明 |
|--------|------|------|
| `@derive(MulScalar)` | 3 天 | sa3d 关键 |
| `@derive(Mul)` | 1 天 | 元素乘 |
| `@derive(Div)` | 1 天 | 数学库 |
| `@derive(Eq)` + `@derive(Hash)` | 2 天 | HashMap key |

**完成后**：303 占位 demo 替换为真实实现。

### Stage 3（视需求，1 周）

排序相关：

| derive | 周数 |
|--------|------|
| `@derive(PartialOrd)` | 2 天 |
| `@derive(Ord)` | 2 天 |

**总计 3 周一人完成全套 10 个 derive**。

---

## 4. 编译器实现要点

### 4.1 Parser 改动

识别 `@derive(Trait1, Trait2, ...)` 注解：

```
@derive(Add, Sub, Mul, Neg, PartialEq)
struct Vec3 { x: f32, y: f32, z: f32 }
```

挂在 `StructDecl.derives: []TraitName` 字段。

### 4.2 AST 改写

每个 derive 触发对应的 impl 块生成（在 type check 之前）：

```
@derive(Add) on struct Vec3 with fields { x: f32, y: f32, z: f32 }
   ↓ 改写阶段
impl Add for Vec3 {
    fn add(self: Vec3, other: Vec3) -> Vec3 {
        return Vec3 {
            x: self.x + other.x,
            y: self.y + other.y,
            z: self.z + other.z
        };
    }
}
```

### 4.3 Type checker 改动（最关键）

`binary_expr` 当前路径（`src/type_checker.zig:1115-1138`）：

```zig
.add, .sub, .mul, .div, .mod => {
    if (!isNumericType(l_ty)) {
        return TypeError.TypeMismatch;   // ← 当前路径
    }
    ty.* = l_ty.*;
}
```

新路径：

```zig
.add, .sub, .mul, .div, .mod => {
    if (isNumericType(l_ty)) {
        ty.* = l_ty.*;                   // 原数值路径
    } else if (lookupTraitImpl(l_ty, "Add")) |impl_| {
        // 改写 binary_expr 为 call_expr
        rewriteToTraitCall(bin, impl_);
        ty.* = impl_.output_type;
    } else {
        return TypeError.TypeMismatch;   // 没 Add impl 才报错
    }
}
```

### 4.4 Codegen 改动

无需额外改动——AST 已在 type checker 阶段被改写为 `call_expr`，走现有 call 路径。

### 4.5 错误信息

```
error[SLA-OP-001]: cannot apply `+` to type `Vec3`.
  Hint: add `@derive(Add)` to the struct definition, or use `vec3_add(&a, &b)`.
  --> example.sla:42:15
```

---

## 5. 与现有路线的协同

| 路线 | 协同 |
|------|------|
| [`mutability_decision_cn.md`](./mutability_decision_cn.md) Phase 2 (sa3d ECS 前 `&mut T`) | 操作符重载触发的方法**当前可全部用 `&self`**（Phase 1 约定），与 ECS 启动时序对齐 |
| [`macro_vs_rust_cn.md`](./macro_vs_rust_cn.md) `@derive` 系列 | 操作符重载 derive **直接复用** `@derive` 框架，工程量减半 |
| [`/home/vscode/projects/sa_plugins/sa_plugin_3dengines/docs/bevy_fast_sla_roadmap_cn.md`](../../sa_plugin_3dengines/docs/bevy_fast_sla_roadmap_cn.md) Milestone 1 (sa3d_math) | math 库**强依赖**操作符重载，sa3d MVP 启动前必须就位 |
| [`/home/vscode/projects/sa_plugins/sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md`](../../sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md) Phase 1 sa3d_math | 同上 |

**触发条件**：**sa3d_math 包启动前必须完成 Stage 1 的 4 个 derive**。

---

## 6. 4 个占位 demo 已就位

| Demo | 演示 | 文件 |
|------|------|------|
| 301 | Vec3 + Vec3 二元加 | [`301_operator_overload_add/`](../demos/rosetta/301_operator_overload_add/) |
| 302 | -Vec3 一元负 | [`302_operator_overload_neg/`](../demos/rosetta/302_operator_overload_neg/) |
| 303 | Vec3 * f32 异构标量乘 | [`303_operator_overload_scalar_mul/`](../demos/rosetta/303_operator_overload_scalar_mul/) |
| 304 | a == b 自定义结构体比较 | [`304_operator_overload_eq/`](../demos/rosetta/304_operator_overload_eq/) |

每个 demo 含：
- `main.rs`：Rust 原版完整可跑
- `main.sla`：当前占位（计算同一个特征值，确保测试套件能跑）
- `README.md`：未来实现的目标代码 + 编译器实施要点

**等 sla 编译器加入 `@derive(Add/Neg/MulScalar/PartialEq)` 后**，把 `main.sla` 替换为 README 中的目标实现即可。

---

## 7. 一句话总结

**Sla 已经支持显式的 `@overload` 操作符重载块**，限定为 `+ - * /` 的静态分发；裸 `overload` 不是合法入口。

**下一步如果要扩展**，优先顺序仍然是 `@derive(Add/Sub/Mul/Neg/PartialEq/Eq/Hash/PartialOrd/Ord)` 这条白名单路线，和现有 `@derive(Component/Bundle/Resource/Event)` 体系保持一致。

**当前 301-304 占位 demo 已不再是唯一参考**：312 号 demo 展示了 `@overload` 的真实前端路径，后续新增算术重载需求应以它为基准。
