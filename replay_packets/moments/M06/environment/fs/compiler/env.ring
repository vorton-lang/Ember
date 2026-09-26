use types::{Type, Effect, EffectRow, StructField, EnumVariant, RecordField, INT, fn_intern_key, struct_intern_key, enum_intern_key, generic_intern_key, record_intern_key, effect_row_intern_key, tuple_intern_key}
use union_find::{UnionFind, uf_find, uf_lookup}
use ast::{Span, EffectExpr, TypeParam}

// ============================================================
// Type Scheme (for let-polymorphism)
// ============================================================

pub struct AssocConstraintEntry {
    pub name: Str,   // "Item"
    pub ty: Type     // the constrained concrete type
}

pub struct SchemeBound {
    pub type_var: Int,
    pub trait_name: Str,
    pub assoc_constraints: List<AssocConstraintEntry>
}

pub struct TypeScheme {
    pub ty: Type,
    pub type_vars: List<Int>,
    pub bounds: List<SchemeBound>,
    pub def_id: Int?
}

// ============================================================
// Struct / Enum / Effect definitions stored in environment
// ============================================================

pub struct StructDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub fields: List<StructField>,
    // True for opaque extern (FFI) types registered as zero-field structs.
    // Carries cross-module via TypeDef::StructDef_ so both the declaring and
    // consuming modules can exclude it from trait derivation (B-074).
    pub is_extern: Bool
}

pub struct EnumDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub variants: List<EnumVariant>,
    pub variant_index: Map<Str, Int>
}

pub fn lookup_variant(def: EnumDef, name: Str) -> EnumVariant? {
    match def.variant_index.get(name) {
        some(idx) => def.variants.get(idx),
        none => none
    }
}

pub struct EffectOpDef {
    pub name: Str,
    pub params: List<Type>,
    pub return_type: Type,
    pub has_default: Bool
}

pub enum BuiltInKind { BkIo, BkFail, BkMut }

pub struct EffectDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub ops: List<EffectOpDef>,
    pub built_in_kind: BuiltInKind?,
    pub all_have_defaults: Bool
}

// ============================================================
// Trait definitions
// ============================================================

pub struct TraitMethodDef {
    pub name: Str,
    pub ty: Type,
    pub has_default: Bool,
    pub param_mutabilities: List<Bool>,
    pub method_type_params: List<TypeParam>
}

pub struct AssocTypeDef {
    pub name: Str,
    pub bounds: List<Str>,        // trait name bounds
    pub default_type: Type?,      // trait-level default value
    pub var_id: Int               // type variable ID used in trait method signatures
}

pub struct TraitDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub methods: List<TraitMethodDef>,
    pub supertraits: List<Str>,
    pub assoc_types: List<AssocTypeDef>
}

pub struct ImplEntry {
    pub trait_name: Str,
    pub target_type_name: Str,
    pub type_params: List<Str>,
    pub method_names: List<Str>,
    pub assoc_types: Map<Str, Type>
}

// ============================================================
// Type alias + function bounds
// ============================================================

pub struct TypeAliasDef {
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub ty: Type
}

pub struct EffectAliasDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub effects: List<EffectExpr>,
    pub span: Span
}

pub struct FnBound {
    pub type_param: Str,
    pub trait_name: Str
}

pub struct SigDef {
    pub name: Str,
    pub members: Map<Str, TypeScheme>,
    pub is_pub: Bool
}

// ============================================================
// Scope
// ============================================================

pub struct Scope {
    pub variables: Map<Str, TypeScheme>
}

// ============================================================
// TypeEnv sub-structs
// ============================================================

pub struct TypeRegistry {
    pub structs: Map<Str, StructDef>,
    pub enums: Map<Str, EnumDef>,
    pub effects: Map<Str, EffectDef>,
    pub variant_to_enum: Map<Str, Str>,
    pub type_aliases: Map<Str, TypeAliasDef>,
    pub sigs: Map<Str, SigDef>,
    pub effect_aliases: Map<Str, EffectAliasDef>
}

pub struct TraitRegistry {
    pub traits: Map<Str, TraitDef>,
    pub trait_impls: Map<Str, List<ImplEntry>>,
    pub impl_methods: Map<Str, Map<Str, TypeScheme>>,
    pub mut_methods: Map<Str, Set<Str>>
}

