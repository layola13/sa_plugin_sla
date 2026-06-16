# 304 Operator Overload — Custom Eq (`a == b` on struct)

> **状态**：占位符。等待 sla 编译器加入 `@derive(PartialEq)` 支持。

## 命令

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/304_operator_overload_eq/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/304_operator_overload_eq/main.sla --out /tmp/304.sa
SA_PLUGIN_DEV=1 sa sla test  demos/rosetta/304_operator_overload_eq/main.sla
```

## 目标实现（等 sla 支持后替换占位）

```sla
@derive(PartialEq)
struct Point {
    x: int,
    y: int
}

fn main() -> int {
    let a = Point { x: 10, y: 20 };
    let b = Point { x: 10, y: 20 };
    let c = Point { x: 99, y: 0 };

    if a == b {
        // 期望进入
    };
    if a != c {
        // 期望进入
    };
    return 0;
}

@test "rosetta 304 operator_overload_eq"() {
    let a = Point { x: 10, y: 20 };
    let b = Point { x: 10, y: 20 };
    let c = Point { x: 99, y: 0 };
    if a != b { panic(1); };
    if a == c { panic(2); };
};
```

## 编译器实现要点

1. **`@derive(PartialEq)`** → 生成 `impl PartialEq for T { fn eq(&self, other: &Self) -> bool }`
2. **Type checker**：`binary_expr` 中 `==` / `!=` 检测到 struct/enum 时回退查 `PartialEq` 实现（当前 `src/type_checker.zig:1129` 直接返回 boolean 但仅对原生数值）
3. **Codegen**：`a == b` 改写为 `<TypeOf(a)>_eq(&a, &b)` 调用
4. **生成 SA**：逐字段 eq + 短路 and

## 关联 derive 建议

`@derive(PartialEq)` 通常与下列 derive 同时使用，建议一起规划：
- `@derive(Eq)`：标记类型可作 HashMap key（等价于 PartialEq + 自反性）
- `@derive(Hash)`：生成 hash 函数（同字段哈希组合）
- `@derive(PartialOrd)` / `@derive(Ord)`：比较 `<` / `<=` / `>` / `>=`

**实施顺序建议**：先 `PartialEq` + `Eq` + `Hash`（HashMap 必需），再 `PartialOrd` + `Ord`（排序）。

## 与 ECS / 通用业务的关系

`@derive(PartialEq)` 是**通用业务高频需求**：
- 测试断言：`assert_eq!(actual, expected)`
- 集合查找：`vec.iter().position(|x| x == &target)`
- ECS Entity 比较：判断两个 entity handle 是否同一实体
- 缓存键比较

**没有 `==` 重载，每处都要手写 `point_eq(a.x, a.y, b.x, b.y)`**，可读性灾难。
