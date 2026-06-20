# 卫生宏 (Hygienic Macros)

Sla 摒弃了 C/SA 的非安全文本替换宏，在编译器前端提供了一套强大的**卫生宏 (Hygienic Macros)** 系统，支持在编译期重组并生成安全的 AST 树，最后将其 1:1 转译降解为底层的汇编预处理结构。

---

## 1. 宏定义语法

在 Sla 中，使用 `macro` 关键字声明宏，它接收一组参数并在块内定义宏模板主体：
```sla
macro swap(a, b) {
    let temp = ^a;
    a = ^b;
    b = ^temp;
}
```

调用宏的语法非常简单，如同调用普通函数一般：
```sla
let x = 1;
let y = 2;
swap(x, y); // 宏展开
```

---

## 2. 卫生性安全设计 (Hygiene)

### 经典变量碰撞问题
在非卫生的文本宏系统中，如果我们在宏内部声明了一个临时变量 `temp`：
```text
#define SWAP(a, b)  int temp = a; a = b; b = temp;
```
如果调用方的上下文里也碰巧包含了一个叫做 `temp` 的变量，且被用作了宏参数（如 `SWAP(temp, y)`），展开后会产生重名变量碰撞或不可预料的词法遮蔽，导致编译故障或逻辑漏洞。

### Sla 的解决方案：Alpha 转换 (Alpha-conversion)
Sla 编译器在前端解析并构建宏的 AST 树时，会执行专门的**词法卫生性扫描**：
1. **重命名局部符号**：自动识别宏定义块内部声明的所有临时本地变量（如 `let temp`），并将其自动 Alpha 重命名为在程序全局上下文内唯一的混淆名（例如将 `temp` 自动替换为 `swap_temp_unique_01`）。
2. **保持输入绑定**：确保作为参数传进来的变量（如 `a`, `b`）映射到正确的调用方作用域标识符，而不被宏内部的本地符号误捕获。

---

## 3. 1:1 降阶至 SA `[MACRO]`

最终生成的 SA 汇编中仍然可以通过 SA 预处理器 `[MACRO]` 的方式保持代码复用。Sla 编译器会根据前端做完 Alpha 转换后的安全 AST 树，输出一个结构清晰的汇编宏模板：

### 编译后的 SA 汇编形式
```sa
// 自动生成的 SA Hygienic 宏模板
[MACRO] swap_hygiene %a, %b
    swap_temp_unique_01 = ^%a
    %a = ^%b
    %b = ^swap_temp_unique_01
    !swap_temp_unique_01 // 自动补全内部临时变量释放
[END_MACRO]

// 调用点展开
EXPAND swap_hygiene x, y
```
这样，开发者在编写高水平 `.sla` 时，能享受到类似 Rust 般无污染、高安全性的卫生宏；而底层的编译器又以最简短的指令和 1:1 降低模式，保证了编译生成的汇编具备可调试性。\n