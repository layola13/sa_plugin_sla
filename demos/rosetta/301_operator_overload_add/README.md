# 301 Operator Overload — Binary Add (`Vec3 + Vec3`)

> **状态**：占位符。等待 sla 编译器加入操作符重载支持。

This directory pairs the Rust rosetta reference with a Sla companion.

- `main.rs`：Rust 原版，演示 `impl Add for Vec3` 实现 `a + b`。
- `main.sla`：当前占位实现（返回特征值 579 等价于输出 5,7,9）。

## 命令

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/301_operator_overload_add/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/301_operator_overload_add/main.sla --out /tmp/301.sa
SA_PLUGIN_DEV=1 sa sla test  demos/rosetta/301_operator_overload_add/main.sla
```

## 目标实现（等 sla 支持后替换占位）

**推荐路径：编译器内建 `@derive(Add)`**（与现有 `@derive` 路线一致，见
[`docs/macro_vs_rust_cn.md`](../../../docs/macro_vs_rust_cn.md)）。

```sla
@derive(Add)
struct Vec3 {
    x: f32,
    y: f32,
    z: f32
}

fn main() -> int {
    let a = Vec3 { x: 1.0, y: 2.0, z: 3.0 };
    let b = Vec3 { x: 4.0, y: 5.0, z: 6.0 };
    let c = a + b;
    // c == Vec3 { x: 5.0, y: 7.0, z: 9.0 }
    return 0;
}

@test "rosetta 301 operator_overload_add"() {
    let a = Vec3 { x: 1.0, y: 2.0, z: 3.0 };
    let b = Vec3 { x: 4.0, y: 5.0, z: 6.0 };
    let c = a + b;
    if c.x != 5.0 { panic(1); };
    if c.y != 7.0 { panic(2); };
    if c.z != 9.0 { panic(3); };
};
```

## 编译器实现要点

1. **Parser**：识别 `@derive(Add)` 注解（已规划，参见 macro_vs_rust §5 Path 1）
2. **AST 改写**：为带 `@derive(Add)` 的 struct 生成 `impl Add for T` 块
3. **Type checker**：`binary_expr` 中 `+` 检测到非数值类型时，**回退查 trait Add 实现**（当前路径直接 `TypeMismatch`，见 `src/type_checker.zig:1121-1126`）
4. **Codegen**：把 `a + b` 改写为 `<TypeOf(a)>_add(&a, &b)` 调用
5. **生成 SA**：调用展开成命名函数 + 逐字段 add

## 备选路径

- **`impl Add for Vec3` 显式实现**（与 Rust 同形态）——需要 sla trait 系统更完整
- **保持命名函数 `vec3_add(&a, &b)`**——不引入操作符重载，让用户写命名调用

推荐 `@derive(Add)`，理由：
- 与现有 `@derive(Copy)/(Default)/(Component)` 系列一致
- 工程量小（约 2-3 天）
- 用户体验等价 Rust
- 覆盖 sa3d math 全部需求（vec/mat/quat 加减乘除）