pub struct ScopeManager {
    pub scopes: List<Scope>,
    pub fn_bounds: Map<Str, List<FnBound>>,
    pub var_bounds: Map<Int, Set<Str>>,
    pub def_spans: Map<Int, Span>,
    pub mutable_vars: Set<Int>,
    pub let_defs: Set<Int>,
    pub mut_param_defs: Set<Int>
}

pub struct IdGen {
    pub next_type_var_id: Int,
    pub next_def_id: Int
}

// ============================================================
// TypeEnv
// ============================================================

pub struct TypeEnv {
    pub types: TypeRegistry,
    pub trait_reg: TraitRegistry,
    pub scope: ScopeManager,
    pub ids: IdGen
}

// ============================================================
// Constructor + helpers
// ============================================================

pub fn mono(ty: Type) -> TypeScheme {
    TypeScheme { ty: ty, type_vars: [], bounds: [], def_id: none }
}

pub fn new_type_env() -> TypeEnv {
    let initial_scope = Scope { variables: map_new() }
    TypeEnv {
        types: TypeRegistry {
            structs: map_new(),
            enums: map_new(),
            effects: map_new(),
            variant_to_enum: map_new(),
            type_aliases: map_new(),
            sigs: map_new(),
            effect_aliases: map_new()
        },
        trait_reg: TraitRegistry {
            traits: map_new(),
            trait_impls: map_new(),
            impl_methods: map_new(),
            mut_methods: map_new()
        },
        scope: ScopeManager {
            scopes: [initial_scope],
            fn_bounds: map_new(),
            var_bounds: map_new(),
            def_spans: map_new(),
            mutable_vars: set_new(),
            let_defs: set_new(),
            mut_param_defs: set_new()
        },
        ids: IdGen {
            next_type_var_id: 0,
            next_def_id: 0
        }
    }
}

// ============================================================
// TypeEnv methods
// ============================================================

impl TypeEnv {
    pub fn current_var_id(self) -> Int { self.ids.next_type_var_id }

    pub fn fresh_var(mut self) -> Type {
        let id = self.ids.next_type_var_id
        self.ids.next_type_var_id = id + 1
        Type::TypeVar { id: id, name: none }
    }

    pub fn fresh_var_id(mut self) -> Int {
        let id = self.ids.next_type_var_id
        self.ids.next_type_var_id = id + 1
        id
    }

    pub fn fresh_def_id(mut self) -> Int {
        let id = self.ids.next_def_id
        self.ids.next_def_id = id + 1
        id
    }

    pub fn push_scope(mut self) {
        self.scope.scopes.push(Scope { variables: map_new() })
    }

    pub fn pop_scope(mut self) {
        if self.scope.scopes.len() <= 1 {
            panic("unreachable: cannot pop global scope")
        }
        self.scope.scopes.pop()
    }

    pub fn bind(mut self, name: Str, scheme: TypeScheme) {
        let s = match scheme.def_id {
            some(_) => scheme,
            none => TypeScheme { ..scheme, def_id: some(self.fresh_def_id()) }
        }
        let idx = self.scope.scopes.len() - 1
        match self.scope.scopes.get(idx) {
            some(scope) => scope.variables.insert(name, s),
            none => panic("unreachable: no current scope")
        }
    }

    pub fn bind_mono(mut self, name: Str, ty: Type) {
        self.bind(name, mono(ty))
    }

    pub fn record_def_span(mut self, def_id: Int, span: Span) {
        self.scope.def_spans.insert(def_id, span)
    }

    pub fn rebind(mut self, name: Str, scheme: TypeScheme) {
        let mut i = self.scope.scopes.len() - 1
        while i >= 0 {
            match self.scope.scopes.get(i) {
                some(scope) => {
                    if scope.variables.contains_key(name) {
                        scope.variables.insert(name, scheme)
                        return
                    }
                },
                none => {}
            }
            i = i - 1
        }
        panic("unreachable: rebind failed — variable '${name}' not found in any scope")
    }

    pub fn lookup(self, name: Str) -> TypeScheme? {
        let mut i = self.scope.scopes.len() - 1
        while i >= 0 {
            let found = match self.scope.scopes.get(i) {
                some(scope) => scope.variables.get(name),
                none => none
            }
            if found.is_some() { return found }
            i = i - 1
        }
        none
    }

