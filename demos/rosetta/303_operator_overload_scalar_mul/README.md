# 303 Operator Overload — Scalar Mul (`Vec3 * f32`)

> **状态**：占位符。等待 sla 编译器加入**异构类型**操作符重载支持。

## 命令

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/303_operator_overload_scalar_mul/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/303_operator_overload_scalar_mul/main.sla --out /tmp/303.sa
SA_PLUGIN_DEV=1 sa sla test  demos/rosetta/303_operator_overload_scalar_mul/main.sla
```

## 目标实现（等 sla 支持后替换占位）

```sla
// 方案 A：@derive(MulScalar) 编译器内建（仅 vec * f32 一种形态）
@derive(MulScalar)
struct Vec3 { x: f32, y: f32, z: f32 }

// 方案 B：手写 impl（需 sla trait + 关联类型）
impl Mul<f32> for Vec3 {
    type Output = Vec3;
    fn mul(self: Vec3, s: f32) -> Vec3 {
        return Vec3 { x: self.x * s, y: self.y * s, z: self.z * s };
    }
}

fn main() -> int {
    let a = Vec3 { x: 1.0, y: 2.0, z: 3.0 };
    let b = a * 4.0;
    // b == Vec3 { x: 4.0, y: 8.0, z: 12.0 }
    return 0;
}
```

## 关键设计挑战

与 301 `Vec3 + Vec3`（同构类型）不同，**`Vec3 * f32` 是异构操作**：

| 操作 | impl 形态 | 复杂度 |
|------|---------|--------|
| `Vec3 + Vec3` | `impl Add<Vec3> for Vec3` (默认 Self) | 简单 |
| `Vec3 * f32` | `impl Mul<f32> for Vec3` | **需类型参数** |
| `f32 * Vec3` | `impl Mul<Vec3> for f32` | **第二方向，需独立 impl** |
| `Vec3 * Vec3`（元素乘） | `impl Mul<Vec3> for Vec3` | 与第二方向冲突，需消歧 |

### Sla 编译器选择

**Option 1（推荐）**：编译器内建多个 `@derive`：
- `@derive(MulScalar)` → `Vec3 * f32` + `f32 * Vec3` 同时生成
- `@derive(MulElement)` → `Vec3 * Vec3` 逐元素

**Option 2**：完整 trait 参数化 `Mul<RHS>`，让用户手写 impl。**工程量大，sla 哲学不鼓励**。

**推荐 Option 1**：覆盖 sa3d 99% 实际需求，工程量小。

## 与 sa3d 数学库的关系

标量乘是数学库**最高频操作之一**：
- 速度缩放：`velocity * delta_time`
- 颜色调暗：`color * 0.5`
- 单位向量：`v * (1.0 / v.length())`
- 物理积分：`acceleration * dt`

如果只有 `vec3_mul_scalar(&v, 0.5)`，sa3d 代码冗余度增 30%。
