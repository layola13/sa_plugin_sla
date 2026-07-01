# Std Surface 元数据格式规范

> **文档版本**：v0.1 / 2026-07-01
> **状态**：基于 `sla_std/std_surface.sla_meta` 和 `src/sab_codegen.zig` 实现
> **关联**：[`architecture_cn.md`](./architecture_cn.md)

---

## 1. 概述

`std_surface.sla_meta` 是一个**纯数据文件**，描述 Sla 编译器的标准库表面 lowering 规则。它位于：

```
sla_std/std_surface.sla_meta
```

该文件不是编译器逻辑。SAB 后端通用地读取这些规则，因此标准库表面的 lowering 可以通过导入的 SA 宏实现，而无需在 Zig 中硬编码普通库语义。

### 设计原则

1. **无 `Vec`/`Option`/`Rc`/`Cell` 编译器分支** — 所有库类型降低通过元数据规则
2. **宏优先** — 每条规则指向一个 `sa_std` SA 宏，编译器只是将其组合起来
3. **通用消费者** — SAB 后端通用地读取所有规则行，不按类型名分支

---

## 2. 规则格式

### 2.1 语法

```
<rule_kind> <type_name> <sa_std_path> <macro_name> <args...> [extra...]
```

一行一条规则。`#` 开头为注释。空白行被忽略。

### 2.2 规则种类（Rule Kind）

| 规则种类 | 描述 | 示例 |
|---------|------|------|
| `associated` | 关联函数调用 `Type::func(args)` | `associated Vec new sa_std/vec.sa VEC_NEW out deps=sa_vec_new` |
| `method` | 方法调用 `value.method(args)` | `method Option is_some sa_std/core/option.sa OPTION_IS_SOME out,receiver` |
| `function` | 自由函数调用 `func(recv, args)` | `function len Vec sa_std/vec.sa VEC_LEN out,receiver deps=sa_vec_len` |
| `fallible_method` | 可能失败的方法（需分支检查 ok 寄存器） | `fallible_method Vec remove sa_std/vec.sa VEC_REMOVE ok,out,receiver,index,elem_size deps=sa_vec_try_remove panic=86` |
| `index` | 索引读取 `value[index]` | `index Vec sa_std/vec.sa VEC_GET_TYPED_{elem_ty} out,receiver,index,elem_size` |
| `index_address` | 索引地址 `&value[index]` | `index_address Vec sa_std/vec.sa VEC_GET_MUT_PTR_U64 out,receiver,index` |
| `index_assign` | 索引赋值 `value[index] = val` | `index_assign Vec sa_std/vec.sa VEC_SET_TYPED receiver,index,value,elem_size,elem_ty` |
| `constructor` | 构造函数调用（由返回类型匹配） | `constructor Some Option sa_std/core/option.sa OPTION_NEW_SOME out,value` |

### 2.3 参数字段

参数以逗号分隔。每个可以是：
- **命名参数**：`out`、`receiver`、`value`、`index`、`elem_size`、...（编译器映射到具体寄存器）
- **模板参数**：`{elem_ty}`（在编译时替换为实际类型名，如 `i32` → `VEC_GET_TYPED_I32`）
- **特殊参数**：`ok`（fallible_method 的成功标志寄存器）

### 2.4 元数据指令

跟在宏名称和参数之后，用空格分隔：

| 指令 | 描述 | 示例 |
|------|------|------|
| `deps=name1,name2,...` | 依赖的 sa_std 子宏列表（预加载用） | `deps=sa_vec_push,sa_mem_copy` |
| `panic=N` | 失败时的 panic 代码 | `panic=86` |

---

## 3. 完整的规则表

以下是当前 `std_surface.sla_meta` 中所有规则。

### 3.1 Vec 容器

```yaml
关联:
  associated Vec new → VEC_NEW out
函数:
  function len Vec → VEC_LEN out,receiver
方法:
  method Vec push → VEC_PUSH receiver,value,elem_size
回退方法:
  fallible_method Vec remove → VEC_REMOVE ok,out,receiver,index,elem_size
索引:
  index Vec → VEC_GET_TYPED_{elem_ty} out,receiver,index,elem_size
  index_address Vec → VEC_GET_MUT_PTR_U64 out,receiver,index
  index_assign Vec → VEC_SET_TYPED receiver,index,value,elem_size,elem_ty
```

### 3.2 Option 类型

