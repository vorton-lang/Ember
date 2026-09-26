// builtins.ring — Combined translation of builtins-core.ts + builtins-hof.ts
// Registers built-in effects, types, traits, and HOF intrinsics into TypeEnv.

use types::{Type, Effect, EffectRow, StructField, EnumVariant,
    INT, STR, BOOL, UNIT, NEVER, EMPTY_ROW,
    BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET, BUILTIN_OPTION, BUILTIN_CELL,
    make_option_type, make_map_type}
use env::{TypeEnv, TypeScheme, SchemeBound, StructDef, EnumDef,
    EffectDef, EffectOpDef, BuiltInKind, TraitDef, TraitMethodDef, ImplEntry, mono, add_impl}

// ============================================================
// Struct for open_row return value
// ============================================================

struct OpenRow {
    eff: EffectRow,
    tail_id: Int
}

// ============================================================
// Helper: get or create a method map for a type in impl_methods
// ============================================================

pub fn get_or_create_methods(mut env: TypeEnv, type_name: Str) -> Map<Str, TypeScheme> {
    match env.trait_reg.impl_methods.get(type_name) {
        some(m) => m,
        none => {
            let m: Map<Str, TypeScheme> = map_new()
            env.trait_reg.impl_methods.insert(type_name, m)
            m
        }
    }
}

// ============================================================
// Helper: create an open effect row (for HOF effect polymorphism)
// ============================================================

fn open_row(mut env: TypeEnv) -> OpenRow {
    let tail_id = env.fresh_var_id()
    OpenRow {
        eff: EffectRow { effects: [], tail: some(tail_id) },
        tail_id: tail_id
    }
}

// ============================================================
// Helper: make a List<T> struct type from a type variable
// ============================================================

fn make_list_struct(t: Type) -> Type {
    Type::StructType { name: BUILTIN_LIST, type_params: [t], fields: [] }
}

// ============================================================
// Helper: make a Set<T> struct type from a type variable
// ============================================================

fn make_set_struct(t: Type) -> Type {
    Type::StructType { name: BUILTIN_SET, type_params: [t], fields: [] }
}

// ============================================================
// Main entry point: register all builtins
// ============================================================

pub fn register_builtins(mut env: TypeEnv) {
    register_effects(env)
    register_cell(env)
    register_option(env)
    register_eq_trait(env)
    register_option_eq(env)
    register_clone_trait(env)
    register_option_clone(env)
    register_ord_trait(env)
    register_debug_trait(env)
    register_option_debug(env)
    register_mut_methods(env)
}

// ============================================================
// Register built-in mut methods (mutating method names per type)
// ============================================================

fn register_mut_methods(mut env: TypeEnv) {
    let mut list_mut: Set<Str> = set_new()
    for m in ["push", "pop", "set", "extend", "reverse", "sort", "shift", "clear", "sort_by"] {
        list_mut.insert(m)
    }
    env.trait_reg.mut_methods.insert("List", list_mut)

    let mut map_mut: Set<Str> = set_new()
    for m in ["insert", "remove", "clear"] {
        map_mut.insert(m)
    }
    env.trait_reg.mut_methods.insert("Map", map_mut)

    let mut set_mut: Set<Str> = set_new()
    for m in ["insert", "remove", "clear"] {
        set_mut.insert(m)
    }
    env.trait_reg.mut_methods.insert("Set", set_mut)
}

// Main entry point: register all HOF intrinsics
pub fn register_hof_intrinsics(mut env: TypeEnv) {
    register_list_hof(env)
    register_map_hof(env)
    register_set_hof(env)
    register_option_hof(env)
}

// ============================================================
// register_effects: "io" and "fail" built-in effects
// ============================================================

fn register_effects(mut env: TypeEnv) {
    // io effect
    env.types.effects.insert("io", EffectDef {
        name: "io",
        type_params: [],
        type_param_vars: [],
        ops: [
            EffectOpDef { name: "read", params: [STR], return_type: STR, has_default: false },
            EffectOpDef { name: "write", params: [STR, STR], return_type: UNIT, has_default: false }
        ],
        built_in_kind: some(BuiltInKind::BkIo),
        all_have_defaults: false
    })

    // fail effect
    let fail_t_id = env.fresh_var_id()
    let fail_t = Type::TypeVar { id: fail_t_id, name: none }
    env.types.effects.insert("fail", EffectDef {
        name: "fail",
        type_params: ["E"],
        type_param_vars: [fail_t_id],
        ops: [
            EffectOpDef { name: "raise", params: [fail_t], return_type: NEVER, has_default: false }
        ],
        built_in_kind: some(BuiltInKind::BkFail),
        all_have_defaults: false
    })
}

