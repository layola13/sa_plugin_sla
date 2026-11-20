# Feature Request: Tuple / ParamSet Expansion Capability

> This is the English counterpart of the Chinese document [Tuple / ParamSet 展开能力 feature request](./tuple_paramset_expansion_feature_request_cn.md).

Status: the first-phase baseline has been implemented and verified. While catching up with Bevy ECS `ParamSet` tuple parity, the downstream `sla_ecs` has already exposed that hand-written width expansion is unsustainable: the ordinary `TableErasedWorld` has already been written out to 7 groups of disjoint pair-mut queries, the relationship wrapper likewise to 7 groups, and the observer wrapper to 6 groups. Continuing to hand-write up to Bevy's current limit of 8 can patch the hole in the short term, but it produces large amounts of duplicated SLA source code and SAB compilation pressure; if 16, 32, or 100 groups are needed in the future, the same pattern will become completely unmanageable.

Update 2026-07-07: the compiler's existing `@expand_tuple(min, max, P)` has been completed with the ability for "the current type-item placeholder to follow the declaration prefix"; templates can now directly write `$P` instead of being restricted to a hardcoded `$T`. A new `tests/test_unit_expand_tuple_paramset.sla` serves as the ParamSet baseline, covering struct/constructor expansion at widths 1/2/3, expanded types entering function-pointer runners, and sequential writeback. This phase introduced no new `P...` / `@for_each_index` syntax; remaining syntax sugar, expansion-index diagnostics, and width 8/16 stress tests remain follow-up work.

This document records only a feature request at the SLA compiler / language layer; it does not require continuing to pile hand-written expansions into `sla_ecs`, nor does it modify SLA compiler source code.

## Background

Because Rust has no stable variadic generics, Bevy ECS uses macro enumeration to implement `ParamSet` tuples:

```rust
// bevy/crates/bevy_ecs/src/system/system_param.rs
all_tuples_enumerated!(impl_param_set, 1, 8, P, p);
```

This means Bevy's official API supports `ParamSet<(P0, ..., P7)>`, but it does not mean business code should write 8 system parameters in bulk. In practice 2 to 4 are more common, and 8 is the API upper limit covering complex systems. To align behavior, `sla_ecs` currently can only write the following explicitly by hand:

- `TableErasedSevenPairMutParamSet<...>` struct
- `table_erased_*_seven_pair_mut_param_set(...)` constructors
- `table_erased_run_seven_pair_mut_param_set_system(...)` runner
- `table_erased_run_seven_pair_mut_param_set_system_auto(...)` runner
- Three sets of ordinary / relationship / observer routing and tests

These code shapes are highly mechanical and carry little business information, but they significantly amplify source code, SAB IR, and cleanup/verifier pressure. Previously `sla_ecs` also had generated `.test.sa` files accumulating to millions of lines, slowing repository operations; it has since switched to prohibiting reliance on generated-SA as completion evidence.

## Requirement Goals

What is needed is an SLA language- or compiler-layer capability to express declaratively "expand the same template over a tuple / parameter list of width N", and let the SAB/default backend handle such structures directly, avoiding hand-written or persisted huge generated source in downstream projects.

Core goals:

- Support index-based generic tuple / parameter list expansion, covering at least Bevy's current `1..=8` limit.
- Support raising the limit in the future, e.g. `1..=16`, `1..=32`, without requiring downstream copy-paste of business code.
- Expansion output should be handled inside the compiler; downstream should not be required to commit or retain `.test.sa` / large generated-SA files.
- The SAB backend must be able to keep function pointers, generic instances, aggregate field cleanup, and move/drop state correct after expansion.
- Error locations should point back to the template source position and the expansion index, rather than only giving line numbers in a large `.sab`.

## Proposed Semantics

The specific syntax can be designed by the compiler side, but capability-wise it is recommended to cover the following patterns.

### 1. tuple/parameter-group Declaration Expansion

It should be possible to express "one ParamSet containing N query fields":

```sla
@expand_tuple_width(1, 8, P, p)
struct ParamSet<P...> {
    @for_each_index(i in P)
    p{i}: Query<P{i}>,
}
```

Equivalent to writing by hand:

```sla
struct ParamSet2<P0, P1> {
    p0: Query<P0>,
    p1: Query<P1>,
}

struct ParamSet3<P0, P1, P2> {
    p0: Query<P0>,
    p1: Query<P1>,
    p2: Query<P2>,
}
```

The syntax here is only illustrative; the point is that the compiler must understand "width parameters" and "generating fields/generics/arguments by index".

### 2. Constructor Expansion

It should be possible to express constructors filling in fields by index:

