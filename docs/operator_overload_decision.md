# Sla Operator Overloading Design Decision

> This is the English counterpart of the Chinese document [Sla 操作符重载设计决策](./operator_overload_decision_cn.md).

> **Document version**: v0.1-draft / 2026-06-15
> **Status**: Capability assessment + design decision + `@overload` implemented (the older placeholder analysis is outdated)
> **Decision recommendation**: `@derive(Add/Sub/Mul/Neg/PartialEq/Eq/Hash/PartialOrd/Ord)` handles automatic derivation, while `@overload` handles explicit hand-written overloads; the two can coexist, but `@overload` has higher precedence
> **Related documents**:
> - [`macro_vs_rust_cn.md`](./macro_vs_rust_cn.md) `@derive` compiler built-in annotation route
> - [`mutability_decision_cn.md`](./mutability_decision_cn.md) Phase 1/2 timeline
> - 4 placeholder demos:
>   - [`demos/rosetta/301_operator_overload_add/`](../demos/rosetta/301_operator_overload_add/)
>   - [`demos/rosetta/302_operator_overload_neg/`](../demos/rosetta/302_operator_overload_neg/)
>   - [`demos/rosetta/303_operator_overload_scalar_mul/`](../demos/rosetta/303_operator_overload_scalar_mul/)
>   - [`demos/rosetta/304_operator_overload_eq/`](../demos/rosetta/304_operator_overload_eq/)

---

## 1. Testing of the Current Status

### 1.1 Current Implementation Status

Tested at `src/type_checker.zig:1115-1138`:

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

**The current implementation already supports static dispatch for `+ - * /` via `@overload`.**

This means expressions such as `vec1 + vec2`, `-vec`, and `a * scalar`, when placed in the context of a target type declared by an `@overload` block, are rewritten into static function calls in the frontend and continue to pass; a bare `overload` is still a compile error.

Whether comparisons such as `a == b` go through overloading is still determined by the current allowlist and type-system constraints, and is not automatically opened up by this `@overload` mechanism.

### 1.2 Impact of the Current Status on the 200+ rosetta Demos

Tested grep results:
- Keywords such as `impl Add` / `trait Add` / `std::ops` **return 0 matches** in rosetta demos / tests / sa_std
- The 301 rosetta demos **contain no operator overloading examples**

**Users can still write named functions; `@overload` can also be used when expressions closer to mathematical notation are desired:**
```sla
let c = vec3_add(&a, &b);          // 替代 a + b
let n = vec3_neg(&v);              // 替代 -v
let scaled = vec3_mul_scalar(&v, 2.0);  // 替代 v * 2.0
let same = point_eq(&a, &b);       // 替代 a == b
```

### 1.3 Quantifying the Pain (Estimated for the sa3d Math Library)

If sa3d used named functions exclusively:

| Expression | Named-function version | Character increase |
|------------|------------------------|--------------------|
| `v + dt * a` | `vec3_add(&v, &vec3_mul_scalar(&a, dt))` | +180% |
| `pos = pos + vel * dt + accel * 0.5 * dt * dt` | 4 levels of nested `vec3_add/mul_scalar` | +300% |
| `n.dot(r) > 0.0` | `vec3_dot(&n, &r) > 0.0` | +30% |
| `if a == b` | `if point_eq(&a, &b)` | +40% |

**Overall redundancy in sa3d math code is +50-80%**. This is why Bevy / glam / nalgebra all use operator overloading — readability is the lifeblood of a math library.

---

## 2. Three Implementation Paths

### Option A: Never Introduce

- ✅ Consistent with SA's "explicit over implicit" philosophy
- ✅ Zero implementation cost
- ❌ Readability disaster for the sa3d math library
- ❌ Difficult Bevy code porting (every `a + b` must become `Vec3::add(a, b)`)
- ❌ LLM training distribution is `a + b`, so the tendency to generate `vec3_add(&a, &b)` is low

**Applicable if**: Sla never pursues a sa3d / Bevy-style route (conflicts with existing plans).