// ============================================================
// register_cell: Cell<T> struct + get/set/update methods
// ============================================================

fn register_cell(mut env: TypeEnv) {
    // Register Cell struct definition
    let cell_t_id = env.fresh_var_id()
    let cell_t = Type::TypeVar { id: cell_t_id, name: none }
    env.types.structs.insert(BUILTIN_CELL, StructDef {
        name: BUILTIN_CELL,
        type_params: ["T"],
        type_param_vars: [cell_t_id],
        fields: [StructField { name: "value", ty: cell_t, is_pub: true }],
        is_extern: false
    })

    // Register Cell constructor function
    let ctor_t_id = env.fresh_var_id()
    let ctor_t = Type::TypeVar { id: ctor_t_id, name: none }
    let ctor_ret = Type::StructType {
        name: BUILTIN_CELL,
        type_params: [ctor_t],
        fields: [StructField { name: "value", ty: ctor_t, is_pub: true }]
    }
    env.bind(BUILTIN_CELL, TypeScheme {
        ty: Type::FnType { params: [ctor_t], return_type: ctor_ret, effects: EMPTY_ROW },
        type_vars: [ctor_t_id],
        bounds: [],
        def_id: none
    })

    // Methods: get, set, update
    let m_t_id = env.fresh_var_id()
    let m_t = Type::TypeVar { id: m_t_id, name: none }
    let mut_row = EffectRow { effects: [Effect::MutEffect { state_type: m_t }], tail: none }
    let self_type = Type::StructType {
        name: BUILTIN_CELL,
        type_params: [m_t],
        fields: [StructField { name: "value", ty: m_t, is_pub: true }]
    }

    let mut methods: Map<Str, TypeScheme> = map_new()

    // get: (Cell<T>) -> T / mut
    methods.insert("get", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: m_t, effects: mut_row },
        type_vars: [m_t_id],
        bounds: [],
        def_id: none
    })

    // set: (Cell<T>, T) -> () / mut
    methods.insert("set", TypeScheme {
        ty: Type::FnType { params: [self_type, m_t], return_type: UNIT, effects: mut_row },
        type_vars: [m_t_id],
        bounds: [],
        def_id: none
    })

    // update: (Cell<T>, (T) -> T) -> () / mut
    let update_cb = Type::FnType { params: [m_t], return_type: m_t, effects: EMPTY_ROW }
    methods.insert("update", TypeScheme {
        ty: Type::FnType { params: [self_type, update_cb], return_type: UNIT, effects: mut_row },
        type_vars: [m_t_id],
        bounds: [],
        def_id: none
    })

    env.trait_reg.impl_methods.insert(BUILTIN_CELL, methods)
}

// ============================================================
// register_option: Option<T> enum + some/none constructors + methods
// ============================================================