    pub fn instantiate(mut self, scheme: TypeScheme) -> Type {
        if scheme.type_vars.len() == 0 { return scheme.ty }
        let mut mapping: Map<Int, Type> = map_new()
        for tv in scheme.type_vars {
            mapping.insert(tv, self.fresh_var())
        }
        for bound in scheme.bounds {
            match mapping.get(bound.type_var) {
                some(fresh) => match fresh {
                    Type::TypeVar { id, .. } => {
                        let mut existing: Set<Str> = match self.scope.var_bounds.get(id) {
                            some(s) => s,
                            none => set_new()
                        }
                        existing.insert(bound.trait_name)
                        self.scope.var_bounds.insert(id, existing)
                    },
                    _ => {}
                },
                none => {}
            }
        }
        apply_subst_map(mapping, scheme.ty)
    }
}

// ============================================================
// trait_impls helpers (Map<Str, List<ImplEntry>> keyed by target_type_name)
// ============================================================

pub fn add_impl(mut reg: TraitRegistry, entry: ImplEntry) {
    match reg.trait_impls.get(entry.target_type_name) {
        some(impls) => impls.push(entry),
        none => {
            let mut list: List<ImplEntry> = []
            list.push(entry)
            reg.trait_impls.insert(entry.target_type_name, list)
        }
    }
}

pub fn has_impl(reg: TraitRegistry, type_name: Str, trait_name: Str) -> Bool {
    match reg.trait_impls.get(type_name) {
        some(impls) => impls.any(fn(i) { i.trait_name == trait_name }),
        none => false
    }
}

pub fn find_impl(reg: TraitRegistry, type_name: Str, trait_name: Str) -> ImplEntry? {
    match reg.trait_impls.get(type_name) {
        some(impls) => impls.find(fn(i) { i.trait_name == trait_name }),
        none => none
    }
}

// ============================================================
// Map-based substitution: apply a local Map<Int, Type> mapping to a type.
// Used for local type parameter instantiation maps (not the global substitution).
// ============================================================

fn chase_type_var_map(subst: Map<Int, Type>, id: Int, depth: Int) -> Type {
    if depth > 100 { return Type::TypeVar { id: id, name: none } }
    match subst.get(id) {
        some(resolved) => match resolved {
            Type::TypeVar { id: next_id, .. } => chase_type_var_map(subst, next_id, depth + 1),
            _ => apply_subst_map(subst, resolved)
        },
        none => Type::TypeVar { id: id, name: none }
    }
}

pub fn apply_subst_map(subst: Map<Int, Type>, t: Type) -> Type {
    match t {
        Type::IntType => t,
        Type::FloatType => t,
        Type::StrType => t,
        Type::BoolType => t,
        Type::UnitType => t,
        Type::NeverType => t,
        Type::AnyType => t,
        Type::TypeVar { id, .. } => chase_type_var_map(subst, id, 0),
        Type::FnType { params, return_type, effects } =>
            Type::FnType {
                params: params.map(fn(p) { apply_subst_map(subst, p) }),
                return_type: apply_subst_map(subst, return_type),
                effects: apply_subst_row_map(subst, effects)
            },
        Type::StructType { name, type_params, fields } =>
            Type::StructType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst_map(subst, p) }),
                fields: fields
            },
        Type::EnumType { name, type_params, variants } =>
            Type::EnumType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst_map(subst, p) }),
                variants: variants
            },
        Type::GenericType { base, args } =>
            Type::GenericType {
                base: apply_subst_map(subst, base),
                args: args.map(fn(a) { apply_subst_map(subst, a) })
            },
        Type::RecordType { fields, tail, tail_name } => {
            let mapped_fields = fields.map(fn(f) {
                RecordField { name: f.name, ty: apply_subst_map(subst, f.ty) }
            })
            match tail {
                some(t_id) => match subst.get(t_id) {
                    some(resolved) => {
                        let chased = apply_subst_map(subst, resolved)
                        match chased {
                            Type::TypeVar { id: new_id, name: new_name } =>
                                Type::RecordType { fields: mapped_fields, tail: some(new_id), tail_name: new_name },
                            Type::RecordType { fields: extra_fields, tail: extra_tail, tail_name: extra_tn } => {
                                let mut all_fields = list_clone(mapped_fields)
                                for ef in extra_fields {
                                    all_fields.push(RecordField { name: ef.name, ty: apply_subst_map(subst, ef.ty) })
                                }
                                Type::RecordType { fields: all_fields, tail: extra_tail, tail_name: extra_tn }
                            },
                            _ => Type::RecordType { fields: mapped_fields, tail: none, tail_name: none }
                        }
                    },
                    none => Type::RecordType { fields: mapped_fields, tail: some(t_id), tail_name: tail_name }
                },
                none => Type::RecordType { fields: mapped_fields, tail: none, tail_name: tail_name }
            }
        },
        Type::EffectRowType { effects, tail } => {
            let row = apply_subst_row_map(subst, EffectRow { effects: effects, tail: tail })
            Type::EffectRowType { effects: row.effects, tail: row.tail }
        },
        Type::TupleType { elements } =>
            Type::TupleType { elements: elements.map(fn(e) { apply_subst_map(subst, e) }) },
        Type::ErrorType => t
    }
}

