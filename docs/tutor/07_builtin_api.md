# 编译器内置 API 与标准库手册

Sla 没有把所有核心功能（如堆管理、并发、集合等）硬编码在编译器内部，而是通过强大的编译器感知（Compiler Intercepts）和外挂 ABI 接口，提供了一系列高度优化、无缝贴合的内置 API 系统。

---

## 1. 基础指针与堆管理 API

### 堆所有权包装 (`Box<T>`)
`Box` 提供了最直接的单所有者堆内存管理抽象。
* `Box::new<T>(val: T) -> Box<T>`：在堆上分配空间并将 `val` 移动存入，返回堆受管的 Box。
* `Box::into_raw<T>(b: Box<T>) -> ptr`：消耗 Box 对象，取出底层分配的物理内存裸指针地址，并**销毁**当前所有权生命周期控制，转交由物理指针接管。
* `Box::from_raw<T>(p: ptr) -> Box<T>`：从裸指针所有权地址重新包装、恢复构建一个由 Box 自动管理生命周期的受管对象。

### 引用计数智能指针 (`Rc<T>` & `Arc<T>`)
* `Rc::new<T>(val: T) -> Rc<T>` / `Arc::new<T>(val: T) -> Arc<T>`：在堆上建立单线程 (Rc) 或多线程安全 (Arc) 的引用计数对象。
* `rc.clone() -> Rc<T>` / `arc.clone() -> Arc<T>`：返回该引用计数指针的新拷贝，并在底层递增引用计数，所有权不会发生转移。

---

## 2. 内聚可变性容器 (Interior Mutability)

### `Cell<T>`
针对简单 `Copy` 类型，提供无运行时锁开销的内部可变容器。
* `Cell::new<T>(val: T) -> Cell<T>`：初始化 Cell。
* `cell.get() -> T`：拷贝并取出内部包装的值。
* `cell.set(val: T)`：用新值替换内部存放的值。

### `RefCell<T>`
针对不支持复制的拥有权类型，在运行时执行动态借用检查（单写多读）。
* `RefCell::new<T>(val: T) -> RefCell<T>`：初始化 RefCell。
* `cell.borrow() -> BorrowGuard`：动态只读借用内部值。若在此期间存在活跃的独占写借用，运行时将触发 `panic(107)`。
* `cell.borrow_mut() -> BorrowMutGuard`：动态独占写借用。若在此期间存在其它的读/写借用，同样会触发 `panic(107)`。

---

## 3. 并发多线程与原子操作

### 线程与通道 (`thread` & `mpsc`)
* `thread::spawn(closure) -> JoinHandle`：在后台拉起一个物理线程执行闭包任务。
* `mpsc::channel<T>() -> (Sender<T>, Receiver<T>)`：创建一个多生产者、单消费者并发通道。
  * `sender.send(val: T) -> Result<(), Error>`：向通道投递数据。
  * `receiver.recv() -> Result<T, Error>`：阻塞等待接收通道数据。
  * `sender.clone() -> Sender<T>`：克隆发送端以便在多个线程间分发发送权限。

### 互斥锁与读写锁 (`Mutex` & `RwLock`)
* `Mutex::new(val: i32) -> Mutex`：创建一把保护整数的互斥锁。
  * `mutex.lock() -> Result<MutexGuard, Error>`：加锁并返回受 RAII 机制保护的 Guard。
* `RwLock::new(val: i32) -> RwLock`：创建一把多读单写的共享锁。
  * `lock.read() -> Result<ReadGuard, Error>` / `lock.write() -> Result<WriteGuard, Error>`。

### 原子原生类型 (`AtomicI32` & `AtomicUsize` & `AtomicPtr`)
支持高速多线程无锁数据访问。
* `AtomicX::new(val) -> AtomicX`
* `atomic.load(ordering: int) -> val`
* `atomic.store(val, ordering: int)`
* `atomic.fetch_add(val, ordering: int) -> old_val`
* `atomic.compare_exchange(expected, new, success_ord, fail_ord) -> Result<old_val, old_val>`

---

## 4. 内置容器与数据集合

Sla 深度集成了 SA 已经实现的几个底层的标准库容器布局，其核心操作会被编译器在 Codegen 阶段直接 Lower 转换。

