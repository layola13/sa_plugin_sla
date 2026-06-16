# 302 Operator Overload — Unary Neg (`-vec`)

> **状态**：占位符。等待 sla 编译器加入一元运算符重载支持。

## 命令

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/302_operator_overload_neg/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/302_operator_overload_neg/main.sla --out /tmp/302.sa
SA_PLUGIN_DEV=1 sa sla test  demos/rosetta/302_operator_overload_neg/main.sla
```

## 目标实现（等 sla 支持后替换占位）

**推荐路径：编译器内建 `@derive(Neg)`**。

```sla
@derive(Neg)
struct Vec3 {
    x: f32,
    y: f32,
    z: f32
}

fn main() -> int {
    let a = Vec3 { x: 1.0, y: -2.0, z: 3.0 };
    let b = -a;
    // b == Vec3 { x: -1.0, y: 2.0, z: -3.0 }
    return 0;
}

@test "rosetta 302 operator_overload_neg"() {
    let a = Vec3 { x: 1.0, y: -2.0, z: 3.0 };
    let b = -a;
    if b.x != 0.0 - 1.0 { panic(1); };
    if b.y != 2.0 { panic(2); };
    if b.z != 0.0 - 3.0 { panic(3); };
};
```

## 编译器实现要点

1. **Parser / Lexer**：sla 已有 `-` 作前缀一元负号（数值），需要扩展到 struct
2. **AST 改写**：`@derive(Neg)` → 生成 `impl Neg for T { fn neg(self) -> T }`
3. **Type checker**：`unary_expr.op == .neg` 检测到非数值时回退查 `Neg` 实现（当前路径仅允许数值）
4. **Codegen**：`-x` 改写为 `<TypeOf(x)>_neg(&x)` 调用
5. **生成 SA**：逐字段 `0 - field` 输出

## 与 sa3d 数学库的关系

`Vec3::neg` 在 sa3d 的 transform / 物理 / 光照计算中频繁出现：

- 法向量翻转：`let inward = -n;`
- 反向速度：`let v_back = -velocity;`
- 镜像变换：`Mat4::from_scale(-Vec3::ONE)`

若仅支持 `vec3_neg(&v)` 命名函数，代码阅读性差一档。