```sla
@expand_tuple_width(1, 8, P, p)
fn param_set<P...>(@for_each_index(i in P) p{i}: Query<P{i}>) -> ParamSet<P...> {
    return ParamSet<P...> {
        @for_each_index(i in P) p{i}: p{i},
    };
}
```

### 3. Runner Expansion

`sla_ecs`'s biggest current pain is the runner's repeated query construction and writeback. It should be possible to express:

```sla
@expand_tuple_width(1, 8, Pair, pair)
fn run_pair_mut_param_set<Pair...>(world: World, run: fn(ParamSet<Pair...>) -> ParamSet<Pair...>) -> World {
    @for_each_index(i in Pair)
    let q{i} = world_query_pair_mut<Pair{i}.A, Pair{i}.B>(world, pair{i}.first_type_id, pair{i}.second_type_id);

    let p0 = param_set<Pair...>(@for_each_index(i in Pair) q{i});
    let p1 = run(p0);

    @fold(world as w, i in Pair)
    w = apply_pair_mut_updates<Pair{i}.A, Pair{i}.B>(w, p1.q{i});

    return w;
}
```

Such notation requires compiler support for:

- Expanding `let` local variables.
- Expanding function parameters and generic arguments.
- Expanding struct literal fields.
- Expanding sequential folds, ensuring stable writeback order.

## Minimal Downstream Example

Below is an SLA-style example that can serve as a minimal compiler test, avoiding dependence on the full `sla_ecs`:

```sla
struct Query<T> { value: T }

struct Pos { x: i32 }
struct Vel { x: i32 }
struct Marker { value: i32 }

@expand_tuple_width(1, 3, P, p)
struct ParamSet<P...> {
    @for_each_index(i in P)
    p{i}: Query<P{i}>,
}

@expand_tuple_width(1, 3, P, p)
fn param_set<P...>(@for_each_index(i in P) p{i}: Query<P{i}>) -> ParamSet<P...> {
    return ParamSet<P...> { @for_each_index(i in P) p{i}: p{i} };
}

fn use_two(param: ParamSet<Pos, Vel>) -> ParamSet<Pos, Vel> {
    param.p0.value.x = param.p0.value.x + 1;
    param.p1.value.x = param.p1.value.x + 2;
    return param_set<Pos, Vel>(param.p0, param.p1);
}

@test "expanded tuple param set width two"() {
    let p = param_set<Pos, Vel>(Query<Pos> { value: Pos { x: 10 } }, Query<Vel> { value: Vel { x: 20 } });
    let r = use_two(p);
    if r.p0.value.x != 11 { panic(91001); };
    if r.p1.value.x != 22 { panic(91002); };
}
```

## Unit Test Recommendations

On the compiler side it is recommended to add at least the following tests, all preferentially verified with the default/SAB backend and not using generated-SA as completion evidence.

### Test 1: Width 1/2/3 Generate Structs and Constructors

Status: already covered with the existing `@expand_tuple` syntax. Test file: `tests/test_unit_expand_tuple_paramset.sla`.

Goal: prove that generic parameters, fields, constructor arguments, and struct literal fields can all be expanded by width.

Assertions:

- `ParamSet<Pos>` can access `p0`.
- `ParamSet<Pos, Vel>` can access `p0`, `p1`.
- `ParamSet<Pos, Vel, Marker>` can access `p0`, `p1`, `p2`.

### Test 2: Expanded Function Pointer Parameters

Status: already covered with the existing `@expand_tuple` syntax. This test also fixed an issue where direct-SAB's exit cleanup for fn-ptr parameters only performed an internal consumed marking without emitting a verifier-visible `move_`.

Goal: prove that an expanded `ParamSet<P...>` can serve as a function-pointer argument and return value.

Example:

```sla
fn run_param_set<P...>(param: ParamSet<P...>, run: fn(ParamSet<P...>) -> ParamSet<P...>) -> ParamSet<P...> {
    return run(param);
}
```

Assertion: after passing in `fn use_two(ParamSet<Pos, Vel>) -> ParamSet<Pos, Vel>`, the SAB call target is correct and cleanup does not leak.

### Test 3: Sequential fold Writeback

Status: the sequential writeback baseline is already covered. The current test uses a hand-written concrete `write_three` to verify that an expanded ParamSet's fields write back stably in order `0, 1, 2`; the `@fold` syntax inside templates is still unimplemented.

Goal: prove that sequential writeback in expanded code is stable and cannot be reordered by concurrency or optimization.

Example:

```sla
@for_each_index(i in P)
state = write_slot(state, i, param.p{i}.value);
```

Assertion: the writeback log order is `0, 1, 2, ...`.