pub fn apply_subst_effect_map(subst: Map<Int, Type>, e: Effect) -> Effect {
    match e {
        Effect::FailEffect { error_type } =>
            Effect::FailEffect { error_type: apply_subst_map(subst, error_type) },
        Effect::MutEffect { state_type } =>
            Effect::MutEffect { state_type: apply_subst_map(subst, state_type) },
        Effect::CustomEffect { name, type_args } =>
            Effect::CustomEffect { name: name, type_args: type_args.map(fn(a) { apply_subst_map(subst, a) }) },
        _ => e
    }
}

pub fn apply_subst_row_map(subst: Map<Int, Type>, row: EffectRow) -> EffectRow {
    let effects = row.effects.map(fn(e) { apply_subst_effect_map(subst, e) })
    match row.tail {
        some(t_id) => match subst.get(t_id) {
            some(resolved) => {
                let chased = apply_subst_map(subst, resolved)
                match chased {
                    Type::TypeVar { id: new_id, .. } =>
                        EffectRow { effects: effects, tail: some(new_id) },
                    Type::EffectRowType { effects: extra_effs, tail: extra_tail } => {
                        let mut merged = list_clone(effects)
                        for ee in extra_effs {
                            merged.push(apply_subst_effect_map(subst, ee))
                        }
                        EffectRow { effects: merged, tail: extra_tail }
                    },
                    _ => EffectRow { effects: effects, tail: none }
                }
            },
            none => EffectRow { effects: effects, tail: some(t_id) }
        },
        none => EffectRow { effects: effects, tail: none }
    }
}

// ============================================================
// Type interning / hash-cons (B-102 Phase 2 / A2)
//
// Collapses structurally-equal Types to a single shared pointer. Each call to
// apply_subst rebuilds composite Type spines from scratch; without interning the
// same structural type is re-allocated millions of times.
//
// LOOKUP-BEFORE-BUILD: the intern probe is inlined into each composite arm of
// apply_subst below (FnType/StructType/EnumType/GenericType/RecordType/
// EffectRowType/TupleType). Each arm applies subst to its children, computes the
// parent key FROM the (already-interned) children via the component-level key
// helpers in types.ring (fn_intern_key / struct_intern_key / ...), and only
// constructs the parent Type on a table MISS. A HIT returns the cached node with
// zero parent allocation. This replaces the old wrap-after-build intern_type
// helper, which built the parent first and discarded HIT copies — under A1
// never-drop those copies are never freed, yielding zero memory benefit.
//
// D1: types containing an unresolved Type::TypeVar yield a none key (apply_subst
//     already chases all resolvable vars, so a residual TypeVar node is genuinely
//     unresolved) -> such a type is built and returned as-is, never cached.
// D4: the intern table lives inside the UnionFind that apply_subst already
//     threads, so no extra plumbing is needed. Map is a reference type, so the
//     insert persists across apply_subst calls sharing this UnionFind even though
//     apply_subst takes a non-mut binding (same as uf_find path compression).
// ============================================================

// ============================================================
// Union-Find substitution: apply UnionFind-based substitution to a type.
// This is the primary apply_subst used by the type inference engine.
// Uses uf_find for O(alpha(n)) path-compressed type variable resolution.
// ============================================================

