# 函数、方法与泛型

Sla 使用强类型的函数、方法与基于单态化的泛型系统，并在顶层提供对闭包与协程异步的原生语法支持。

---

## 1. 函数声明

基本函数使用 `fn` 声明，参数必须声明类型，且必须显式声明返回类型（无返回值时可以省略或返回隐式的空元组）：
```sla
fn add(a: int, b: int) -> int {
    return a + b;
}
```
对于需要接收所有权的拥有权类型参数，可在变量名前加 `^` 指示符；若是借用参数，可加 `&` 指示符：
```sla
fn consume_box(val: ^Box<int>) {
    // val 取得了 Box 的所有权，退出时由编译器自动释放堆内存
}
```

---

## 2. 方法与 UFCS (通用函数调用语法)

在 Sla 中，可以在 `impl` 块中为特定的结构体定义“关联方法”。
* **定义形式**：首个参数约定为 `&self`（借用接收器）或 `self` / `^self`（拥有权接收器）。
  ```sla
  struct Counter {
      value: int,
  }
  
  impl Counter {
      fn tick(&self) -> int {
          return self.value + 1;
      }
  }
  ```
* **UFCS 与方法降低**：Sla 在编译期不需要任何虚函数表或运行时的对象指针。所有的 `x.method(y)` 均会被静态 Lower 转换为非虚静态函数调用：`method(x, y)`。
* **自动借用与自动移动 (Auto-Borrow & Auto-Move)**：
  在调用方法时，如果方法签名声明的是借用 `&self`，而你传入的值是拥有权值 `v`，Sla 编译器会自动将其重写为 `&v`。如果方法声明需要消耗所有权（如 `push(self, val)`），而你传入了未加移动符的值，编译器会自动转换为 `^v`，从而极大地优化了链式调用的可读性：
  ```sla
  // 链式调用
  let my_vec = Vec::new();
  my_vec.push(10).push(20);
  
  // 编译器后台自动 Lower 为：
  // push(^(push(^my_vec, 10)), 20)
  ```

---

## 3. 泛型与编译期单态化 (Monomorphization)

Sla 支持结构体和函数的泛型定义，例如标准的容器 `Option<T>`。
```sla
struct Option<T> {
    has_value: bool,
    value: T,
}

fn make_some<T>(val: T) -> Option<T> {
    return Option<T> {
        has_value: true,
        value: val,
    };
}
```
* **编译期实例化**：泛型定义自身不产生实际的汇编代码。在遇到 `Option<int>` 或 `make_some<float>` 的位置，编译器会对参数 `T` 用具体类型进行替换，产生唯一的单态化结构布局（例如计算出 `Option_int` 的物理字节大小、对齐与成员偏移量），并将函数符号编译为如 `@make_some_int`。这种设计彻底避免了运行时装箱与动态指针反射开销。

---

## 4. 闭包 (Closures)

Sla 支持捕获当前环境的局部闭包字面量：
* **定义与捕获**：使用 `|arg1, arg2| body` 语法声明闭包，它可以捕获外层作用域的活跃变量。
  ```sla
  let base_offset = 10;
  let add_base = |x: int| x + base_offset;
  let result = add_base(5); // 结果为 15
  ```
* **工作机制**：在降低为 SA 时，编译器会根据闭包中捕获的变量自动生成一个隐藏的“上下文结构体”（将外部 `base_offset` 打包存入），并在调用闭包时隐式地将此上下文传递给实际的闭包代理解析函数。

---

## 5. Async / Await 协程异步

Sla 内置了对协程异步编程的一等支持：
* **异步函数**：使用 `async fn` 声明的函数在被调用时不会立刻执行，而是直接返回一个实现了 `future<T>` 类型的协程任务对象。
* **异步等待 (`.await`)**：只能在异步上下文（或特殊的运行桥接中）对 `future` 使用 `.await` 后缀，它会暂停当前协程，并挂载等待通知，直到任务返回具体的计算结果。
  ```sla
  async fn fetch_data() -> int {
      return 42;
  }
  
  async fn process() -> int {
      let f: future<int> = fetch_data();
      let val = f.await; // 挂起并等待任务就绪，最终获取 42
      return val + 8;
  }
  ```
Sla 的异步类型会在最终生成的 SA 中被精准 lowering 为基于状态机状态切换和 Waker 唤醒机制的低开销协程运行代码。\n