fn register_option(mut env: TypeEnv) {
    // Register Option enum definition
    let option_t_id = env.fresh_var_id()
    let option_t = Type::TypeVar { id: option_t_id, name: none }
    let mut option_vi: Map<Str, Int> = map_new()
    option_vi.insert("some", 0)
    option_vi.insert("none", 1)
    env.types.enums.insert(BUILTIN_OPTION, EnumDef {
        name: BUILTIN_OPTION,
        type_params: ["T"],
        type_param_vars: [option_t_id],
        variants: [
            EnumVariant { name: "some", fields: [option_t], field_names: none },
            EnumVariant { name: "none", fields: [], field_names: none }
        ],
        variant_index: option_vi
    })

    env.types.variant_to_enum.insert("some", BUILTIN_OPTION)
    env.types.variant_to_enum.insert("none", BUILTIN_OPTION)

    // some constructor: (T) -> Option<T>
    let some_t_id = env.fresh_var_id()
    let some_t = Type::TypeVar { id: some_t_id, name: none }
    env.bind("some", TypeScheme {
        ty: Type::FnType { params: [some_t], return_type: make_option_type(some_t), effects: EMPTY_ROW },
        type_vars: [some_t_id],
        bounds: [],
        def_id: none
    })

    // none: Option<T> (not a function, just a polymorphic value)
    let none_t_id = env.fresh_var_id()
    let none_t = Type::TypeVar { id: none_t_id, name: none }
    env.bind("none", TypeScheme {
        ty: make_option_type(none_t),
        type_vars: [none_t_id],
        bounds: [],
        def_id: none
    })

    // Option methods: is_some, is_none, unwrap_or
    let mut methods = get_or_create_methods(env, BUILTIN_OPTION)

    let t_id = env.fresh_var_id()
    let t = Type::TypeVar { id: t_id, name: none }
    let self_type = make_option_type(t)

    methods.insert("is_some", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: BOOL, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    methods.insert("is_none", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: BOOL, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    methods.insert("unwrap_or", TypeScheme {
        ty: Type::FnType { params: [self_type, t], return_type: t, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    methods.insert("unwrap", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: t, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    let e_id = env.fresh_var_id()
    let e = Type::TypeVar { id: e_id, name: none }
    let self_type2 = make_option_type(Type::TypeVar { id: t_id, name: none })
    let fail_eff = Effect::FailEffect { error_type: e }
    methods.insert("to_fail", TypeScheme {
        ty: Type::FnType { params: [self_type2, e], return_type: Type::TypeVar { id: t_id, name: none }, effects: EffectRow { effects: [fail_eff], tail: none } },
        type_vars: [t_id, e_id],
        bounds: [],
        def_id: none
    })
}

// ============================================================
// register_eq_trait: Eq trait + primitive impls
// ============================================================

fn register_eq_trait(mut env: TypeEnv) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let eq_fn = Type::FnType { params: [self_var, self_var], return_type: BOOL, effects: EMPTY_ROW }
    let ne_fn = Type::FnType { params: [self_var, self_var], return_type: BOOL, effects: EMPTY_ROW }

    env.trait_reg.traits.insert("Eq", TraitDef {
        name: "Eq",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "eq", ty: eq_fn, has_default: false, param_mutabilities: [false, false], method_type_params: [] },
            TraitMethodDef { name: "ne", ty: ne_fn, has_default: true, param_mutabilities: [false, false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })

    // Register Eq impls for primitive types
    for prim in ["Int", "Float", "Str", "Bool"] {
        add_impl(env.trait_reg, ImplEntry {
            trait_name: "Eq",
            target_type_name: prim,
            type_params: [],
            method_names: ["eq", "ne"],
            assoc_types: map_new()
        })
    }
}

// ============================================================
// register_option_eq: Option<T: Eq> Eq impl
// ============================================================

fn register_option_eq(mut env: TypeEnv) {
    let t_id = env.fresh_var_id()
    let t = Type::TypeVar { id: t_id, name: none }
    let opt = make_option_type(t)

    let mut methods = get_or_create_methods(env, BUILTIN_OPTION)

    let eq_bounds = [SchemeBound { type_var: t_id, trait_name: "Eq", assoc_constraints: [] }]

    methods.insert("eq", TypeScheme {
        ty: Type::FnType { params: [opt, opt], return_type: BOOL, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: eq_bounds,
        def_id: none
    })

    methods.insert("ne", TypeScheme {
        ty: Type::FnType { params: [opt, opt], return_type: BOOL, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [SchemeBound { type_var: t_id, trait_name: "Eq", assoc_constraints: [] }],
        def_id: none
    })

    add_impl(env.trait_reg, ImplEntry {
        trait_name: "Eq",
        target_type_name: BUILTIN_OPTION,
        type_params: ["T"],
        method_names: ["eq", "ne"],
        assoc_types: map_new()
    })
}

// ============================================================
// register_clone_trait: Clone trait + primitive + collection impls
// ============================================================

fn register_clone_trait(mut env: TypeEnv) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let clone_fn = Type::FnType { params: [self_var], return_type: self_var, effects: EMPTY_ROW }

    env.trait_reg.traits.insert("Clone", TraitDef {
        name: "Clone",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "clone", ty: clone_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })

    // Primitive impls
    for prim in ["Int", "Float", "Str", "Bool"] {
        add_impl(env.trait_reg, ImplEntry {
            trait_name: "Clone",
            target_type_name: prim,
            type_params: [],
            method_names: ["clone"],
            assoc_types: map_new()
        })
    }

    // Collection impls
    for coll in ["List", "Map", "Set"] {
        add_impl(env.trait_reg, ImplEntry {
            trait_name: "Clone",
            target_type_name: coll,
            type_params: [],
            method_names: ["clone"],
            assoc_types: map_new()
        })
    }
}

// ============================================================
// register_option_clone: Option<T: Clone> Clone impl
// ============================================================

fn register_option_clone(mut env: TypeEnv) {
    let t_id = env.fresh_var_id()
    let t = Type::TypeVar { id: t_id, name: none }
    let opt = make_option_type(t)

    let mut methods = get_or_create_methods(env, BUILTIN_OPTION)

    methods.insert("clone", TypeScheme {
        ty: Type::FnType { params: [opt], return_type: opt, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [SchemeBound { type_var: t_id, trait_name: "Clone", assoc_constraints: [] }],
        def_id: none
    })

    add_impl(env.trait_reg, ImplEntry {
        trait_name: "Clone",
        target_type_name: BUILTIN_OPTION,
        type_params: ["T"],
        method_names: ["clone"],
        assoc_types: map_new()
    })
}

// ============================================================
// register_ord_trait: Ord trait + primitive impls
// ============================================================

fn register_ord_trait(mut env: TypeEnv) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let cmp_fn = Type::FnType { params: [self_var, self_var], return_type: INT, effects: EMPTY_ROW }

    env.trait_reg.traits.insert("Ord", TraitDef {
        name: "Ord",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "cmp", ty: cmp_fn, has_default: false, param_mutabilities: [false, false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })

    for prim in ["Int", "Float", "Str", "Bool"] {
        add_impl(env.trait_reg, ImplEntry {
            trait_name: "Ord",
            target_type_name: prim,
            type_params: [],
            method_names: ["cmp"],
            assoc_types: map_new()
        })
    }
}

// ============================================================
// register_debug_trait: Debug trait + primitive + collection impls
// ============================================================

fn register_debug_trait(mut env: TypeEnv) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let debug_fn = Type::FnType { params: [self_var], return_type: STR, effects: EMPTY_ROW }

    env.trait_reg.traits.insert("Debug", TraitDef {
        name: "Debug",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "debug", ty: debug_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })

    // Primitive impls
    for prim in ["Int", "Float", "Str", "Bool"] {
        add_impl(env.trait_reg, ImplEntry {
            trait_name: "Debug",
            target_type_name: prim,
            type_params: [],
            method_names: ["debug"],
            assoc_types: map_new()
        })
    }

    // List<T: Debug> Debug impl
    let mut t_id = env.fresh_var_id()
    let mut t = Type::TypeVar { id: t_id, name: none }
    let list_self = Type::StructType { name: BUILTIN_LIST, type_params: [t], fields: [] }
    let list_debug_fn = Type::FnType { params: [list_self], return_type: STR, effects: EMPTY_ROW }
    let mut list_methods = get_or_create_methods(env, BUILTIN_LIST)
    list_methods.insert("debug", TypeScheme {
        ty: list_debug_fn,
        type_vars: [t_id],
        bounds: [SchemeBound { type_var: t_id, trait_name: "Debug", assoc_constraints: [] }],
        def_id: none
    })
    add_impl(env.trait_reg, ImplEntry {
        trait_name: "Debug",
        target_type_name: BUILTIN_LIST,
        type_params: ["T"],
        method_names: ["debug"],
        assoc_types: map_new()
    })

    // Map<K, V> Debug impl (no bounds required in TS source)
    let k_id = env.fresh_var_id()
    let k = Type::TypeVar { id: k_id, name: none }
    let v_id = env.fresh_var_id()
    let v = Type::TypeVar { id: v_id, name: none }
    let map_self = make_map_type(k, v)
    let map_debug_fn = Type::FnType { params: [map_self], return_type: STR, effects: EMPTY_ROW }
    let mut map_methods = get_or_create_methods(env, BUILTIN_MAP)
    map_methods.insert("debug", TypeScheme {
        ty: map_debug_fn,
        type_vars: [k_id, v_id],
        bounds: [],
        def_id: none
    })
    add_impl(env.trait_reg, ImplEntry {
        trait_name: "Debug",
        target_type_name: BUILTIN_MAP,
        type_params: ["K", "V"],
        method_names: ["debug"],
        assoc_types: map_new()
    })

    // Set<T> Debug impl (no bounds required in TS source)
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    let set_self = Type::StructType { name: BUILTIN_SET, type_params: [t], fields: [] }
    let set_debug_fn = Type::FnType { params: [set_self], return_type: STR, effects: EMPTY_ROW }
    let mut set_methods = get_or_create_methods(env, BUILTIN_SET)
    set_methods.insert("debug", TypeScheme {
        ty: set_debug_fn,
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })
    add_impl(env.trait_reg, ImplEntry {
        trait_name: "Debug",
        target_type_name: BUILTIN_SET,
        type_params: ["T"],
        method_names: ["debug"],
        assoc_types: map_new()
    })
}

// ============================================================
// register_option_debug: Option<T: Debug> Debug impl
// ============================================================

fn register_option_debug(mut env: TypeEnv) {
    let t_id = env.fresh_var_id()
    let t = Type::TypeVar { id: t_id, name: none }
    let opt = make_option_type(t)

    let mut methods = get_or_create_methods(env, BUILTIN_OPTION)

    methods.insert("debug", TypeScheme {
        ty: Type::FnType { params: [opt], return_type: STR, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [SchemeBound { type_var: t_id, trait_name: "Debug", assoc_constraints: [] }],
        def_id: none
    })

    add_impl(env.trait_reg, ImplEntry {
        trait_name: "Debug",
        target_type_name: BUILTIN_OPTION,
        type_params: ["T"],
        method_names: ["debug"],
        assoc_types: map_new()
    })
}

// ============================================================
// HOF: register_list_hof
// ============================================================

fn register_list_hof(mut env: TypeEnv) {
    let mut methods = get_or_create_methods(env, BUILTIN_LIST)

    // map: (List<T>, (T) -> U / e) -> List<U> / e
    let mut t_id = env.fresh_var_id()
    let mut t = Type::TypeVar { id: t_id, name: none }
    let mut u_id = env.fresh_var_id()
    let mut u = Type::TypeVar { id: u_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType { params: [t], return_type: u, effects: orow.eff }
    methods.insert("map", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(u), effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // filter: (List<T>, (T) -> Bool / e) -> List<T> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("filter", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(t), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // flat_map: (List<T>, (T) -> List<U> / e) -> List<U> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: make_list_struct(u), effects: orow.eff }
    methods.insert("flat_map", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(u), effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // fold: (List<T>, U, (U, T) -> U / e) -> U / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [u, t], return_type: u, effects: orow.eff }
    methods.insert("fold", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), u, cb], return_type: u, effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // any: (List<T>, (T) -> Bool / e) -> Bool / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("any", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: BOOL, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // all: (List<T>, (T) -> Bool / e) -> Bool / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("all", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: BOOL, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // find: (List<T>, (T) -> Bool / e) -> Option<T> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("find", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_option_type(t), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // find_index: (List<T>, (T) -> Bool / e) -> Option<Int> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("find_index", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_option_type(INT), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // sort_by: (List<T>, (T, T) -> Int / e) -> () / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t, t], return_type: INT, effects: orow.eff }
    methods.insert("sort_by", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: UNIT, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
}

// ============================================================
// HOF: register_map_hof
// ============================================================

fn register_map_hof(mut env: TypeEnv) {
    let mut methods = get_or_create_methods(env, BUILTIN_MAP)

    // map_values: (Map<K,V>, (V) -> U / e) -> Map<K,U> / e
    let mut k_id = env.fresh_var_id()
    let mut k = Type::TypeVar { id: k_id, name: none }
    let mut v_id = env.fresh_var_id()
    let mut v = Type::TypeVar { id: v_id, name: none }
    let mut u_id = env.fresh_var_id()
    let mut u = Type::TypeVar { id: u_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType { params: [v], return_type: u, effects: orow.eff }
    methods.insert("map_values", TypeScheme {
        ty: Type::FnType { params: [make_map_type(k, v), cb], return_type: make_map_type(k, u), effects: orow.eff },
        type_vars: [k_id, v_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // filter: (Map<K,V>, (K, V) -> Bool / e) -> Map<K,V> / e
    k_id = env.fresh_var_id()
    k = Type::TypeVar { id: k_id, name: none }
    v_id = env.fresh_var_id()
    v = Type::TypeVar { id: v_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [k, v], return_type: BOOL, effects: orow.eff }
    methods.insert("filter", TypeScheme {
        ty: Type::FnType { params: [make_map_type(k, v), cb], return_type: make_map_type(k, v), effects: orow.eff },
        type_vars: [k_id, v_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // fold: (Map<K,V>, U, (U, K, V) -> U / e) -> U / e
    k_id = env.fresh_var_id()
    k = Type::TypeVar { id: k_id, name: none }
    v_id = env.fresh_var_id()
    v = Type::TypeVar { id: v_id, name: none }
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [u, k, v], return_type: u, effects: orow.eff }
    methods.insert("fold", TypeScheme {
        ty: Type::FnType { params: [make_map_type(k, v), u, cb], return_type: u, effects: orow.eff },
        type_vars: [k_id, v_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // any: (Map<K,V>, (K, V) -> Bool / e) -> Bool / e
    k_id = env.fresh_var_id()
    k = Type::TypeVar { id: k_id, name: none }
    v_id = env.fresh_var_id()
    v = Type::TypeVar { id: v_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [k, v], return_type: BOOL, effects: orow.eff }
    methods.insert("any", TypeScheme {
        ty: Type::FnType { params: [make_map_type(k, v), cb], return_type: BOOL, effects: orow.eff },
        type_vars: [k_id, v_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
}

// ============================================================
// HOF: register_set_hof
// ============================================================

fn register_set_hof(mut env: TypeEnv) {
    let mut methods = get_or_create_methods(env, BUILTIN_SET)

    // filter: (Set<T>, (T) -> Bool / e) -> Set<T> / e
    let mut t_id = env.fresh_var_id()
    let mut t = Type::TypeVar { id: t_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("filter", TypeScheme {
        ty: Type::FnType { params: [make_set_struct(t), cb], return_type: make_set_struct(t), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // fold: (Set<T>, U, (U, T) -> U / e) -> U / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    let u_id = env.fresh_var_id()
    let u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [u, t], return_type: u, effects: orow.eff }
    methods.insert("fold", TypeScheme {
        ty: Type::FnType { params: [make_set_struct(t), u, cb], return_type: u, effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // any: (Set<T>, (T) -> Bool / e) -> Bool / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("any", TypeScheme {
        ty: Type::FnType { params: [make_set_struct(t), cb], return_type: BOOL, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // all: (Set<T>, (T) -> Bool / e) -> Bool / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("all", TypeScheme {
        ty: Type::FnType { params: [make_set_struct(t), cb], return_type: BOOL, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
}

// ============================================================
// HOF: register_option_hof
// ============================================================

fn register_option_hof(mut env: TypeEnv) {
    let mut methods = get_or_create_methods(env, BUILTIN_OPTION)

    // map: (Option<T>, (T) -> U / e) -> Option<U> / e
    let mut t_id = env.fresh_var_id()
    let mut t = Type::TypeVar { id: t_id, name: none }
    let mut u_id = env.fresh_var_id()
    let mut u = Type::TypeVar { id: u_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType { params: [t], return_type: u, effects: orow.eff }
    methods.insert("map", TypeScheme {
        ty: Type::FnType { params: [make_option_type(t), cb], return_type: make_option_type(u), effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // and_then: (Option<T>, (T) -> Option<U> / e) -> Option<U> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: make_option_type(u), effects: orow.eff }
    methods.insert("and_then", TypeScheme {
        ty: Type::FnType { params: [make_option_type(t), cb], return_type: make_option_type(u), effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // unwrap_or_else: (Option<T>, () -> T / e) -> T / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [], return_type: t, effects: orow.eff }
    methods.insert("unwrap_or_else", TypeScheme {
        ty: Type::FnType { params: [make_option_type(t), cb], return_type: t, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
}