pub fn apply_subst(mut subst: UnionFind, t: Type) -> Type {
    match t {
        Type::IntType => t,
        Type::FloatType => t,
        Type::StrType => t,
        Type::BoolType => t,
        Type::UnitType => t,
        Type::NeverType => t,
        Type::AnyType => t,
        Type::TypeVar { id, .. } => match uf_lookup(subst, id) {
            some(resolved) => apply_subst(subst, resolved),
            none => {
                // Even without a type binding, path compression may have changed the root
                let root = uf_find(subst, id)
                if root == id { t } else { Type::TypeVar { id: root, name: none } }
            }
        },
        // B-102 Phase 2 / A2: all 7 composite arms use LOOKUP-BEFORE-BUILD
        // hash-cons. We first apply_subst the child components (which are already
        // interned), compute the parent key FROM those components (no parent
        // allocation), then probe the table: a HIT returns the cached node with
        // ZERO parent allocation; only a MISS (or none key — unresolved var, D1)
        // constructs the parent. This is the fix over the old wrap-after-build
        // (intern_type-after-construct), which always allocated the parent and —
        // under A1 never-drop — discarded HIT copies that are never freed, giving
        // zero memory benefit.
        Type::FnType { params, return_type, effects } => {
            // Use explicit for-loops (not .map closures): apply_subst now takes a
            // `mut subst`, and the auto-boxing pass boxes any mutable binding
            // captured by a closure (infer.ring:1092). subst is a reference type
            // whose writes (intern_table.insert) persist through the reference
            // without boxing (like uf_find), so we must avoid capturing it in a
            // closure — a for-loop references it directly. (CLAUDE.md: .map closure
            // cannot capture let mut — use a for loop.)
            let mut s_params: List<Type> = []
            for p in params { s_params.push(apply_subst(subst, p)) }
            let s_ret = apply_subst(subst, return_type)
            let s_effects = apply_subst_row(subst, effects)
            match fn_intern_key(s_params, s_ret, s_effects) {
                none => Type::FnType { params: s_params, return_type: s_ret, effects: s_effects },
                some(k) => match subst.intern_table.get(k) {
                    some(existing) => existing,
                    none => {
                        let built = Type::FnType { params: s_params, return_type: s_ret, effects: s_effects }
                        subst.intern_table.insert(k, built)
                        built
                    }
                }
            }
        },
        // StructType/EnumType ARE interned (B-102 Phase 2 / A2). They are the bulk
        // of the apply_subst type flood, so interning them is required to meet the
        // memory gate. Their nominal-shallow key (name + concrete type_params) is
        // sound because exhaustive.ring no longer reads template variants/fields
        // structurally — it re-derives payloads from the node's own type_params via
        // inst_map (see exhaustive.ring instantiate_enum_variants /
        // instantiate_struct_fields). So a cached node shared across two reads with
        // the same name+type_params is safe: variants/fields carry the (template)
        // payload but every reader re-instantiates from type_params.
        Type::StructType { name, type_params, fields } => {
            let mut s_params: List<Type> = []
            for p in type_params { s_params.push(apply_subst(subst, p)) }
            match struct_intern_key(name, s_params) {
                none => Type::StructType { name: name, type_params: s_params, fields: fields },
                some(k) => match subst.intern_table.get(k) {
                    some(existing) => existing,
                    none => {
                        let built = Type::StructType { name: name, type_params: s_params, fields: fields }
                        subst.intern_table.insert(k, built)
                        built
                    }
                }
            }
        },
        Type::EnumType { name, type_params, variants } => {
            let mut s_params: List<Type> = []
            for p in type_params { s_params.push(apply_subst(subst, p)) }
            match enum_intern_key(name, s_params) {
                none => Type::EnumType { name: name, type_params: s_params, variants: variants },
                some(k) => match subst.intern_table.get(k) {
                    some(existing) => existing,
                    none => {
                        let built = Type::EnumType { name: name, type_params: s_params, variants: variants }
                        subst.intern_table.insert(k, built)
                        built
                    }
                }
            }
        },
        Type::GenericType { base, args } => {
            let s_base = apply_subst(subst, base)
            let mut s_args: List<Type> = []
            for a in args { s_args.push(apply_subst(subst, a)) }
            match generic_intern_key(s_base, s_args) {
                none => Type::GenericType { base: s_base, args: s_args },
                some(k) => match subst.intern_table.get(k) {
                    some(existing) => existing,
                    none => {
                        let built = Type::GenericType { base: s_base, args: s_args }
                        subst.intern_table.insert(k, built)
                        built
                    }
                }
            }
        },
        Type::RecordType { fields, tail, tail_name } => {
            let mut mapped_fields: List<RecordField> = []
            for f in fields { mapped_fields.push(RecordField { name: f.name, ty: apply_subst(subst, f.ty) }) }
            // Resolve the record's tail-chasing ONCE to obtain the FINAL components
            // (final_fields/final_tail/final_tail_name), then run lookup-before-build
            // keyed on those components (key from components, no parent alloc).
            // record_result is a lightweight RecordType used only as a carrier for
            // the resolved components; the actual interned node is (re)built below
            // only on MISS, so a HIT pays no allocation here.
            let record_result = match tail {
                some(t_id) => {
                    let root_id = uf_find(subst, t_id)
                    match uf_lookup(subst, root_id) {
                        some(resolved) => {
                            let chased = apply_subst(subst, resolved)
                            match chased {
                                Type::TypeVar { id: new_id, name: new_name } =>
                                    Type::RecordType { fields: mapped_fields, tail: some(new_id), tail_name: new_name },
                                Type::RecordType { fields: extra_fields, tail: extra_tail, tail_name: extra_tn } => {
                                    let mut all_fields = list_clone(mapped_fields)
                                    for ef in extra_fields {
                                        all_fields.push(RecordField { name: ef.name, ty: apply_subst(subst, ef.ty) })
                                    }
                                    Type::RecordType { fields: all_fields, tail: extra_tail, tail_name: extra_tn }
                                },
                                _ => Type::RecordType { fields: mapped_fields, tail: none, tail_name: none }
                            }
                        },
                        none => {
                            let actual_id = if root_id == t_id { t_id } else { root_id }
                            Type::RecordType { fields: mapped_fields, tail: some(actual_id), tail_name: tail_name }
                        }
                    }
                },
                none => Type::RecordType { fields: mapped_fields, tail: none, tail_name: tail_name }
            }
            match record_result {
                Type::RecordType { fields: rf, tail: rt, tail_name: rtn } =>
                    match record_intern_key(rf, rt) {
                        none => Type::RecordType { fields: rf, tail: rt, tail_name: rtn },
                        some(k) => match subst.intern_table.get(k) {
                            some(existing) => existing,
                            none => {
                                let built = Type::RecordType { fields: rf, tail: rt, tail_name: rtn }
                                subst.intern_table.insert(k, built)
                                built
                            }
                        }
                    },
                _ => record_result
            }
        },
        Type::EffectRowType { effects, tail } => {
            let row = apply_subst_row(subst, EffectRow { effects: effects, tail: tail })
            match effect_row_intern_key(row.effects, row.tail) {
                none => Type::EffectRowType { effects: row.effects, tail: row.tail },
                some(k) => match subst.intern_table.get(k) {
                    some(existing) => existing,
                    none => {
                        let built = Type::EffectRowType { effects: row.effects, tail: row.tail }
                        subst.intern_table.insert(k, built)
                        built
                    }
                }
            }
        },
        Type::TupleType { elements } => {
            let mut s_elements: List<Type> = []
            for e in elements { s_elements.push(apply_subst(subst, e)) }
            match tuple_intern_key(s_elements) {
                none => Type::TupleType { elements: s_elements },
                some(k) => match subst.intern_table.get(k) {
                    some(existing) => existing,
                    none => {
                        let built = Type::TupleType { elements: s_elements }
                        subst.intern_table.insert(k, built)
                        built
                    }
                }
            }
        },
        Type::ErrorType => t
    }
}

