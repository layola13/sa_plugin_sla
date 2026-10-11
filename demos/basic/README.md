# SLA Basic Demos（对标 tsgosa）

本目录把 `tsgosa/demos` 中“小而渐进”的基础用例移植为 SLA 写法，
与 `demos/rosetta`（Rust 语义对照，重型）形成互补：
`basic` 聚焦语言基本功 + 常用算法，每一个 demo 都可独立 `check` / `test`。

- 参考源：`/content/sa_all/tsgosa/demos/01_hello` … `200_finale`（TS 版 `main.ts` + `expected.stdout`）
- SLA 写法：`fn main() -> i32`（`println` 演示）+ `@test`（断言语义，等价于 `expected.stdout`）
- Rust 对照仍在 `demos/rosetta`，这里不再重复 Rust，README 会标注对应的 tsgosa 编号。

## Commands

```bash
export PATH="/tmp/gotools/zig-x86_64-linux-0.14.1:/content/sa_all/sci/zig-out/bin:$PATH"
SA_PLUGIN_DEV=1 sa sla check demos/basic/01_hello/main.sla
SA_PLUGIN_DEV=1 sa sla test demos/basic/01_hello/main.sla
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/01_hello/main.sla -o /tmp/basic_01_hello && /tmp/basic_01_hello
```

批量验证（bash）：

```bash
for d in demos/basic/*/; do echo "== $d"; SA_PLUGIN_DEV=1 sa sla check "$d/main.sla" || break; done
for d in demos/basic/*/; do echo "== $d"; SA_PLUGIN_DEV=1 sa sla test "$d/main.sla" || break; done
```

## Index