### Option B: Compiler Built-in `@derive` Family (Recommended)

Let users annotate:

```sla
@derive(Add, Sub, Mul, Neg, PartialEq)
struct Vec3 { x: f32, y: f32, z: f32 }
```

When the Sla compiler sees `@derive(Add)` → automatically generate:

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

When `binary_expr` encounters a non-numeric type, the type checker **falls back to looking up a trait impl**; finding an `Add` implementation → rewrites it to a `Vec3_add(&a, &b)` call.

**Supported `@derive` allowlist** (v0.1 recommendation):

| derive | Generated content | Use case |
|--------|-------------------|----------|
| `@derive(Add)` | `impl Add for T`, field-wise addition of like-typed fields | Vec / Matrix / Quat |
| `@derive(Sub)` | `impl Sub for T`, field-wise subtraction of like-typed fields | Same as above |
| `@derive(Mul)` | `impl Mul for T`, field-wise multiplication of like-typed fields (**element-wise**, not dot product) | Vec element-wise multiplication |
| `@derive(Div)` | `impl Div for T` | Math library |
| `@derive(Neg)` | `impl Neg for T`, unary negation | Vec / Quat reversal |
| `@derive(MulScalar)` | `impl Mul<f32>` + `impl Mul<Self> for f32` in both directions | Vec * scalar |
| `@derive(PartialEq)` | `impl PartialEq for T`, field-by-field comparison | Tests / collection lookup |
| `@derive(Eq)` | Marks the type as usable as a HashMap key | HashMap |
| `@derive(Hash)` | `impl Hash for T` | HashMap |
| `@derive(PartialOrd)` / `@derive(Ord)` | `impl PartialOrd/Ord for T`, field-wise lexicographic ordering | Sorting |

**Advantages of Option B**:
- ✅ Consistent with the existing `@derive(Component/Bundle/Resource/Event)` family
- ✅ Small effort (~2-3 days per derive, ~1 month for 10 derives)
- ✅ User experience equivalent to Rust
- ✅ Covers 99% of sa3d math / ECS / business comparison needs
- ✅ Does not introduce trait-system complexity (associated types / parameterized traits)

### Option C: Full Operator Trait System

Let users write full trait impls:

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

- ✅ 100% form-compatible with Rust
- ❌ Requires the Sla trait system to support associated types (`type Output`)
- ❌ Requires the Sla trait system to support parameterization (`Mul<f32>` vs `Mul<Vec3>`)
- ❌ Large effort (~2-3 months)
- ❌ Conflicts with Sla's minimalism philosophy
- ⚠️ User experience is almost identical to Option B

**Not recommended** — Option B already covers all actual needs and requires an order of magnitude less effort.

---

## 3. Recommendation: Option B in Three Stages

### Stage 1 (mandatory, 1 week)

A minimum of 4 derives, covering sa3d math and basic business needs:

| derive | Duration | Notes |
|--------|----------|-------|
| `@derive(Add)` | 2 days | Most commonly used |
| `@derive(Sub)` | 1 day | Symmetric with Add |
| `@derive(Neg)` | 1 day | Simple |
| `@derive(PartialEq)` | 2 days | Required for tests + business logic |

**After completion**: replace the three placeholder demos 301, 302, and 304 with real implementations.

### Stage 2 (recommended, 1 week)

Fill in the math + HashMap needs:

| derive | Duration | Notes |
|--------|----------|-------|
| `@derive(MulScalar)` | 3 days | Critical for sa3d |
| `@derive(Mul)` | 1 day | Element-wise multiplication |
| `@derive(Div)` | 1 day | Math library |
| `@derive(Eq)` + `@derive(Hash)` | 2 days | HashMap key |

**After completion**: replace the 303 placeholder demo with a real implementation.

### Stage 3 (as needed, 1 week)

Sorting-related:

| derive | Duration |
|--------|----------|
| `@derive(PartialOrd)` | 2 days |
| `@derive(Ord)` | 2 days |

**Total: 3 weeks for one person to complete the full set of 10 derives**.

---