fn apply_subst_effect(subst: UnionFind, e: Effect) -> Effect {
    match e {
        Effect::FailEffect { error_type } =>
            Effect::FailEffect { error_type: apply_subst(subst, error_type) },
        Effect::MutEffect { state_type } =>
            Effect::MutEffect { state_type: apply_subst(subst, state_type) },
        Effect::CustomEffect { name, type_args } =>
            Effect::CustomEffect { name: name, type_args: type_args.map(fn(a) { apply_subst(subst, a) }) },
        _ => e
    }
}

pub fn apply_subst_row(subst: UnionFind, row: EffectRow) -> EffectRow {
    let effects = row.effects.map(fn(e) { apply_subst_effect(subst, e) })
    match row.tail {
        some(t_id) => {
            let root_id = uf_find(subst, t_id)
            match uf_lookup(subst, root_id) {
                some(resolved) => {
                    let chased = apply_subst(subst, resolved)
                    match chased {
                        Type::TypeVar { id: new_id, .. } =>
                            EffectRow { effects: effects, tail: some(new_id) },
                        Type::EffectRowType { effects: extra_effs, tail: extra_tail } => {
                            let mut merged = list_clone(effects)
                            for ee in extra_effs {
                                merged.push(apply_subst_effect(subst, ee))
                            }
                            EffectRow { effects: merged, tail: extra_tail }
                        },
                        _ => EffectRow { effects: effects, tail: none }
                    }
                },
                none => {
                    let actual_id = if root_id == t_id { t_id } else { root_id }
                    EffectRow { effects: effects, tail: some(actual_id) }
                }
            }
        },
        none => EffectRow { effects: effects, tail: none }
    }
}