| SLA demo | 对标 tsgosa | 覆盖点 |
|---|---|---|
| 01_hello | 01_hello / 20_console | `println`，`main -> i32` |
| 02_arith | 02_arith / 21_compound | `+ - * / %`，负数，优先级 |
| 03_if_else | 03_if_else | `if/else`，`max` 函数 |
| 04_while_sum | 04_while_sum / 110_while_break | `while`，累加 |
| 05_for_sum | 05_for_sum | `for in 0..n`，`%` 过滤 |
| 06_ternary | 06_ternary / 153_ternary_chain | `if` 表达式（三元） |
| 07_functions | 07_functions / 125_fact | 递归 `fact`，多函数 |
| 08_arrays | 08_arrays | 定长数组 `[int; N]` 读写 |
| 09_vec_methods | 09_array_methods | `Vec::push/len/remove`，循环求和 |
| 10_strings | 10_strings / 16_template | `println` 格式化，`str_eq` |
| 11_struct | 13_struct / 19_destructure | `struct` 构造，字段读写 |
| 12_impl_counter | 14_class | `struct + impl`（`Counter::inc`） |
| 13_enum_switch | 15_enum_switch | `enum + switch`，`classify` |
| 14_bool_logic | 17_bool_logic | `&& \|\| !` |
| 15_option | 18_optional | `Option::Some/None`，`match` |
| 16_insert_sort | 102_insert_sort | 插入排序（`while` 内移） |
| 17_bsearch_gcd | 101_bsearch / 119_gcd3 | 二分查找 + 辗转相除 |
| 18_fib_sieve | 173_fib_loop / 128_sieve | fib 循环，筛法计数 |
| 19_matrix | 143_mat_add / 144_transpose | 2x2 矩阵加法 + 转置求和 |
| 20_closures | 109_closure / 24_find_some_every | 闭包捕获，`find/some` 手写循环版 |
| 21_gcd_lcm | 120_lcm | 递归 `gcd` + `lcm` |
| 22_second_max | 121_second_max | 一遍扫描最大/次大，`else if` 链 |
| 23_rotate | 122_rotate | 左旋（取模索引，无 `slice/concat`） |
| 24_fizzbuzz | 191_fizz20 | `for 1..(n+1)` + `||` 整除计数 |
| 25_leap | 180_leap | 多 `if` 早返回闰年判断 |
| 26_clamp_max3 | 126_clamp | `if` 表达式链代替 `Math.min/max` |
| 27_sum_sq_dot | 141_sum_sq / 142_dot | 平方和 + 点积 |
| 28_mat_mul | 184_matrix_mul | 2x2 乘法对角元 |
| 29_sum_even_swap | 192_sum_even / 195_swap | 偶数求和 + 三变量交换 |
| 30_palindrome | 103_palindrome | int 数组回文（字符串索引有坑，见 POTENTIAL_ISSUES #3/#5） |
| 31_compound | 21_compound | `+= -= *= /= %= \|= &=` 全原生（#6 已修复） |
| 32_while_break | 110_while_break | `while true + break/continue` |
| 33_switch_return | 111_switch_fn | 混合写法保留，纯全 `return` 臂亦支持（#7 已修复） |
| 34_pick_max | 112_pick_max | `if + 早返回`（与 03 表达式式互补） |
| 35_min_range | 116_minloop / 129_range | 最小值 + 区间求和 |
| 36_prefix | 118_prefix | `^borrow` 原地前缀和 |
| 37_mode | 146_mode | 嵌套循环众数 |
| 38_median | 147_median | 插入排序后取中位数（无 `toSorted`） |
| 39_vec_concat_dedup | 136_concat_all / 117_dedup | `Vec` 拼接 + 手写 `contains` 去重 |
| 40_do_sum | 158_do_sum | `while true + break` 表达 `do-while` 语义 |
| 41_merge_sorted | 123_merge | 双指针归并 + `&&` 收尾 |
| 42_every_positive | 127_sorted | 定长数组手写 `every` |
| 43_tally_even | 140_tally | 偶数计数 + 求和 |
| 44_bit_count | 148_bit_count | `&` + `>>` 置位计数 |
| 45_divmod_maxmin | 179_div_mod / 186_max3 | 整除取余 + 手写 max/min |
| 46_prime_upto | 183_prime_upto | `for + break` 剪枝，30 以内 10 个 |
| 47_default_args | 150_multi_default | 默认参数用双函数表达（见 POTENTIAL_ISSUES #8） |
| 48_nested_break | 157_label_nested | 内层 `break` 代替 label（见 POTENTIAL_ISSUES #9） |
| 49_collatz_pow | 155_collatz / 135_pow_loop | collatz(27)=111（计数口径已核对）+ 2^10 |
| 50_nested_sign_min_step | 189_nest_if3 / 175_min3 / 199_for_step2 | 嵌套 `if` 符号函数 + min3 + `while` 步长求和（`for` 无步长） |
| 51_gcd_sum | 159_gcd_sum | `while` 版 `gcd` + `gcd(i,12)` 累加（=27） |
| 52_pow2_series | 160_pow2 | 翻倍循环 2 的幂 `Vec`（无 `**`，8/1/128） |
| 53_concat3 | 161_concat3 | `Vec::push` 三段拼接（无 `concat`，4/1/4） |
| 54_neg_index | 162_at_neg / 169_neg_idx | `a[len-1]` 表达 `at(-1)`（无负索引） |
| 55_num_sep | 164_num_sep | 普通字面量（数字分隔符见缺口 #11） |
| 56_chain_ops | 165_chain | 顺序赋值表达链式赋值（缺口 #12） |
| 57_iife | 170_iife | 先绑定再调用（直接调用见缺口 #13） |
| 58_sum_2d | 172_sum_2d | 扁平 `[int; 6]` 双层循环（无嵌套字面量） |
| 59_count_even | 174_count_even | `Vec` 版偶数计数（与 29/43 互补） |
| 60_sort_desc | 190_sort_desc | 取反比较子降序插入（与 16/38 互补） |
| 61_while_sum2 | 198_while_sum2 | `while` 倒数累加（与 04/05 互补） |
| 62_pow_sum | 176_pow_sum | 翻倍累乘 2 的幂求和（无 `**`，15） |
| 63_binary | 187_binary | 循环组装二进制 `01010101b=85`（与 44 互补） |
| 64_select | 188_select | 变量索引取值（`a[1]=20`，`a[2]=30`） |
| 65_sort_slice | 178_obj_sum | 插入排序 + 手工拷贝切片（无 `slice`） |
| 66_pair_sum | 194_class_pair | 双字段 `struct+impl` + 求和方法 |
| 67_map_dbl | 193_map_dbl | 显式循环 `push` 表达 `map` 翻倍 |
| 68_str_count | 185_str_join2 | `for-of` 改直列 `str_eq` 计数（无迭代器协议） |
| 69_len_sum | 196_str_len_sum | 字面量 + 变量 `len` 求和（=10，缺口 #10 已修复） |
| 70_finale_mini | 200_finale | 递归 `fib(10)` + 排序首尾和收官综合 |
| 71_tri | 137_tri | `for` 正序三角数累加（=55，与 04/05/61 互补） |
| 72_diag | 138_diag | 扁平 `[int; 4]` 2x2 对角和（无嵌套字面量） |
| 73_area | 133_area | 结构体作函数参数（`6x7=42`） |
| 74_manhattan | 151_obj_param | 对象参数坐标求和（与 73 互补） |
| 75_weekend | 152_enum_calc | `enum + match` 周末判断（全臂列举） |
| 76_flags | 106_flags | `|` 组合 + `&` 测试 + `^` 翻转（与 44 互补） |
| 77_find_index | 108_find_index | 显式循环 + 闭包谓词表达 `findIndex` |
| 78_map_filter | 114_compose | 两轮显式循环表达 `map/filter` 链 |
| 79_nested | 33_nested_struct | 整数嵌套结构体读值（字符串字段暂略） |
| 80_gcd_all | 181_gcd_all | 循环版多组 `gcd` 打印（与 17/21/51 互补） |
| 81_reduce | 25_reduce | 显式循环表达 `reduce` 求和 + 右折求积 |
| 82_reduce_right | 107_reduce_right | 右折减法（`0-4-3-2-1=-10`，与 81 互补） |
| 83_slice_concat | 27_slice_concat | `Vec::push` 手工表达 `slice/concat` |
| 84_spread | 29_spread_elem | 拷贝循环 + `push` 表达展开（无展开语法） |
| 85_rest | 154_rest_first | 定长数组形参表达剩余参数（无 `...rest`） |
| 86_destructure | 156_destructure_call | 显式索引表达解构（无解构语法） |
| 87_chainwrite | 113_chainwrite | 嵌套结构体字段写（与 79 互补） |
| 88_grade | 23_switch_plain | 纯全 `return` 臂分档（#7 已修复） |
| 89_splice | 166_splice_do | 开区间尾段手工切片（与 65/83 同口径） |
| 90_f64_cmp | 22_f64_cmp | 浮点运算比较（首个 f64 demo） |
| 91_lcm_all | 182_lcm_all | 循环版 `gcd` + `lcm` 多组打印（与 21 互补） |
| 92_and_or | 197_and_or | 整数比较式改写与或非（`&&` 口径见 14） |
| 93_override | 104_override | 双结构体各自实现同名方法（无继承语义） |
| 94_nested_tpl | 105_nested_tpl | 双插值模板赋值打印 + `str_eq`（#4b 绕行） |
| 95_str_iter | 11_string_array_iter | 直列 `len()` 改写 `forEach/map`（无迭代器协议） |
| 96_forof_len | 12_for_of | `for-of` 改直列求长（无迭代器协议） |
| 97_gcd_loop | 134_gcd_loop | `main` 内直写辗转相除（与 51/80 互补） |
| 98_sort_copy | 26_sort | 原地排序 + 手工拷贝排序（无 `toSorted`） |
| 99_closure_dbl | 30_closure | 最简闭包绑定调用（与 20 互补） |
| 100_math_floor | 31_math | 分支 `abs` + `as i32` 截断 `floor` |
| 101_map_getset | 35_map_getset | 缺键取零表 `has` + `len(m)` 表长（#14 已修复） |
| 102_map_count | 132_map_count | 取-加-存覆盖累加（11, 2） |
| 103_vec_ops | 28_push_unshift | 整数核手写 `unshift/fill/with`（无方法） |
| 104_generic | 34_generic_fn | `int + bool` 两具化（字符串实例暂略） |
| 105_map_clear | 167_map_clear | `clear()` 后表长为 0（`MAP_CLEAR` 直降） |
| 106_postfix | 268_postfix | 显式加减表达后置自增（无 `++`/`--`） |
| 107_switch_stacked | 282_switch_stacked | 胖箭头两臂同体（无 C 式堆叠 `case`） |
| 108_f64_loop | 279_f64_loop | `while` 显式累加 f64 步进（`n=3,m=7`） |
| 109_f64_neg | 313_fneg | f64 取负 + 比较（`11`） |
| 110_f64_array | 315_float_arr | f64 数组局部存取（#17 绕行：不跨函数返回） |
| 111_struct_args | 310_iface_lit_arg | 结构体字面量/绑定作实参（无继承） |
| 112_vec_grow | 269_arr_rebind | `Vec::push` 表达数组生长（无 `concat`） |
| 113_pow_loop | 273_pow_assign | 循环连乘表达幂赋值（无 `**`/`**=`） |
| 114_struct_pair | 272_destructure_defaults | 显式字段/索引表达解构（无解构语法） |
| 115_switch_dispatch | 271_switch_arms | switch 分发 + `else if` 链（`12,100`） |
| 116_linear_search | 323_unannot_scan | 显式循环表达 indexOf/includes/lastIndexOf（#1 注解） |
| 117_isqrt | 347_math_sqrt | 循环试乘整数开方下取整（无 `Math.sqrt`） |
| 118_sign_imul | 351_math_small | 分支 `sign` + 普通乘法 `imul`（`abs` 见 100） |
| 119_shift | 372_ushr + 412_shift_compound | `>>`/`<<` + 显式移位赋值（无 `>>>`/`<<=`） |
| 120_recurse | 377_funexpr_rec | 具名函数递归 fact/fib（无函数表达式自引用） |
| 121_vec_rebind | 381_arr_clear | 重建绑定表达清空（无 `Vec.clear`） |
| 122_strcmp_lit | 384_strcmp | 字面量关系比较 + helper 包裹（#18 绕行） |
| 123_inbounds | 387_inarr | 显式区间判断表达 `in`（无 `in` 运算符） |
| 124_bool_array | 388_boolkw | 布尔透传 + `bool` 数组 |
| 125_f64_infer | 311_float_infer | 无注解浮点即 `f64` |
| 126_str_switch | 498_str_switch | 字面量 scrutinee + 字面量臂（#18 绕行） |
| 127_arr_swap | 547_swap | 数组形参调用者可见可变（引用语义） |
| 128_shift_big | 452_shift_bigcount | 64 位无掩码位移（与 TS mod-32 不同） |
| 129_truthiness | 442_boolean_ctor | 显式 `!= 0` 表达真值（条件须严格布尔） |
| 130_floor_neg | 497_math_floor_neg + 545_f64round | 分支 floor/ceil/trunc（主覆盖负数） |
| 131_arr_alloc | 446_new_array_n | 占位字面量 + 下标填充（无 `new Array(n)`） |
| 132_struct_str | 552_strobj | `: ptr` 字符串字段 + `len`/`str_eq` |
| 133_pi_const | 574_piconst | 顶层 `const` f64 比较 |
| 134_max_min | 511_math_int | 分支 max/min 双函数（无 `Math.max/min`） |
| 135_enum_ret | 575_enumret | 函数返回枚举 + `match` 消费 |
| 136_top_const_arr | 698_top_const_arr | 顶层 `const` 数组跨函数读（结构体常量见 #19） |
| 137_oob_zero | 701_top_arr_oob | 动态越界读零（字面量越界 exe 不支持） |
| 138_eager_logic | 643_logic_short | `&&`/`||` 急求值（与短路语义不同，见 #21） |
| 139_discard_loop | 672_void_i32 + 676_void_loop | 弃值调用（无 `void` 运算符） |
| 140_indexof_from | 710_top_arr_indexof | 起始位查找（116 延伸） |
| 141_vec_pop | 507_arr_api | `pop().unwrap()`（空表 `None`） |
| 142_prime_count | 183_prime_upto | 试除法素数计数（与 18 筛法互补） |
| 143_fib_iter | 173_fib_loop | 迭代 fib（与 120 递归互补） |
| 144_struct_bool | 790_top_obj_bool | 局部布尔字段结构体（顶层常量见 #19） |
| 145_hex_mask | 1250_mask_idioms | `0x` 字面量掩码（无 `0o`/`0b`；`&` 优先级坑） |
| 146_nested_continue | 893_nested_continue | 嵌套循环 continue（label 跳出见 #9） |
| 147_while_continue | 895_while_continue | while + continue 求和（先步进防死循环） |
| 148_call_len | 898_chain_call_len | `: ptr` 返回再 `len`（未注解落 #15） |
| 149_multi_enum | 842_top_multi_enum | 显式判别值 + 变量 scrutinee |
| 150_idx_compound | 908_arr_compound + 940_compound_var_idx | 下标复合赋值（字面量 + 变量下标） |
| 151_switch_call | 902_switch_call | 调用结果作 switch scrutinee |
| 152_enum_switch | 943_enum_switch | 枚举 switch（与 match 互补） |
| 153_case_const | 948_case_ident | 顶层 `const` 作 case 臂 |
| 154_vec_bool | 388_boolkw | `Vec<bool>`（124 定长版的换 Vec 版） |
| 155_neg_divmod | 383_div_guard | 负数除余向零截断（383 正数延伸） |
| 156_copywithin | 981_copywithin | 显式循环前向重叠拷贝（无方法） |
| 157_ilog10 | 983_math_aux | 循环除数 log10（`sign` 见 118） |
| 158_step3_down | 1048_for_dec | 步长 3 倒数求和（`for` 无步长） |
| 159_while_dec2 | 1050_while_dec | 步长 2 倒数求和（与 158 互补） |
| 160_rev_index_sum | 1052_rev_index | 倒序下标求和（`len()` 先 `as i32`） |
| 161_deep_break | 1053_deep_break | 三层嵌套裸 break（label 见 #9） |
| 162_switch_in_loop | 1055_sw_loop | 循环内 switch（偶 +10/奇 +1） |
| 163_call_bound_loop | 1057_for_call_bound | 调用作循环上界（逐次重求） |
| 164_closure_array | 1071_closure_arr | 捕获数组的闭包（体仅表达式） |
| 165_bool_param | 1044_bool_param | 布尔参数取反（严格布尔） |
| 166_switch_bool | 1099_switch_bool | 布尔字面量臂（条件臂见 #22） |
| 167_arr_identity | 1202_arr_identity + 1203_self_identity | 数组 `==` 为引用恒等 |
| 168_shift_32bit | 1228_shift_sign | 32 位边界 64 位语义（无 `>>>`） |
| 169_bool_not | 1220_double_negation | `!`/`!!` 布尔操作数 |
| 170_shift_loop | 1234_shift_loop | 循环左移翻倍（与 52 机制互补） |
| 171_overflow_64 | 1237_mul_overflow | 64 位不回绕（TS 末项分歧） |
| 172_bit_test | 1248_bit_condition + 1249_bit_ternary | 位→布尔判定（显式比零） |
| 173_xor_swap | 1251_xor_swap | 三遍 `^` 交换（无 `^=`） |
| 174_clamp | 1263_clamp | 三参数夹逼（与 134 互补） |
| 175_between | 1267_between | `&&` 双边区间判定 |
| 176_shift_varcount | 1233_shift_varcount | 变量位移计数（119 字面量版互补） |
| 177_shift_chain | 1239_shift_chain + 1247_shift_compare | 连续位移 + 符号判定（64 位） |
| 178_shift_halve | 1256_shift_while | 循环右移折半（与 170 方向互补） |
| 179_compare_chain | 1258_compare_chain | 比较传递链（与 175 同构） |
| 180_swbind_str | 435_str_switch | `: ptr` 绑定 scrutinee（#18 缩小） |
| 181_find_last | 430_find_last | 倒序查找（无 `findLast`） |
| 182_struct_value | 476_field_compound | 结构体形参值语义（对照 127） |
| 183_factory_struct | 482_factory_arg | 工厂返回结构体（对照 #17） |
| 184_paren_call | 481_paren_call | 括号包裹被调函数 |
| 185_nested_ternary | 1262_nested_ternary | 右嵌套三元分档（06 互补） |
| 186_shift_varcount | 1233_shift_varcount | 变量位移计数（局部 `const` 不可用） |
| 187_two_structs | 791_top_obj_multi | 双局部结构体交叉读（顶层见 #19） |
| 188_f64_pick | 475_f64_mixed_ternary | f64 三元钳零（185 整数版互补） |
| 189_calls_array | 1063_calls_in_array | 调用结果组数组 |
| 190_generic_infer | 1075_generic_erased | 泛型推断调用（104 显式版互补） |
| 191_btree_basic | 132_map_count | 首个 BTreeMap 端到端（#14 口径） |
| 192_result_basic | 1026_catch_arith | 首个 Result demo（无 try/catch） |
| 193_str_array | 286_str_elem | 定长字符串数组存取（无 `split`） |
| 194_f64_param | 1011_arr_param_twice | f64 数组形参（变长不可表达） |
| 195_nest3 | 916_nested_struct | 三层嵌套穿透读（79 两层互补） |
| 196_nested_count | 1278_nested_loop | 裸双层循环计数（146 分支版互补） |
| 197_step2_up | 1279_while_even | 步长 +2 上行累加（159 下行互补） |
| 198_clz32 | 1438_clz32 | 手写前导零计数（178 右移同机制） |
| 199_dowhile_continue | 1395_dowhile_continue | do-while 语义 + 跳过（40 无跳过互补） |
| 200_loop_carry | 1397_loop_var_after | 循环外带末轮值（163 调用界互补） |
| 201_pop_drain | 1416_pop_cond | `len` 驱动排空求和（141 单 pop 互补） |
| 202_for_break | 1270_for_break | 单层区间 for 早停（32 while 版互补） |
| 203_prefix_slice | 1423_slice_0_2 | 手写前缀切片（89 尾段版互补） |
| 204_cond_break | 1268_while_break | 条件循环跳过加早停（147 无停互补） |
| 205_ceil_neg | 1426_ceil_neg | 负数上取整（130 未测分支） |
| 206_iife_nest | 864_top_iife_nest | 嵌套直接调用（57 单层互补） |
| 207_tern_switch | 942_ternary_switch | 三元判别 switch（151 调用版互补） |
| 208_void_fn | 915_void_call | 首个 void 函数（668 同形） |
| 209_boolret | 567_boolret | 布尔返回函数（165 形参互补） |
| 210_sw_field | 939_sw_member | 字段路径 switch（151/207 互补） |
| 211_void_nest | 671_void_fn | void 嵌套调用（208 单层互补） |
| 212_discard_call | 672_void_i32 | 返回值丢弃（141 语句版互补） |
| 213_void_branch | 675_void_branch | 分支内 void 调用 |
| 214_void_loop | 676_void_loop | 循环内 void 调用 |
| 215_dyn_range | 605_top_cond_forlen | 动态上界区间（此前皆字面量） |
| 216_f64_channel | 278_f64_channel | f64 通道（125 比较口径） |
| 217_intmap | 35_map_getset | int 键版（101 字符串版互补） |
| 218_nested_calls | 1062_nested_calls | 实参位嵌套（189 组数组互补） |
| 219_chainret | 1065_chained_returns | 返回表达式组合 |
| 220_elseif_calls | 1066_elseif_calls | 调用判别链（50 变量版互补） |
| 221_gen_struct | 343_generic_erase | 泛型结构体（104 函数版互补） |
| 222_btree_overwrite | 132_map_count | BTree 覆写（102 HashMap 版互补） |
| 223_vec_struct | 13_struct | 结构体数组（141×11 组合） |
| 224_nest4 | 916_nested_struct | 四层穿透（195 三层延伸） |
| 225_struct_write | 13_struct | 单层字段写（87 嵌套版互补） |
| 226_idx_copy | 79_copy_loop | 下标逐元拷贝（203 push 版互补） |
| 227_avg | 76_sum_avg | 整平均（27+45 组合） |
| 228_for_continue | 38_nested_loops | 区间嵌套跳过（146 while 版互补） |
| 229_nest_vec | 172_sum_2d | 嵌套 Vec（58 扁平版互补） |
| 230_fact_iter | 125_fact | 迭代阶乘（120 递归版互补） |
| 231_minmax_sum | 1264_minmax_sum | 极值组合（134 单体互补） |
| 232_leap_list | 25_leap | 闰年表（25 单点互补） |
| 233_fizz_count | 24_fizzbuzz | 整除计数（24 打印版互补） |
| 234_numpalin | 103_palindrome | 算术回文（30 数组版互补） |
| 235_sw_arm | 271_switch_arms | 臂内计算（107 常量版互补） |
| 236_collatz_seq | 155_collatz | 序列版（49 步数版互补） |
| 237_fib_list | 173_fib_loop | 表版（143 单值版互补） |
| 238_prime_list | 183_prime_upto | 表版（46 计数版互补） |
| 239_f64_arith | 278_f64_channel | 减乘除（278 加法互补） |
| 240_vec_dot | 142_dot | Vec 版（27 定长版互补） |
| 241_sieve_mark | 128_sieve | 真筛版（18 试除版互补） |
| 242_minmax_fn | 1264_minmax_sum | 三元体版（134 分支版互补） |
| 243_cumsum | 141_sum_sq | 累计版（27 总额版互补） |
| 244_prefix_max | 121_second_max | 前缀版（22 单遍版互补） |
| 245_formula | 137_tri | 公式版（71/27 循环版互补） |
| 246_vec_reverse | 1441_toReversed | 手写逆序（89 尾段版互补） |
| 247_vec_rotate | 122_rotate | 循环版（23 展开版互补） |
| 248_vec_write | 1281_arr_index | Vec 版（226 定长版互补） |
| 249_vec_swap | 547_swap | Vec 版（127 定长版互补） |
| 250_vec_max | 134_max_min | 扫描版（134 函数版互补） |
| 251_vec_min | 134_max_min | 镜像版（250 互补） |
| 252_vec_prod | 125_fact | Vec 版（230 区间版互补） |
| 253_vec_equal | 167_arr_identity | 逐元版（167 引用版互补） |
| 254_run_prod | 243_cumsum | 积版（243 和版互补） |
| 255_vec_second | 121_second_max | Vec 版（22 定长版互补） |
| 256_gcd_sub | 119_gcd3 | 减法版（17/80 取模版互补） |
| 257_isqrt_newton | 347_math_sqrt | 牛顿版（117 试乘版互补） |
| 258_pow_sqmul | 1231_pow | 平方乘版（49/113 连乘版互补） |
| 259_divmod_sub | 179_div_mod | 减法版（45 算子版互补） |
| 260_bsearch_rec | 101_bsearch | 递归版（17 循环版互补） |
| 261_prime_wheel | 183_prime_upto | 轮式版（46 试除版互补） |
| 262_select_sort | 26_sort | 选择版（16/38/98 互补） |
| 263_lower_bound | 101_bsearch | 下界版（17 等值版互补） |
| 264_mult_table | 893_nested_continue | 嵌套算术（146 计数互补） |
| 265_deep_count | 38_nested_loops | 三层版（228 双层互补） |
| 266_unwrap_or | 1022_map_str_int | `-or` 版（101 取零版互补） |
| 267_result_or | 1026_catch_arith | `-or` 版（192 基础版互补） |
| 268_hashset_int | 1104_set_has_size | 首个 HashSet（#16 互补） |
| 269_btreeset_str | 1321_set_add_add | 首个 BTreeSet（#16 互补） |
| 270_deep_write | 87_chainwrite | 三层版（87 双层互补） |
| 271_vec_struct_write | 223_vec_struct | 写版（223 读版互补） |
| 272_vec_enum | 149_multi_enum | 容器版（149 变量版互补） |
| 273_hashset_str | 1104_set_has_size | str 版（268 互补） |
| 274_opt_pred | 15_option | 谓词版（15 match 版互补） |
| 275_fixed_dynrange | 605_top_cond_forlen | 定长版（215 Vec 版互补） |
| 276_method_args | 14_class | 带参版（12 无参版互补） |
| 277_fact_list | 125_fact | 表版（230 单值版互补） |
| 278_sq_list | 141_sum_sq | 表版（27 总额版互补） |
| 279_tri_list | 137_tri | 表版（71 单值版互补） |
| 280_pow_list | 176_pow_sum | 表版（62 求和版互补） |
| 281_prime_sum | 183_prime_upto | 求和版（238 表版互补） |
| 282_fib_sum | 173_fib_loop | 求和版（237 表版互补） |
| 283_collatz_max | 155_collatz | 最值版（236 序列版互补） |
| 284_odd_sum | 04_while_sum | 步进版（04 逐一版互补） |
| 285_fact_sum | 125_fact | 求和版（230 单值版互补） |
| 286_duel_gcd | 17×256 | 取模减法对峙（6=6） |
| 287_duel_isqrt | 117×257 | 试乘牛顿对峙（3=3） |
| 288_duel_sqsum | 27×245 | 循环公式对峙（55=55） |
| 289_duel_sort | 16×262 | 插入选择对峙（1/5/3） |
| 290_duel_prime | 46×261 | 试除轮式对峙（10=10） |
| 291_duel_fib | 120×143 | 递归迭代对峙（55=55） |
| 292_duel_fact | 120×230 | 递归迭代对峙（120=120） |
| 293_duel_pow | 113×258 | 连乘方乘对峙（1024） |
| 294_duel_collatz | 49×236 | 步数链长对峙（8=8） |
| 295_duel_tri | 71×245 | 循环公式对峙（55=55） |
| 296_duel_abs | 100×06 | 语句表达式对峙（5=5） |
| 297_duel_min | 134×242 | 语句三元对峙（3=3） |
| 298_duel_avg | 227×245 | 循环公式对峙（5=5） |
| 299_duel_max | 134×242 | 语句三元对峙（7=7） |
| 300_duel_swap | 127×173 | 临时异或对峙（34,12） |
| 301_duel_rotid | 247×247 | 旋转复原对峙（1,5） |
| 302_duel_contains | 39×116 | 谓词下标对峙（1/0） |
| 303_duel_second | 22×255 | 定长 Vec 对峙（9=9） |
| 304_duel_pick | 03×06 | 语句三元对峙（7=7） |
| 305_duel_sum | 04×05 | while for 对峙（55=55） |
| 306_bubble_sort | 73_bubble_sort | 第三种手排（1,3,5） |
| 307_tri_fact | 120×230×277 | 三向对峙（120 三版） |
| 308_tri_fib | 120×143×237 | 三向对峙（55 三版） |
| 309_tri_pow | 113×258×119 | 三向对峙（1024 三版） |
| 310_gcd_stein | 119_gcd3 | Stein 第三实现（6,1） |
| 311_tri_tri | 71×245×rec | 三向对峙（55 三版） |
| 312_duel_min3 | 134×185 | 分支三元对峙（1=1） |
| 313_tri_search | 116×17×39 | 三向对峙（2=2=1） |
| 314_duel_stats | 22×27 | 单遍三遍对峙（35=35） |
| 315_tri_sum | 61×305×245 | 三向对峙（55 三版） |
| 316_tri_sort | 16×262×306 | 三向对峙（3 三版） |
| 317_sqrt_bs | 347_math_sqrt | 二分版（117/257 互补） |
| 318_cbrt | 347_math_sqrt | 立方版（117 平方版互补） |
| 319_tri_prime | 46×261×241 | 三向对峙（10 三版） |
| 320_ilog2 | 983_math_aux | log2 部（157 互补） |
| 321_is_square | 347_math_sqrt | 判定版（117 取值版互补） |
| 322_duel_clamp | 26×174 | 语句三元对峙（5=5） |
| 323_tri_gcd | 17×256×310 | 三向对峙（25 三版） |
| 324_duel_rev | 246×246 | 自对偶复原（301 异操作互补） |
| 325_is_tri | 137_tri | 成员版（71 取值版互补） |
| 336_euler_phi | 183_prime_upto | 计数版（46 素数版互补） |
| 337_div_count | 183_prime_upto | 计数版（334 和版互补） |
| 338_pyth_check | 347_math_sqrt | 判定应用（321 互补） |
| 339_pyth_gen | 117_isqrt | 生成版（338 判定互补） |
| 340_fib_gcd | 120×17 | 恒等式对峙（2=2） |
| 341_wilson | 230×328 | 定理合取（5→1） |
| 342_droot | 103_palindrome | 数位版（234 回文版互补） |
| 343_pal_count | 234_numpalin | 计数版（234 单值版互补） |
| 344_modinv | 181_gcd_all | 逆元版（80 互补） |
| 345_euler_thm | 328×336 | 定理合取（1） |
| 326_mat_det | 143_mat_add | 行列式版（19 加法版互补） |
| 327_mat_trace | 143_mat_add | 迹版（19 加法版互补） |
| 328_powmod | 258_pow_sqmul | 取模版（258 明文版互补） |
| 329_quad_roots | 117_isqrt | 求根应用（117 取值版互补） |
| 330_arith_seq | 04_while_sum | 等差版（04 逐一版互补） |
| 331_narci | 103_palindrome | 立方和版（234 回文版互补） |
| 332_palprime | 234×238 | 回文素数合取（234/46 互补） |
| 333_is_fib | 173_fib_loop | 成员版（237 表版互补） |
| 334_perfect | 183_prime_upto | 因子和版（46 素数版互补） |
| 335_amicable | 334_perfect | 亲和版（334 互补） |
| 346_coprime_pairs | 336_euler_phi | 判定版（336 计数版互补） |
| 347_gcd_chain | 340_fib_gcd | 链式版（80/119 口径） |
| 348_lcm_chain | 21_gcd_lcm | 链式版（91 互补） |
| 349_fact_zero | 125_fact | 数位版（285 求和版互补） |
| 350_binom | 137_tri | 组合版（325 成员版互补） |
| 351_catalan | 350_binom | 商式版（350 互补） |
| 352_geom_sum | 330_arith_seq | 等比版（330 等差版互补） |
| 353_mat_pow | 28_mat_mul | 幂版（326/327 互补） |
| 354_mat_trans_sum | 19_matrix | 恒等式版（327 迹版互补） |
| 355_tri_powmod | 328_powmod | 三向版（258 明文版互补） |
| 356_is_prime | 46_trial_div | 判定版（261 轮式版互补） |
| 357_nth_prime | 356_is_prime | 计数版（356 判定版互补） |
| 358_prime_sum | 281_prime_sum | 素数版（238 表版互补） |
| 359_sq_sum | 27_sum_sq | 循环版（288 公式版互补，365 做三向） |
| 360_cube_sum | 359_sq_sum | 立方版（359 平方版互补） |
| 361_fib_even_sum | 237_fib_table | 偶项版（282 求和版互补） |
| 362_harm_bound | 141_sum | 倒数版（239 f64 版互补，纯 int） |
| 363_gcd_table_sum | 125_table | gcd 版（173-表系互补） |
| 364_duel_prime | 46×261 | 判定对峙版（290 互补） |
| 365_tri_sqsum | 288_duel_sqsum | 三向版（359 互补） |
| 366_twin_count | 356_is_prime | 对版（358 求和版互补） |
| 367_prime_gap | 358_prime_sum | 间隙版（357 计数版互补） |
| 368_tri_cubesum | 365_tri_sqsum | 立方版（360 互补） |
| 369_alt_sum | 359_sq_sum | 符号版（330 等差系互补，375 做三向） |
| 370_gcd_grid_sum | 363_gcd_table_sum | 网格版（363 单表版互补） |
| 371_lcm_table_sum | 348_lcm_chain | 表版（363-gcd 表互补） |
| 372_pow3_sum | 352_geom_sum | 3 进制版（352 公比 2 版互补） |
| 373_prime_count | 358_prime_sum | 计数版（357 单值版互补） |
| 374_duel_primecount | 364_duel_prime | 计数对峙版（373 互补） |
| 375_tri_altsum | 368_tri_cubesum | 交错版（369 互补） |
| 376_semiprime | 356_is_prime | 合数版（356 素数版互补） |
| 377_sigma | 337_div_count | 求和版（337 计数版互补，379 做三向） |
| 378_abundant | 377_sigma | 分类版（334 完全数版互补） |
| 379_tri_sigma | 368_tri_cubesum | 除数和版（377 互补） |
| 380_goldbach | 366_twin_count | 和版（366 对版互补） |
| 381_coprime_sum | 346_coprime_pairs | 求和版（336-phi 计数版互补） |
| 382_phi_sum | 336_euler_phi | 累和版（381 互补） |
| 383_lcm_grid | 370_gcd_grid_sum | lcm 版（371 单表版互补） |
| 384_duel_sigma | 374_duel_primecount | 除数和版（379 三向版互补） |
| 385_tri_pow3sum | 375_tri_altsum | 等比版（372 互补） |

> 说明：TS 的高阶方法（`map/filter/reduce/find`）在 SLA 中用显式循环 + 闭包表达，
> 避免依赖尚未进入 direct-SAB 快路径的迭代器协议（roadmap Phase 6）。
> `for in` 协议、`async`、Node/Deno/NPM/Zod 相关 tsgosa demos（203+）不在本批范围。