### Test 4: Error Location Includes Expansion Index

Status: not implemented. The current `@expand_tuple` is still source-level expansion; diagnostics can land on expanded source lines, but there is no dedicated reporting of template width and current index.

Goal: when a type error occurs inside an expansion template, the diagnostic can point to the template source and the specific expansion index.

Example: induce an error on `p{i}.missing_field`.

Expected error to include:

- Template source file line and column.
- Expansion width.
- Current `i` value.

### Test 5: Upper-Limit Stress Test Without Persisting generated-SA

Status: not implemented. The current baseline only covers widths 1/2/3; width 8/16 stress and independence from generated-SA files still need separate later verification.

Goal: expansions at width 8 and width 16 can be compile-tested through SAB/default, without generating or requiring committing `.test.sa`.

Assertions:

- `sa sla test tests/test_tuple_expansion.sla --trace-panic` passes.
- After the test, no new tracked or persistently depended-upon `*.test.sa` exists in the repository.

## 2026-07-07 First-Phase Verification

Implementation content:

- `src/source_expand.zig`: for `@expand_tuple(min, max, P)`, the current type-item placeholder follows the declaration prefix; `$P` expands to `P0`, `P1`, etc. within `@each(P)` / `@join(P, ...)`.
- `src/sab_codegen.zig`: function-pointer parameters now emit a verifier-visible `move_` during function-exit cleanup, avoiding the `run` parameter remaining Active after an expanded runner's `run(param)`.
- `tests/test_unit_expand_tuple_paramset.sla`: new minimal ParamSet baseline.

Verification commands:

```bash
zig test src/source_expand.zig --test-filter "expand tuple"
zig build --summary all
./zig-out/bin/sla-local-cli sla test tests/test_unit_expand_tuple_paramset.sla --test-backend sa --trace-panic
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_expand_tuple_paramset.sla --test-backend sab --trace-panic
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_fn_ptr_value.sla --test-backend sab --trace-panic
./zig-out/bin/sla-local-cli sla sab build tests/test_unit_expand_tuple_paramset.sla --out /tmp/expand_tuple_paramset.sab
./zig-out/bin/sla-local-cli sla sab disasm /tmp/expand_tuple_paramset.sab --out /tmp/expand_tuple_paramset.disasm.sa
```

Results:

- `source_expand` focused tests 4/4 passing.
- ParamSet fixture: SA 3/3, direct-SAB 3/3 passing.
- Existing fn-ptr direct-SAB fixture: 11/11 passing.
- Disassembly of `run_expanded_param_set2<Pos, Vel>` confirms a `move_` cleanup of the fn-ptr parameter after `call_indirect`:

```text
call_indirect r243,"tmp_166","sla__run_expanded_param_set2_Pos_Vel__param_0_param"
move_ r242
move_ r241
move_ r240
return_ r243
```

## `sla_ecs` Acceptance Scenarios

Once this feature is complete, `sla_ecs` should be able to gradually replace its current hand-written:

- `TableErasedTwoPairMutParamSet` through `TableErasedSevenPairMutParamSet`
- `TableErasedRelationshipTwoPairMutParamSet` through `TableErasedRelationshipSevenPairMutParamSet`
- `TableErasedObserverTwoPairMutParamSet` through `TableErasedObserverSixPairMutParamSet`

with a single template or a small number of template declarations, and extend to Bevy's current limit of 8. Acceptance commands preferentially use the default/SAB multithreaded path:

```bash
cd /home/vscode/projects/sla_ecs
timeout 240s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased_relationship.sla --trace-panic
timeout 240s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased_observer.sla --trace-panic
```

The ordinary `lib/system_param_table_erased.sla` currently has a separate SAB cleanup issue recorded in `docs/sab_system_param_removed_components_memoryleak_issue_cn.md`; the tuple expansion feature should not mask that cleanup problem, nor should it make the expansion capability depend on the generated-SA path.

## Non-Goals

- No requirement to implement arbitrary infinite variadic generics from the start.
- No requirement for business code to actually use 100 system params.
- No requirement to change the judgment of Bevy parity's API upper limit; downstream can continue targeting Bevy's current `1..=8`.
- No requirement for the SLA compiler to directly understand ECS semantics; only a generic tuple/parameter-list expansion mechanism is needed here.

## Priority Recommendation

Priority: High.

Reason: continuing to hand-write tuple limit 8 in `sla_ecs` is low-value repetitive labor that increases SAB compilation pressure and maintenance cost. Once the language/compiler layer has a declarative expansion capability, repetitive structures such as ECS, query data, system params, tuple filters, AnyOf, bundle tuples, and schedule tuples can all reuse the same mechanism.