```yaml
构造函数:
  constructor Some Option → OPTION_NEW_SOME out,value
  constructor None Option → OPTION_NEW_NONE out
方法:
  method Option is_some → OPTION_IS_SOME out,receiver
  method Option is_none → OPTION_IS_NONE out,receiver
  method Option get → OPTION_GET out,receiver
  method Option unwrap → OPTION_UNWRAP out,receiver
  method Option unwrap_or → OPTION_UNWRAP_OR out,receiver,value
```

### 3.3 Result 类型

```yaml
构造函数:
  constructor Ok Result → RESULT_NEW_OK out,value
  constructor Err Result → RESULT_NEW_ERR out,value
方法:
  method Result is_ok → RESULT_IS_OK out,receiver
  method Result is_err → RESULT_IS_ERR out,receiver
  method Result unwrap → RESULT_UNWRAP out,receiver
  method Result unwrap_or → RESULT_UNWRAP_OR out,receiver,value
```

### 3.4 智能指针

```yaml
Box:
  associated Box new → BOX_NEW out,value
  method Box get → BOX_GET_U64 out,receiver
  method Box as_ptr → BOX_AS_PTR out,receiver

Rc:
  associated Rc new → RC_NEW out,value
  associated Rc clone → RC_CLONE_OUT out,value
  method Rc get → RC_GET out,receiver
  method Rc as_ptr → RC_AS_PTR out,receiver

Arc:
  associated Arc new → ARC_NEW out,value
  associated Arc clone → ARC_CLONE_OUT out,value
  method Arc get → ARC_GET out,receiver
  method Arc as_ptr → ARC_AS_PTR out,receiver

RefCell:
  associated RefCell new → REFCELL_U64_NEW out,value

Cell:
  associated Cell new → CELL_NEW_VALUE out,value
  method Cell get → CELL_GET out,receiver
  method Cell set → CELL_SET receiver,value
```

### 3.5 Slice

```yaml
索引:
  index Slice → SLICE_GET_TYPED_{elem_ty} out,receiver,index,elem_size
  index_address Slice → SLICE_GET_MUT_PTR_U64 out,receiver,index
```

---

## 4. 添加新规则

### 4.1 步骤

1. 确定规则种类（`associated` / `method` / `function` / `fallible_method` / `index` / `index_address` / `index_assign` / `constructor`）
2. 在 `sla_std/std_surface.sla_meta` 中添加规则行
3. 在 `sa_std` 中确保目标宏存在（例如 `VEC_NEW`、`OPTION_UNWRAP`）
4. 如果需要新的规则种类，更新 `src/sab_codegen.zig` 中的 `StdSurfaceRuleKind` 枚举和处理逻辑
5. 编写直接 SAB no-fallback 测试

### 4.2 约束条件

- **不要在规则中使用类型名分支**。`index Vec` 和 `index Slice` 通过规则名区分，不是通过 Zig `if type == Vec` 分支
- **使用模板参数**。当类型名嵌入宏名时使用 `{elem_ty}`，如 `VEC_GET_TYPED_{elem_ty}`
- **只添加被失败测试证明需要的规则**。不要提前添加从未使用的规则
- **依赖关系必须准确**。`deps=` 必须列出预加载所需的所有辅助宏

### 4.3 模板参数替换

模板参数在编译时替换。当前支持的模板变量：

| 模板变量 | 替换值 | 示例 |
|----------|--------|------|
| `{elem_ty}` | 元素类型名（小写） | `i32` → `VEC_GET_TYPED_I32` |

模板替换的工作原理：
1. 宏名包含 `{elem_ty}` 占位符时，直接路径查找具体宏
2. 如果替换后的宏名无效，回退到普通参数扁平化

---

## 5. 常见模式

### 关联函数（构造函数）
```yaml
associated <Type> <new> <path> <MACRO_NAME> out,value
```
- `out` — 返回的对象
- `value` — 传递给构造函数的参数

### 查询方法
```yaml
method <Type> <method_name> <path> <MACRO_NAME> out,receiver
```
- `out` — 查询结果（bool 或内部值）
- `receiver` — `self` 参数

### 修改方法
```yaml
method <Type> <method_name> <path> <MACRO_NAME> receiver,value,...
```
- `receiver` — `self` 参数（可变）
- `value` — 要写入的值
- 无 `out` 参数（void 方法）

### 可能失败的方法
```yaml
fallible_method <Type> <name> <path> <MACRO_NAME> ok,out,receiver,... deps=... panic=N
```
- `ok` — 成功标志寄存器（用后检查）
- `out` — 成功时的输出
- 失败时调用 `panic(N)`

### 类型模板索引
```yaml
index <Type> <path> <MACRO_NAME_{elem_ty}> out,receiver,index,elem_size
```
- `{elem_ty}` 被物化为实际类型名
- `elem_size` 是元素字节大小
