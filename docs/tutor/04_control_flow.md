# 控制流与模式匹配

Sla 的控制流兼具高级编程语言的表达力与底层编译器的安全性，特别针对 SA 的限制做出了专门的优化。

---

## 1. 条件分支 (`if/else` 与 `if let`)

Sla 中的 `if/else` 可以作为表达式使用，分支的最后一条语句即为表达式的返回值。
```sla
let limit = 50;
let message = if limit > 100 {
    "excessive"
} else {
    "normal"
};
```

Sla 还支持 `if let` 链条，用于解构并匹配枚举变体：
```sla
if let Message::Move { x, y } = msg {
    let sum = x + y;
} else {
    // 匹配失败时的备用分支
}
```

---

## 2. 循环结构 (`for` 与 `while`)

### 数值区间 `for` 循环
数值区间的 `for` 循环使用 `start..end` 的形式（左闭右开）：
```sla
let sum = 0;
for i in 0..10 {
    sum = sum + i;
}
```
> **堆分配提升 (Hoisting) 机制**：由于 SA 规定循环体内部不能有动态或局部的 `stack_alloc` 声明，Sla 编译器会自动分析循环体内声明的所有栈变量，并将其**强制 hoisted（提升）**到循环标签的顶部之前分配。在循环每次迭代时，仅复用同一片物理栈空间，确保控制流跳转时满足 SA 静态验证的要求。

### 条件 `while` 循环
```sla
let count = 5;
while count > 0 {
    count = count - 1;
}
```

---

## 3. 自定义迭代器协议 (`for-in` 协议)

除了普通的数值区间循环，Sla 还支持通过自定义协议遍历复杂结构。任何实现了以下两个方法的结构体，都可以直接作为 `for` 循环的目标：
1. `iter_len(&self) -> i64`：返回集合的总长度。
2. `iter_at(&self, index: i64) -> T`：按索引返回元素（可以通过值拷贝或转移所有权）。

### 迭代协议示例
```sla
struct Item {
    id: i32,
}

struct Query<T> {
    items: Vec<T>,
}

impl Query<T> {
    fn iter_len(&self) -> i64 {
        return len(self.items) as i64;
    }

    fn iter_at(&self, index: i64) -> T {
        return self.items[index]; // 获取元素
    }
}

fn process_query(q: Query<Item>) -> i32 {
    let total = 0;
    // q 实现了 iter_len 和 iter_at 协议，可直接进行 for-in 循环
    for item in q {
        total = total + item.id;
    }
    return total;
}
```

---

## 4. 模式匹配 (`switch` 与 `match`)

### `switch` 表达式
用于对字面量进行分流，类似于其它语言中的 switch。必须包含 `default` 分支以确保穷尽性：
```sla
let code = 200;
let status_msg = switch code {
    200 => "OK",
    404 => "Not Found",
    default => "Unknown Error"
};
```

### `match` 表达式
用于有标签联合（Enum）变体的匹配。匹配的分支中可以直接提取绑定字段，还可以加入模式守护条件（Guard）：
```sla
enum Message {
    Quit,
    Move { x: int, y: int },
}

fn process_msg(msg: Message) -> int {
    match msg {
        Message::Quit => {
            return 0;
        },
        Message::Move { x, y } if x > 0 => {
            return x + y;
        },
        Message::Move { x, y } => {
            return -x + y;
        }
    };
}
```
* Sla 的模式匹配不只安全，编译器还会在特定变体分支未走通时自动清理局部变量占用的寄存器状态，杜绝内存泄漏。\n