### 向量集合 (`Vec<T>`)
* `Vec::new() -> Vec<T>`：新建空向量。
* `vec(val1, val2, ...)`：内置多参数初始化函数。
* `vec.len() -> int`：返回元素数量。
* `vec.push(elem: T)`：追加一个元素。
* `vec.pop() -> Option<T>`：弹出末尾元素。
* `vec.remove(index: int) -> Option<T>`：移除特定位置的元素。

### 字典表 (`HashMap<K, V>` & `BTreeMap<K, V>`)
* `HashMap::new()` / `BTreeMap::new()`：新建哈希映射或 B-树映射。
* `map.len() -> int`：返回表的大小。
* `map.insert(k, v) -> Option<V>`：插入键值对。
* `map.get(k) -> Option<&V>`：按键查询对应的值引用。

### 集合 (`HashSet<K>` & `BTreeSet<K>`)
* `HashSet::new()` / `BTreeSet::new()`：新建集合。
* `set.len() -> int`：返回集合内元素数量。
* `set.insert(k) -> bool`：向集合内插入值，原先不存在时返回 `true`。
* `set.contains(k) -> bool`：判断集合中是否包含该键。

---

## 5. 字符串系统与迭代器方法链

### 字符串操作
Sla 的字符串包括不可变的静态 `String` 和可动态增长并支持格式化的 `FormatString`。
* `s.len() -> int`：返回字符串的字节长度。
* `s.str_eq(other) -> bool`：字符串物理比对。
* `s.as_ptr() -> ptr`：获取首字节地址裸指针。
* `s.as_bytes() -> Slice` / `s.bytes() -> Slice`：导出为字节切片。

### 迭代器方法链优化
数组、切片以及 `Vec` 支持使用方法链执行流式数据加工。如 `.iter()` 与 `.into_iter()`：
* 支持调用：`.map(closure)`, `.filter(closure)`, `.fold(init, closure)`, `.copied()`, `.sum()`, `.collect()`, `.join(sep)`。
```sla
let my_arr = [1, 2, 3, 4];
// 计算数组的平方和
let total = my_arr.iter().map(|x| x * x).sum(); // 结果为 30
```
> **优化原理**：在降解代码时，编译器并不真正创建任何迭代器对象、也不频繁进行内存分配。这套流式 API 链会在 Codegen 阶层直接被静态解构为对应的扁平、高效率的 `while` 或 `for` 的数值计数内联循环，性能等同于手写。

---

## 6. 文件、路径与外部资源管理

### 文件读写 (`File`)
* `File::open(path_str) -> Result<File, Error>`：打开一个文件。
* `file.as_raw_fd() -> i32`：返回对应的操作系统底层文件描述符。

### 路径与元数据查询 (`path`)
* `path_str.try_exists() -> bool`：判断路径对应的文件/文件夹是否存在。
* `path_str.is_file() -> bool`
* `path_str.is_dir() -> bool`
* `path_str.is_symlink() -> bool`
* `path_str.metadata() -> Result<Metadata, Error>`
* `Metadata` 方法：
  * `meta.is_file() -> bool`
  * `meta.is_dir() -> bool`
  * `meta.is_symlink() -> bool`
  * `meta.modified_ms() -> u64`
  * `meta.created_ms() -> u64`

---

## 7. 错误传播与辅助函数

### 错误传播操作符 `?`
`?` 是施加在返回 `Result<T, E>` 类型的表达式后的后缀一元操作符。
* **展开逻辑**：如果该表达式评估出 `Ok(v)`，它自动解包取出内部的值 `v` 并继续运行；若评估出 `Err(e)`，编译器将自动接管当前函数作用域，执行所有活跃变量的安全析构清理（自动插入 `!`），然后令当前函数提前返回该 `Err(e)`：
  ```sla
  fn load_data() -> Result<int, Error> {
      let file = File::open("config.json")?; // 如果失败，自动在此处清理并直接返回错误
      return Ok(100);
  }
  ```

### 内存所有权规避与手动逃逸 (`mem` & `ManuallyDrop`)
当与不安全的 C 语言交互，或进行极其复杂的多线程并发结构构建时，可以手动打破自动生命周期规则：
* `mem::forget<T>(val: T)`：消耗所有权并不执行任何物理释放，常用于将内存交给第三方 C-ABI 库接管。
* `ManuallyDrop::new<T>(val: T) -> ManuallyDrop<T>`：包装资源，防止其退出作用域时被自动释放。
* `ManuallyDrop::into_inner<T>(md: ManuallyDrop<T>) -> T`：取出包装内部的值，重新恢复自动所有权析构控制。\n