## 4. Compiler Implementation Points

### 4.1 Parser Changes

Recognize the `@derive(Trait1, Trait2, ...)` annotation:

```
@derive(Add, Sub, Mul, Neg, PartialEq)
struct Vec3 { x: f32, y: f32, z: f32 }
```

Attach it to the `StructDecl.derives: []TraitName` field.

### 4.2 AST Rewriting

Each derive triggers generation of the corresponding impl block (before type checking):

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

### 4.3 Type Checker Changes (most critical)

Current path for `binary_expr` (`src/type_checker.zig:1115-1138`):

```zig
.add, .sub, .mul, .div, .mod => {
    if (!isNumericType(l_ty)) {
        return TypeError.TypeMismatch;   // ← 当前路径
    }
    ty.* = l_ty.*;
}
```

New path:

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

### 4.4 Codegen Changes

No additional changes needed — the AST is already rewritten to `call_expr` during type checking and follows the existing call path.

### 4.5 Error Messages

```
error[SLA-OP-001]: cannot apply `+` to type `Vec3`.
  Hint: add `@derive(Add)` to the struct definition, or use `vec3_add(&a, &b)`.
  --> example.sla:42:15
```

---

## 5. Coordination with Existing Routes

| Route | Coordination |
|-------|--------------|
| [`mutability_decision_cn.md`](./mutability_decision_cn.md) Phase 2 (`&mut T` before sa3d ECS) | Methods triggered by operator overloading **can all currently use `&self`** (Phase 1 convention), aligned with the ECS start timeline |
| [`macro_vs_rust_cn.md`](./macro_vs_rust_cn.md) `@derive` family | Operator overloading derives **directly reuse** the `@derive` framework, halving the effort |
| [`/home/vscode/projects/sa_plugins/sa_plugin_3dengines/docs/bevy_fast_sla_roadmap_cn.md`](../../sa_plugin_3dengines/docs/bevy_fast_sla_roadmap_cn.md) Milestone 1 (sa3d_math) | The math library **strongly depends** on operator overloading; it must be in place before the sa3d MVP begins |
| [`/home/vscode/projects/sa_plugins/sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md`](../../sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md) Phase 1 sa3d_math | Same as above |

**Trigger condition**: **the 4 Stage 1 derives must be completed before the sa3d_math package begins**.

---

## 6. The 4 Placeholder Demos Are in Place

| Demo | Demonstrates | Files |
|------|--------------|-------|
| 301 | Vec3 + Vec3 binary addition | [`301_operator_overload_add/`](../demos/rosetta/301_operator_overload_add/) |
| 302 | -Vec3 unary negation | [`302_operator_overload_neg/`](../demos/rosetta/302_operator_overload_neg/) |
| 303 | Vec3 * f32 heterogeneous scalar multiplication | [`303_operator_overload_scalar_mul/`](../demos/rosetta/303_operator_overload_scalar_mul/) |
| 304 | a == b custom struct comparison | [`304_operator_overload_eq/`](../demos/rosetta/304_operator_overload_eq/) |

Each demo contains:
- `main.rs`: the original Rust version, fully runnable
- `main.sla`: current placeholder (computes the same characteristic value so the test suite can run)
- `README.md`: the target code for the future implementation + compiler implementation points

**Once the Sla compiler adds `@derive(Add/Neg/MulScalar/PartialEq)`**, simply replace `main.sla` with the target implementation in the README.

---

## 7. One-Sentence Summary

**Sla already supports explicit `@overload` operator overloading blocks**, limited to static dispatch for `+ - * /`; a bare `overload` is not a valid entry point.

**If expansion is the next step**, the priority remains the `@derive(Add/Sub/Mul/Neg/PartialEq/Eq/Hash/PartialOrd/Ord)` allowlist route, kept consistent with the existing `@derive(Component/Bundle/Resource/Event)` system.

**The current 301-304 placeholder demos are no longer the only reference**: demo 312 demonstrates the real frontend path for `@overload`, and future arithmetic overloading work should use it as the baseline.
