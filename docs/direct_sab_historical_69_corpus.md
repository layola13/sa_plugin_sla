# Historical direct-SAB 69-file corpus

Authoritative baseline commit: `ecd9570f354aed470c0e3dc65f5b65572beaff68`.

The membership below is generated from:

```sh
git ls-tree -r --name-only ecd9570 -- tests | rg '^tests/test_unit_.*\.sla$' | sort
```

Evidence refreshed on 2026-07-12:

- Historical membership: 69 files.
- Current `tests/test_unit_*.sla` membership: 134 files.
- Historical files missing from the current tree: 0.
- Current files added since the historical baseline: 65.
- The current strict local direct-SAB no-fallback sweep passed 134/134.
- The current installed/dev-dispatched strict direct-SAB no-fallback sweep passed 134/134.
- Therefore every historical member is present and passed in both sweeps: 69/69.

Comparison command:

```sh
comm -23 /tmp/sla-historical-69.txt /tmp/sla-current-unit.txt
```

## Members

- `tests/test_unit_array_direct.sla`
- `tests/test_unit_array_struct_field_cleanup.sla`
- `tests/test_unit_arrays.sla`
- `tests/test_unit_assign_move_cleanup.sla`
- `tests/test_unit_async_await.sla`
- `tests/test_unit_basic.sla`
- `tests/test_unit_blank_identifier.sla`
- `tests/test_unit_boolean_logic.sla`
- `tests/test_unit_borrow_direct.sla`
- `tests/test_unit_borrow_temp_release_order.sla`
- `tests/test_unit_cell_bool.sla`
- `tests/test_unit_closures.sla`
- `tests/test_unit_derive_component.sla`
- `tests/test_unit_derive_semantics.sla`
- `tests/test_unit_dyn_borrow_arg.sla`
- `tests/test_unit_enum_match.sla`
- `tests/test_unit_expand_tuple_macro.sla`
- `tests/test_unit_field_array_cleanup.sla`
- `tests/test_unit_field_assign_move_cleanup.sla`
- `tests/test_unit_field_compare_and_nested_len.sla`
- `tests/test_unit_fn_ptr_value.sla`
- `tests/test_unit_for_in_protocol.sla`
- `tests/test_unit_generic_for_in_protocol.sla`
- `tests/test_unit_generics.sla`
- `tests/test_unit_global_const_call_arg_cleanup.sla`
- `tests/test_unit_if_else_expr.sla`
- `tests/test_unit_impl_static_methods.sla`
- `tests/test_unit_imported_fs_exists_direct.sla`
- `tests/test_unit_imported_fs_read_direct.sla`
- `tests/test_unit_imported_json_direct.sla`
- `tests/test_unit_imported_json_string_direct.sla`
- `tests/test_unit_imported_json_struct_direct.sla`
- `tests/test_unit_math.sla`
- `tests/test_unit_move_direct.sla`
- `tests/test_unit_nested_generic_close.sla`
- `tests/test_unit_numeric_casts.sla`
- `tests/test_unit_option_direct.sla`
- `tests/test_unit_option_methods.sla`
- `tests/test_unit_overload_add.sla`
- `tests/test_unit_panic.sla`
- `tests/test_unit_pkgjson_codegen.sla`
- `tests/test_unit_rc_dyn_trait.sla`
- `tests/test_unit_refcell_struct_payload.sla`
- `tests/test_unit_result_direct.sla`
- `tests/test_unit_sets.sla`
- `tests/test_unit_sla_import.sla`
- `tests/test_unit_sla_import_nested_contract.sla`
- `tests/test_unit_sla_import_sa_std_output_path.sla`
- `tests/test_unit_sla_import_wildcard.sla`
- `tests/test_unit_sla_import_wildcard_bare.sla`
- `tests/test_unit_smart_pointer_struct_field_cleanup.sla`
- `tests/test_unit_spaceship_cmp.sla`
- `tests/test_unit_std_import.sla`
- `tests/test_unit_struct_field_array_loop.sla`
- `tests/test_unit_struct_field_copy_not_move.sla`
- `tests/test_unit_struct_update.sla`
- `tests/test_unit_ternary_expr.sla`
- `tests/test_unit_top_level_numeric_const.sla`
- `tests/test_unit_trait_static_dispatch.sla`
- `tests/test_unit_tuples.sla`
- `tests/test_unit_type_alias_flattening.sla`
- `tests/test_unit_user_macro_direct.sla`
- `tests/test_unit_using_static_extension.sla`
- `tests/test_unit_var_comprehensive.sla`
- `tests/test_unit_var_phase1.sla`
- `tests/test_unit_vec_index_assign.sla`
- `tests/test_unit_vec_index_direct.sla`
- `tests/test_unit_vec_len_direct.sla`
- `tests/test_unit_vec_remove_direct.sla`

