# Std Surface Metadata Format Specification

> This is the English counterpart of the Chinese document [Std Surface 元数据格式规范](./std_surface_metadata_cn.md).

> **Document version**: v0.1 / 2026-07-01
> **Status**: Based on the implementation in `sla_std/std_surface.sla_meta` and `src/sab_codegen.zig`
> **Related**: [`architecture_cn.md`](./architecture_cn.md)

---

## 1. Overview

`std_surface.sla_meta` is a **pure data file** describing the standard-library surface lowering rules of the Sla compiler. It is located at:

```
sla_std/std_surface.sla_meta
```

This file is not compiler logic. The SAB backend reads these rules generically, so standard-library surface lowering can be implemented via imported SA macros without hardcoding ordinary library semantics in Zig.

### Design Principles

1. **No `Vec`/`Option`/`Rc`/`Cell` compiler branches** — all library types are lowered through metadata rules
2. **Macro-first** — every rule points to an `sa_std` SA macro; the compiler merely composes them
3. **Generic consumer** — the SAB backend reads all rule rows generically, without branching on type names

---

## 2. Rule Format

### 2.1 Syntax

```
<rule_kind> <type_name> <sa_std_path> <macro_name> <args...> [extra...]
```

One rule per line. Lines beginning with `#` are comments. Blank lines are ignored.

### 2.2 Rule Kinds

| Rule kind | Description | Example |
|-----------|-------------|---------|
| `associated` | Associated function call `Type::func(args)` | `associated Vec new sa_std/vec.sa VEC_NEW out deps=sa_vec_new` |
| `method` | Method call `value.method(args)` | `method Option is_some sa_std/core/option.sa OPTION_IS_SOME out,receiver` |
| `function` | Free function call `func(recv, args)` | `function len Vec sa_std/vec.sa VEC_LEN out,receiver deps=sa_vec_len` |
| `fallible_method` | Method that may fail (requires a branch checking the ok register) | `fallible_method Vec remove sa_std/vec.sa VEC_REMOVE ok,out,receiver,index,elem_size deps=sa_vec_try_remove panic=86` |
| `index` | Index read `value[index]` | `index Vec sa_std/vec.sa VEC_GET_TYPED_{elem_ty} out,receiver,index,elem_size` |
| `index_address` | Index address `&value[index]` | `index_address Vec sa_std/vec.sa VEC_GET_MUT_PTR_U64 out,receiver,index` |
| `index_assign` | Index assignment `value[index] = val` | `index_assign Vec sa_std/vec.sa VEC_SET_TYPED receiver,index,value,elem_size,elem_ty` |
| `constructor` | Constructor call (matched by return type) | `constructor Some Option sa_std/core/option.sa OPTION_NEW_SOME out,value` |

### 2.3 Argument Fields

Arguments are comma-separated. Each can be:

- **Named argument**: `out`, `receiver`, `value`, `index`, `elem_size`, ... (mapped by the compiler to concrete registers)
- **Template argument**: `{elem_ty}` (replaced at compile time with the actual type name, e.g. `i32` → `VEC_GET_TYPED_I32`)
- **Special argument**: `ok` (the success-flag register of a fallible_method)

### 2.4 Metadata Directives

These follow the macro name and arguments, separated by spaces:

| Directive | Description | Example |
|-----------|-------------|---------|
| `deps=name1,name2,...` | List of dependent sa_std sub-macros (for preloading) | `deps=sa_vec_push,sa_mem_copy` |
| `panic=N` | Panic code on failure | `panic=86` |

---

## 3. Complete Rule Tables

The following are all rules currently in `std_surface.sla_meta`.

### 3.1 Vec Container

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

### 3.2 Option Type

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

### 3.3 Result Type

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

### 3.4 Smart Pointers

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

## 4. Adding a New Rule

### 4.1 Steps

1. Determine the rule kind (`associated` / `method` / `function` / `fallible_method` / `index` / `index_address` / `index_assign` / `constructor`)
2. Add a rule row in `sla_std/std_surface.sla_meta`
3. Ensure the target macro exists in `sa_std` (e.g. `VEC_NEW`, `OPTION_UNWRAP`)
4. If a new rule kind is needed, update the `StdSurfaceRuleKind` enum and handling logic in `src/sab_codegen.zig`
5. Write a direct-SAB no-fallback test

### 4.2 Constraints

- **Do not use type-name branches in rules**. `index Vec` and `index Slice` are distinguished by rule name, not by a Zig `if type == Vec` branch
- **Use template arguments**. Use `{elem_ty}` when the type name is embedded in a macro name, such as `VEC_GET_TYPED_{elem_ty}`
- **Only add rules proven necessary by a failing test**. Do not add rules in advance that are never used
- **Dependencies must be accurate**. `deps=` must list all helper macros required for preloading

### 4.3 Template Argument Substitution

Template arguments are substituted at compile time. Currently supported template variables:

| Template variable | Replacement value | Example |
|-------------------|-------------------|---------|
| `{elem_ty}` | Element type name (lowercase) | `i32` → `VEC_GET_TYPED_I32` |

Template substitution works as follows:
1. When a macro name contains a `{elem_ty}` placeholder, the direct path looks up the concrete macro
2. If the substituted macro name is invalid, fall back to ordinary argument flattening

---

## 5. Common Patterns

### Associated Functions (Constructors)

```yaml
associated <Type> <new> <path> <MACRO_NAME> out,value
```
- `out` — the returned object
- `value` — the argument passed to the constructor

### Query Methods

```yaml
method <Type> <method_name> <path> <MACRO_NAME> out,receiver
```
- `out` — the query result (bool or internal value)
- `receiver` — the `self` argument

### Mutating Methods

```yaml
method <Type> <method_name> <path> <MACRO_NAME> receiver,value,...
```
- `receiver` — the `self` argument (mutable)
- `value` — the value to write
- No `out` argument (void method)

### Fallible Methods

```yaml
fallible_method <Type> <name> <path> <MACRO_NAME> ok,out,receiver,... deps=... panic=N
```
- `ok` — the success-flag register (check after use)
- `out` — the output on success
- On failure, calls `panic(N)`

### Type-Templated Indexing

```yaml
index <Type> <path> <MACRO_NAME_{elem_ty}> out,receiver,index,elem_size
```
- `{elem_ty}` is materialized as the actual type name
- `elem_size` is the byte size of the element
