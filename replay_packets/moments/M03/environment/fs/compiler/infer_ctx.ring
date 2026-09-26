use types::{Type, Effect, EffectRow, RecordField, StructField,
    INT, FLOAT, STR, BOOL, UNIT, NEVER, ANY, EMPTY_ROW,
    type_to_string, types_equal, make_option_type, type_to_builtin_name,
    row_merge, effects_match_kind}
use ast::{Span, Pattern, TypeExpr, RecordTypeField, NamedPatternField, span_zero, EffectExpr}
use hir::{HExpr, HStmt, HParam, DictRef, trait_dict_name, trait_bound_param_name,
    BUILTIN_INT, BUILTIN_FLOAT, BUILTIN_STR, BUILTIN_BOOL, BUILTIN_OPTION}
use diagnostics::{DiagnosticContext, DiagnosticNote, Diagnostic, CollectingSink, Severity, Suggestion, make_diag, make_diagnostic}
use codes::{E0201, E0204, E0301, E0302, E0503, E0511, E0512, E0513, E0705}
use union_find::{UnionFind, new_union_find, uf_find}
use env::{TypeEnv, TypeScheme, SchemeBound, AssocConstraintEntry, new_type_env, mono, apply_subst, apply_subst_row, apply_subst_map, has_impl, find_impl, lookup_variant}
use unify::{UnificationError, empty_subst, unify, occurs_in, unify_effect_params}

// ============================================================
// InferResult — return type for expression inference
// ============================================================

pub struct InferResult {
    pub hexpr: HExpr,
    pub subst: UnionFind,
    pub effects: EffectRow
}

// ============================================================
// Fn bounds entry type
// ============================================================

pub struct FnBoundsEntry {
    pub type_param_var_id: Int,
    pub trait_name: Str,
    pub type_param_name: Str
}

// ============================================================
// CompileError (raised via fail effect, caught at declaration level)
// ============================================================

pub struct CompileError {}

// ============================================================
// InferCtx — mutable type inference context
// ============================================================

pub struct InferCtx {
    pub env: TypeEnv,
    pub subst: UnionFind,
    pub sink: CollectingSink,
    pub type_param_scope: Map<Str, Type>,
    pub current_fn_return_type: Type?,
    pub current_fn_bounds: List<FnBoundsEntry>,
    pub fn_bounds_stack: List<List<FnBoundsEntry>>,
    pub loop_depth: Int,
    pub mod_path_stack: List<Str>,
    pub use_aliases: Map<Str, Str>,
    pub boxed_vars: Set<Int>,
    pub lambda_depth: Int,
    pub var_lambda_depth: Map<Int, Int>,
    pub fn_mut_params: Map<Str, List<Bool>>,
    // Default effect handler dependency graph: effect name -> list of effect names it depends on
    pub effect_default_deps: Map<Str, List<Str>>,
    // Qualified associated type scope: "T::Item" -> Type
    // Used to disambiguate when multiple type params have same-named associated types
    pub qualified_assoc_scope: Map<Str, Type>
}

pub fn new_infer_ctx(sink: CollectingSink) -> InferCtx {
    InferCtx {
        env: new_type_env(),
        subst: empty_subst(),
        sink: sink,
        type_param_scope: map_new(),
        current_fn_return_type: none,
        current_fn_bounds: [],
        fn_bounds_stack: [],
        loop_depth: 0,
        mod_path_stack: [],
        use_aliases: map_new(),
        boxed_vars: set_new(),
        lambda_depth: 0,
        var_lambda_depth: map_new(),
        fn_mut_params: map_new(),
        effect_default_deps: map_new(),
        qualified_assoc_scope: map_new()
    }
}

// ============================================================
// Error helper
// ============================================================

fn infer_suggestion(code: Str, message: Str, context: DiagnosticContext) -> List<Suggestion> {
    let mut suggestions: List<Suggestion> = []

    // Type mismatch suggestions
    if code == "E0301" {
        if message.contains("Str") && message.contains("Int") {
            suggestions.push(Suggestion {
                message: "Use parse_int() to convert Str to Int, or .to_str() for Int to Str",
                replacement: none,
                span: none
            })
        }
        if message.contains("Str") && message.contains("Float") {
            suggestions.push(Suggestion {
                message: "Use parse_float() to convert Str to Float, or .to_str() for Float to Str",
                replacement: none,
                span: none
            })
        }
        if message.contains("Option") {
            suggestions.push(Suggestion {
                message: "Use match, .unwrap_or(), or .unwrap_or_else() to handle Option values",
                replacement: none,
                span: none
            })
        }
        if message.contains("Bool") && (message.contains("Int") || message.contains("Str")) {
            suggestions.push(Suggestion {
                message: "Bool cannot be implicitly converted; use an if expression instead",
                replacement: none,
                span: none
            })
        }
    }

    // Numeric type required (E0303) — string concatenation attempt
    if code == "E0303" {
        if message.contains("Str") {
            suggestions.push(Suggestion {
                message: "Strings cannot use + for concatenation; use string interpolation or List<Str>.join()",
                replacement: none,
                span: none
            })
        }
    }

    // Undefined variable suggestions
    if code == "E0201" {
        match context {
            UndefinedVariable { name, scope_locals } => {
                match scope_locals {
                    some(locals) => {
                        let similar = find_similar_name(name, locals)
                        match similar {
                            some(suggestion) => {
                                suggestions.push(Suggestion {
                                    message: "Did you mean '${suggestion}'?",
                                    replacement: some(suggestion),
                                    span: none
                                })
                            },
                            none => {}
                        }
                    },
                    none => {}
                }
            },
            _ => {}
        }
    }

    // Missing field suggestions
    if code == "E0203" {
        match context {
            MissingField { field, available, .. } => {
                match available {
                    some(avail) => {
                        let similar = find_similar_name(field, avail)
                        match similar {
                            some(suggestion) => {
                                suggestions.push(Suggestion {
                                    message: "Did you mean '${suggestion}'?",
                                    replacement: some(suggestion),
                                    span: none
                                })
                            },
                            none => {}
                        }
                    },
                    none => {}
                }
            },
            _ => {}
        }
    }

    // Undefined method
    if code == "E0305" {
        suggestions.push(Suggestion {
            message: "Check available methods using the type's impl block or trait implementations",
            replacement: none,
            span: none
        })
    }

    // Immutable assignment
    if code == "E0205" {
        suggestions.push(Suggestion {
            message: "Declare the variable with 'let mut' instead of 'let' to allow reassignment",
            replacement: none,
            span: none
        })
    }

    // Non-exhaustive pattern match
    if code == "E0601" {
        suggestions.push(Suggestion {
            message: "Add a wildcard pattern '_ => ...' or cover all missing variants",
            replacement: none,
            span: none
        })
    }

    suggestions
}

fn find_similar_name(target: Str, candidates: List<Str>) -> Str? {
    // Simple similarity: find a candidate that starts with the same first 2 chars,
    // or where one is a prefix of the other, or they differ by only 1-2 characters in length
    let mut best: Str? = none
    let mut best_score = 0

    for candidate in candidates {
        let mut score = 0
        // Exact prefix match (one is prefix of the other)
        if candidate.starts_with(target) || target.starts_with(candidate) {
            score = 3
        }
        // Same first 2 characters and similar length
        if target.len() >= 2 && candidate.len() >= 2 {
            if target.slice(0, 2) == candidate.slice(0, 2) {
                let len_diff = if target.len() > candidate.len() { target.len() - candidate.len() } else { candidate.len() - target.len() }
                if len_diff <= 2 { score = 2 }
            }
        }
        // Same length and similar starting character
        if target.len() == candidate.len() && target.len() >= 1 {
            if target.slice(0, 1) == candidate.slice(0, 1) {
                score = 1
            }
        }
        if score > best_score {
            best_score = score
            best = some(candidate)
        }
    }
    best
}

pub fn type_error(mut sink: CollectingSink, code: Str, message: Str, span: Span, context: DiagnosticContext) -> Type {
    let mut diag = make_diag(code, Severity::SevError, message, span, context)
    let suggestions = infer_suggestion(code, message, context)
    if suggestions.len() > 0 {
        diag = Diagnostic { ..diag, suggestions: suggestions }
    }
    sink.report(diag)
    Type::ErrorType
}

pub fn type_error_with_notes(mut sink: CollectingSink, code: Str, message: Str, span: Span, context: DiagnosticContext, notes: List<DiagnosticNote>) -> Type {
    let mut diag = make_diagnostic(code, Severity::SevError, message, span, context, notes)
    let suggestions = infer_suggestion(code, message, context)
    if suggestions.len() > 0 {
        diag = Diagnostic { ..diag, suggestions: suggestions }
    }
    sink.report(diag)
    Type::ErrorType
}

// ============================================================
// Unification / effect helpers
// ============================================================

pub fn merge_effects(env: TypeEnv, a: EffectRow, b: EffectRow, s: UnionFind) -> (EffectRow, UnionFind) {
    // Apply substitution to resolve already-bound tail variables before merging
    let resolved_a = apply_subst_row(s, a)
    let resolved_b = apply_subst_row(s, b)
    let m = row_merge(resolved_a, resolved_b)
    let mut result_s = s

    // Unify type params for same-kind effects between a and b.
    // Catch unification errors: if params can't unify (e.g. mut<Int> vs mut<Str>),
    // keep the substitution unchanged — distinct effects stay separate.
    for eff_b in resolved_b.effects {
        for eff_a in resolved_a.effects {
            if effects_match_kind(eff_a, eff_b) {
                result_s = (unify_effect_params(eff_a, eff_b, result_s, env)) catch { _ => result_s }
                break
            }
        }
    }

    match m.tails_to_unify {
        some(pair) => {
            let (ta, tb) = pair
            result_s = unify(
                Type::TypeVar { id: ta, name: none },
                Type::TypeVar { id: tb, name: none },
                result_s, env
            )
        },
        none => {}
    }
    let out = (m.row, result_s)
    out
}

pub fn unify_at(sink: CollectingSink, env: TypeEnv, t1: Type, t2: Type, s: UnionFind, span: Span) -> UnionFind {
    unify(t1, t2, s, env) catch {
        e => {
            let code = if e.is_occurs_check { E0302 } else { E0301 }
            let _ = type_error(sink, code, e.message, span, DiagnosticContext::TypeMismatch {
                expected: type_to_string(apply_subst(s, t1)),
                actual: type_to_string(apply_subst(s, t2)),
                expression: none
            })
            s
        }
    }
}

pub fn unify_at_noted(sink: CollectingSink, env: TypeEnv, t1: Type, t2: Type, s: UnionFind, span: Span, notes: List<DiagnosticNote>) -> UnionFind {
    unify(t1, t2, s, env) catch {
        e => {
            let code = if e.is_occurs_check { E0302 } else { E0301 }
            let _ = type_error_with_notes(sink, code, e.message, span, DiagnosticContext::TypeMismatch {
                expected: type_to_string(apply_subst(s, t1)),
                actual: type_to_string(apply_subst(s, t2)),
                expression: none
            }, notes)
            s
        }
    }
}

// ============================================================
// Free type variable collection
// ============================================================

pub fn free_type_vars(t: Type, subst: UnionFind) -> Set<Int> {
    let resolved = apply_subst(subst, t)
    let mut result: Set<Int> = set_new()
    collect_free_vars(resolved, result)
    result
}

pub fn collect_free_vars(t: Type, mut result: Set<Int>) {
    match t {
        Type::IntType => {},
        Type::FloatType => {},
        Type::StrType => {},
        Type::BoolType => {},
        Type::UnitType => {},
        Type::NeverType => {},
        Type::AnyType => {},
        Type::ErrorType => {},
        Type::TypeVar { id, .. } => { result.insert(id) },
        Type::FnType { params, return_type, effects } => {
            for p in params { collect_free_vars(p, result) }
            collect_free_vars(return_type, result)
            match effects.tail {
                some(tail_id) => { result.insert(tail_id) },
                none => {}
            }
            for e in effects.effects {
                match e {
                    Effect::FailEffect { error_type } => collect_free_vars(error_type, result),
                    Effect::MutEffect { state_type } => collect_free_vars(state_type, result),
                    Effect::CustomEffect { type_args, .. } => {
                        for a in type_args { collect_free_vars(a, result) }
                    },
                    _ => {}
                }
            }
        },
        Type::StructType { type_params, .. } => {
            for tp in type_params { collect_free_vars(tp, result) }
        },
        Type::EnumType { type_params, .. } => {
            for tp in type_params { collect_free_vars(tp, result) }
        },
        Type::GenericType { base, args } => {
            collect_free_vars(base, result)
            for a in args { collect_free_vars(a, result) }
        },
        Type::RecordType { fields, tail, .. } => {
            for f in fields { collect_free_vars(f.ty, result) }
            match tail { some(t_id) => { result.insert(t_id) }, none => {} }
        },
        Type::TupleType { elements } => {
            for e in elements { collect_free_vars(e, result) }
        },
        Type::EffectRowType { effects, tail } => {
            match tail { some(t_id) => { result.insert(t_id) }, none => {} }
            for e in effects {
                match e {
                    Effect::FailEffect { error_type } => collect_free_vars(error_type, result),
                    Effect::MutEffect { state_type } => collect_free_vars(state_type, result),
                    Effect::CustomEffect { type_args, .. } => {
                        for a in type_args { collect_free_vars(a, result) }
                    },
                    _ => {}
                }
            }
        }
    }
}

pub fn free_type_vars_in_env(env: TypeEnv, subst: UnionFind) -> Set<Int> {
    let mut result: Set<Int> = set_new()
    for scope in env.scope.scopes {
        for entry in scope.variables.entries() {
            let (_, scheme) = entry
            let ftv = free_type_vars(scheme.ty, subst)
            let mut quantified: Set<Int> = set_new()
            for v in scheme.type_vars {
                let resolved = apply_subst(subst, Type::TypeVar { id: v, name: none })
                match resolved {
                    Type::TypeVar { id, .. } => { quantified.insert(id) },
                    _ => { quantified.insert(v) }
                }
            }
            for v in ftv {
                if !quantified.contains(v) { result.insert(v) }
            }
        }
    }
    result
}

// ============================================================
// Generalization
// ============================================================

pub fn generalize(env: TypeEnv, t: Type, subst: UnionFind) -> TypeScheme {
    let resolved = apply_subst(subst, t)
    let ftv_type = free_type_vars(resolved, empty_subst())
    let ftv_env = free_type_vars_in_env(env, subst)
    let mut type_vars: List<Int> = []
    for v in ftv_type {
        if !ftv_env.contains(v) { type_vars.push(v) }
    }
    let mut bounds: List<SchemeBound> = []
    for tv in type_vars {
        match env.scope.var_bounds.get(tv) {
            some(traits) => {
                for trait_name in traits {
                    bounds.push(SchemeBound { type_var: tv, trait_name: trait_name, assoc_constraints: [] })
                }
            },
            none => {}
        }
    }
    TypeScheme { ty: resolved, type_vars: type_vars, bounds: bounds, def_id: none }
}

// ============================================================
// Fn effects update
// ============================================================

pub fn update_fn_effects(mut env: TypeEnv, name: Str, effects: EffectRow) {
    match env.lookup(name) {
        some(scheme) => match scheme.ty {
            Type::FnType { params, return_type, .. } => {
                let new_type = Type::FnType { params: params, return_type: return_type, effects: effects }
                env.rebind(name, TypeScheme { ..scheme, ty: new_type })
            },
            _ => {}
        },
        none => {}
    }
}

// ============================================================
// Scheme var map + dict resolution
// ============================================================

pub fn build_scheme_var_map(scheme: TypeScheme, instantiated_type: Type) -> Map<Int, Type> {
    let mut result: Map<Int, Type> = map_new()
    let type_var_set: Set<Int> = set_from(scheme.type_vars)
    match (scheme.ty, instantiated_type) {
        (Type::FnType { params: sp, return_type: sr, .. },
         Type::FnType { params: ip, return_type: ir, .. }) => {
            let mut i = 0
            let limit = if sp.len() < ip.len() { sp.len() } else { ip.len() }
            while i < limit {
                match (sp.get(i), ip.get(i)) {
                    (some(s_param), some(i_param)) =>
                        collect_var_mappings(s_param, i_param, type_var_set, result),
                    _ => {}
                }
                i = i + 1
            }
            collect_var_mappings(sr, ir, type_var_set, result)
        },
        _ => {}
    }
    result
}

fn collect_var_mappings(scheme_type: Type, inst_type: Type, type_vars: Set<Int>, mut result: Map<Int, Type>) {
    match scheme_type {
        Type::TypeVar { id, .. } => {
            if type_vars.contains(id) {
                result.insert(id, inst_type)
            }
        },
        Type::StructType { name: sn, type_params: stp, .. } => match inst_type {
            Type::StructType { name: in_, type_params: itp, .. } => {
                if sn == in_ {
                    let mut i = 0
                    let limit = if stp.len() < itp.len() { stp.len() } else { itp.len() }
                    while i < limit {
                        match (stp.get(i), itp.get(i)) {
                            (some(s), some(inst)) => collect_var_mappings(s, inst, type_vars, result),
                            _ => {}
                        }
                        i = i + 1
                    }
                }
            },
            _ => {}
        },
        Type::EnumType { name: sn, type_params: stp, .. } => match inst_type {
            Type::EnumType { name: in_, type_params: itp, .. } => {
                if sn == in_ {
                    let mut i = 0
                    let limit = if stp.len() < itp.len() { stp.len() } else { itp.len() }
                    while i < limit {
                        match (stp.get(i), itp.get(i)) {
                            (some(s), some(inst)) => collect_var_mappings(s, inst, type_vars, result),
                            _ => {}
                        }
                        i = i + 1
                    }
                }
            },
            _ => {}
        },
        Type::FnType { params: sp, return_type: sr, .. } => match inst_type {
            Type::FnType { params: ip, return_type: ir, .. } => {
                let mut i = 0
                let limit = if sp.len() < ip.len() { sp.len() } else { ip.len() }
                while i < limit {
                    match (sp.get(i), ip.get(i)) {
                        (some(s), some(inst)) => collect_var_mappings(s, inst, type_vars, result),
                        _ => {}
                    }
                    i = i + 1
                }
                collect_var_mappings(sr, ir, type_vars, result)
            },
            _ => {}
        },
        Type::TupleType { elements: se, .. } => match inst_type {
            Type::TupleType { elements: ie, .. } => {
                let mut i = 0
                let limit = if se.len() < ie.len() { se.len() } else { ie.len() }
                while i < limit {
                    match (se.get(i), ie.get(i)) {
                        (some(s), some(inst)) => collect_var_mappings(s, inst, type_vars, result),
                        _ => {}
                    }
                    i = i + 1
                }
            },
            _ => {}
        },
        Type::GenericType { base: sb, args: sa, .. } => match inst_type {
            Type::GenericType { base: ib, args: ia, .. } => {
                collect_var_mappings(sb, ib, type_vars, result)
                let mut i = 0
                let limit = if sa.len() < ia.len() { sa.len() } else { ia.len() }
                while i < limit {
                    match (sa.get(i), ia.get(i)) {
                        (some(s), some(inst)) => collect_var_mappings(s, inst, type_vars, result),
                        _ => {}
                    }
                    i = i + 1
                }
            },
            _ => {}
        },
        _ => {}
    }
}

pub fn resolve_dicts_from_scheme(
    sink: CollectingSink, env: TypeEnv,
    current_fn_bounds: List<FnBoundsEntry>,
    scheme: TypeScheme, callee_type: Type, s: UnionFind, span: Span
) -> List<DictRef> {
    if scheme.bounds.len() == 0 { return [] }
    let var_map = build_scheme_var_map(scheme, callee_type)
    let mut resolved_dicts: List<DictRef> = []
    for bound in scheme.bounds {
        let mut found = false
        match var_map.get(bound.type_var) {
            some(fresh_var) => {
                let concrete = apply_subst(s, fresh_var)
                match concrete {
                    Type::StructType { name, type_params, .. } => {
                        if has_impl(env.trait_reg, name, bound.trait_name) {
                            if type_params.len() > 0 {
                                let inner = resolve_inner_dicts_from_type_params(env, current_fn_bounds, type_params, s, bound.trait_name)
                                resolved_dicts.push(DictRef::Wrapped {
                                    dict: trait_dict_name(name, bound.trait_name),
                                    trait_name: bound.trait_name,
                                    inner_dicts: inner
                                })
                            } else {
                                resolved_dicts.push(DictRef::Simple(trait_dict_name(name, bound.trait_name)))
                            }
                            found = true
                            // Validate associated type constraints
                            check_assoc_constraints(sink, env, bound, name, s, span)
                        }
                    },
                    Type::EnumType { name, type_params, .. } => {
                        if has_impl(env.trait_reg, name, bound.trait_name) {
                            if type_params.len() > 0 {
                                let inner = resolve_inner_dicts_from_type_params(env, current_fn_bounds, type_params, s, bound.trait_name)
                                resolved_dicts.push(DictRef::Wrapped {
                                    dict: trait_dict_name(name, bound.trait_name),
                                    trait_name: bound.trait_name,
                                    inner_dicts: inner
                                })
                            } else {
                                resolved_dicts.push(DictRef::Simple(trait_dict_name(name, bound.trait_name)))
                            }
                            found = true
                            // Validate associated type constraints
                            check_assoc_constraints(sink, env, bound, name, s, span)
                        }
                    },
                    Type::TypeVar { id, .. } => {
                        let matching = current_fn_bounds.find(fn(fb) {
                            let resolved_fb = apply_subst(s, Type::TypeVar { id: fb.type_param_var_id, name: none })
                            let resolved_match = match resolved_fb { Type::TypeVar { id: rid, .. } => rid == id, _ => false }
                            (fb.type_param_var_id == id || uf_find(s, fb.type_param_var_id) == id || resolved_match) && fb.trait_name == bound.trait_name
                        })
                        match matching {
                            some(fb) => {
                                resolved_dicts.push(DictRef::Simple(trait_bound_param_name(fb.type_param_name, fb.trait_name)))
                                found = true
                            },
                            none => {}
                        }
                    },
                    _ => {}
                }
                if !found {
                    match type_to_builtin_name(concrete) {
                        some(prim_name) => {
                            if has_impl(env.trait_reg, prim_name, bound.trait_name) {
                                resolved_dicts.push(DictRef::Simple(trait_dict_name(prim_name, bound.trait_name)))
                                found = true
                                // Validate associated type constraints
                                check_assoc_constraints(sink, env, bound, prim_name, s, span)
                            }
                        },
                        none => {}
                    }
                }
            },
            none => {}
        }
        if !found {
            let _ = type_error(sink, E0503,
                "Type does not satisfy trait bound '${bound.trait_name}'",
                span, DiagnosticContext::TraitError { detail: "type does not satisfy '${bound.trait_name}'" })
        }
    }
    resolved_dicts
}

// Check associated type constraints on a bound against an impl entry's actual assoc types.
fn check_assoc_constraints(
    sink: CollectingSink, env: TypeEnv,
    bound: SchemeBound, target_type_name: Str,
    s: UnionFind, span: Span
) {
    if bound.assoc_constraints.len() == 0 { return }
    // Find the impl entry for this type + trait
    let impl_entry = find_impl(env.trait_reg, target_type_name, bound.trait_name)
    match impl_entry {
        some(entry) => {
            for ac in bound.assoc_constraints {
                match entry.assoc_types.get(ac.name) {
                    some(actual_ty) => {
                        let expected_ty = apply_subst(s, ac.ty)
                        let actual_resolved = apply_subst(s, actual_ty)
                        if !types_equal(expected_ty, actual_resolved) {
                            let _ = type_error(sink, E0513,
                                "Associated type '${ac.name}' mismatch: expected '${type_to_string(expected_ty)}' but impl provides '${type_to_string(actual_resolved)}'",
                                span, DiagnosticContext::TraitError { detail: "associated type constraint mismatch" })
                        }
                    },
                    none => {}
                }
            }
        },
        none => {}
    }
}

fn resolve_inner_dicts_from_type_params(
    env: TypeEnv,
    current_fn_bounds: List<FnBoundsEntry>,
    type_params: List<Type>,
    s: UnionFind,
    trait_name: Str
) -> List<DictRef> {
    let mut result: List<DictRef> = []
    for param in type_params {
        let concrete = apply_subst(s, param)
        result.push(resolve_concrete_type_to_dict_ref(env, current_fn_bounds, concrete, s, trait_name))
    }
    result
}

fn resolve_concrete_type_to_dict_ref(
    env: TypeEnv,
    current_fn_bounds: List<FnBoundsEntry>,
    t: Type,
    s: UnionFind,
    trait_name: Str
) -> DictRef {
    match type_to_builtin_name(t) {
        some(builtin_name) => match t {
            Type::StructType { .. } => {},
            Type::EnumType { .. } => {},
            _ => { return DictRef::Simple(trait_dict_name(builtin_name, trait_name)) }
        },
        none => {}
    }
    match t {
        Type::TypeVar { id, .. } => {
            let bound = current_fn_bounds.find(fn(fb) {
                fb.type_param_var_id == id && fb.trait_name == trait_name
            })
            match bound {
                some(b) => DictRef::Simple(trait_bound_param_name(b.type_param_name, trait_name)),
                none => DictRef::Simple(trait_dict_name("__unknown", trait_name))
            }
        },
        Type::StructType { name, type_params, .. } => {
            if has_impl(env.trait_reg, name, trait_name) {
                if type_params.len() > 0 {
                    let inner = resolve_inner_dicts_from_type_params(env, current_fn_bounds, type_params, s, trait_name)
                    DictRef::Wrapped {
                        dict: trait_dict_name(name, trait_name),
                        trait_name: trait_name,
                        inner_dicts: inner
                    }
                } else {
                    DictRef::Simple(trait_dict_name(name, trait_name))
                }
            } else {
                DictRef::Simple(trait_dict_name(name, trait_name))
            }
        },
        Type::EnumType { name, type_params, .. } => {
            if has_impl(env.trait_reg, name, trait_name) {
                if type_params.len() > 0 {
                    let inner = resolve_inner_dicts_from_type_params(env, current_fn_bounds, type_params, s, trait_name)
                    DictRef::Wrapped {
                        dict: trait_dict_name(name, trait_name),
                        trait_name: trait_name,
                        inner_dicts: inner
                    }
                } else {
                    DictRef::Simple(trait_dict_name(name, trait_name))
                }
            } else {
                DictRef::Simple(trait_dict_name(name, trait_name))
            }
        },
        _ => DictRef::Simple(trait_dict_name("__unknown", trait_name))
    }
}

// ============================================================
// Type expression resolution
// ============================================================

pub fn resolve_type_expr(mut ctx: InferCtx, texpr: TypeExpr) -> Type {
    match texpr {
        TypeExpr::Named { name, qualifier, type_args, span } =>
            match qualifier {
                some(q) => {
                    // Check if qualifier is a type parameter — if so, resolve as associated type
                    match ctx.type_param_scope.get(q) {
                        some(tp_type) => {
                            // q is a type parameter, name is an associated type name
                            resolve_assoc_type(ctx, q, name, span)
                        },
                        none => {
                            let mut resolved_q = q
                            if q == "self" || q.starts_with("super") {
                                match resolve_relative_qualifier(q, ctx.mod_path_stack) {
                                    some(prefix) => { resolved_q = prefix },
                                    none => { resolved_q = q }
                                }
                            }
                            if resolved_q == "" {
                                resolve_named_type(ctx, name, type_args, span)
                            } else {
                                let qualified_type_name = "${resolved_q}::${name}"
                                // Try direct lookup first
                                if ctx.env.types.structs.contains_key(qualified_type_name) || ctx.env.types.enums.contains_key(qualified_type_name) || ctx.env.types.type_aliases.contains_key(qualified_type_name) {
                                    resolve_named_type(ctx, qualified_type_name, type_args, span)
                                } else if ctx.mod_path_stack.len() > 0 {
                                    // Fallback: try prepending current mod path for relative references
                                    let mod_prefix = ctx.mod_path_stack.join("::")
                                    let full_type_name = "${mod_prefix}::${qualified_type_name}"
                                    if ctx.env.types.structs.contains_key(full_type_name) || ctx.env.types.enums.contains_key(full_type_name) || ctx.env.types.type_aliases.contains_key(full_type_name) {
                                        resolve_named_type(ctx, full_type_name, type_args, span)
                                    } else {
                                        resolve_named_type(ctx, qualified_type_name, type_args, span)
                                    }
                                } else {
                                    resolve_named_type(ctx, qualified_type_name, type_args, span)
                                }
                            }
                        }
                    }
                },
                none => resolve_named_type(ctx, name, type_args, span)
            },
        TypeExpr::FnType { params, return_type, effects, .. } => {
            let mut resolved_params: List<Type> = []
            for p in params { resolved_params.push(resolve_type_expr(ctx, p)) }
            let ret = resolve_type_expr(ctx, return_type)
            let eff_row = if effects.len() > 0 {
                let mut resolved_effects: List<Effect> = []
                for e in effects {
                    resolved_effects.push(resolve_fn_type_effect(ctx, e))
                }
                EffectRow { effects: resolved_effects, tail: none }
            } else {
                let tail_id = ctx.env.fresh_var_id()
                EffectRow { effects: [], tail: some(tail_id) }
            }
            Type::FnType { params: resolved_params, return_type: ret, effects: eff_row }
        },
        TypeExpr::OptionType { inner, .. } =>
            make_option_type(resolve_type_expr(ctx, inner)),
        TypeExpr::RecordType { fields, rest, .. } => {
            let mut resolved_fields: List<RecordField> = []
            for f in fields {
                resolved_fields.push(RecordField { name: f.name, ty: resolve_type_expr(ctx, f.ty) })
            }
            match rest {
                some(rest_name) => {
                    let tail_var = ctx.env.fresh_var()
                    match tail_var {
                        Type::TypeVar { id, .. } => {
                            ctx.type_param_scope.insert(rest_name, tail_var)
                            Type::RecordType { fields: resolved_fields, tail: some(id), tail_name: some(rest_name) }
                        },
                        _ => Type::RecordType { fields: resolved_fields, tail: none, tail_name: none }
                    }
                },
                none => Type::RecordType { fields: resolved_fields, tail: none, tail_name: none }
            }
        },
        TypeExpr::TupleType { elements, .. } => {
            let mut resolved_elems: List<Type> = []
            for e in elements { resolved_elems.push(resolve_type_expr(ctx, e)) }
            Type::TupleType { elements: resolved_elems }
        }
    }
}

// Resolve associated type T::Item by searching the type parameter's trait bounds
fn resolve_assoc_type(mut ctx: InferCtx, type_param_name: Str, assoc_name: Str, span: Span) -> Type {
    // First check: if we have a qualified path (T::Item), look up the qualified_assoc_scope
    // which tracks per-type-param associated types to disambiguate when multiple
    // type params have same-named associated types (e.g., T::Item vs U::Item)
    if type_param_name != "" {
        let qualified_key = "${type_param_name}::${assoc_name}"
        match ctx.qualified_assoc_scope.get(qualified_key) {
            some(ty) => { return ty },
            none => {}
        }
    }

    // Fallback: is the assoc_name already directly in the type_param_scope?
    // (This happens when trait body injects assoc type vars into scope during registration)
    match ctx.type_param_scope.get(assoc_name) {
        some(ty) => {
            // Check if this is a legitimate associated type by verifying through bounds
            // If we're in a trait body context, the associated type name is directly in scope
            return ty
        },
        none => {}
    }

    // Look up the type param's bounds from current_fn_bounds
    let mut found_types: List<Type> = []
    let mut found_trait_names: List<Str> = []
    for fb in ctx.current_fn_bounds {
        if fb.type_param_name == type_param_name {
            // Look up the trait definition for this bound
            match ctx.env.trait_reg.traits.get(fb.trait_name) {
                some(tdef) => {
                    for atdef in tdef.assoc_types {
                        if atdef.name == assoc_name {
                            // Found a matching associated type; create a fresh type variable for it
                            let at_var = ctx.env.fresh_var()
                            found_types.push(at_var)
                            found_trait_names.push(fb.trait_name)
                        }
                    }
                },
                none => {}
            }
        }
    }

    // Also check var_bounds for type variables
    if found_types.len() == 0 {
        match ctx.type_param_scope.get(type_param_name) {
            some(tp_type) => match tp_type {
                Type::TypeVar { id, .. } => {
                    match ctx.env.scope.var_bounds.get(id) {
                        some(bound_set) => {
                            for bound_name in bound_set.to_list() {
                                match ctx.env.trait_reg.traits.get(bound_name) {
                                    some(tdef) => {
                                        for atdef in tdef.assoc_types {
                                            if atdef.name == assoc_name {
                                                let at_var = ctx.env.fresh_var()
                                                found_types.push(at_var)
                                                found_trait_names.push(bound_name)
                                            }
                                        }
                                    },
                                    none => {}
                                }
                            }
                        },
                        none => {}
                    }
                },
                _ => {}
            },
            none => {}
        }
    }

    if found_types.len() == 0 {
        let _ = type_error(ctx.sink, E0511,
            "Type '${type_param_name}' has no associated type '${assoc_name}'",
            span, DiagnosticContext::TraitError { detail: "unknown associated type '${assoc_name}'" })
        return ctx.env.fresh_var()
    }
    if found_types.len() > 1 {
        let traits_str = found_trait_names.join(", ")
        let _ = type_error(ctx.sink, E0512,
            "Ambiguous associated type '${assoc_name}' for '${type_param_name}': found in traits ${traits_str}",
            span, DiagnosticContext::TraitError { detail: "ambiguous associated type" })
    }
    found_types.get(0).unwrap_or(ctx.env.fresh_var())
}

fn resolve_fn_type_effect(mut ctx: InferCtx, eff: EffectExpr) -> Effect {
    if eff.name == "io" { return Effect::IoEffect }
    if eff.name == "mut" {
        let mut_state = if eff.type_args.len() > 0 {
            match eff.type_args.first() {
                some(t) => resolve_type_expr(ctx, t),
                none => ctx.env.fresh_var()
            }
        } else {
            ctx.env.fresh_var()
        }
        return Effect::MutEffect { state_type: mut_state }
    }
    if eff.name == "fail" {
        let err_type = if eff.type_args.len() > 0 {
            match eff.type_args.first() {
                some(t) => resolve_type_expr(ctx, t),
                none => ctx.env.fresh_var()
            }
        } else {
            ctx.env.fresh_var()
        }
        return Effect::FailEffect { error_type: err_type }
    }
    let mut resolved_args: List<Type> = []
    for ta in eff.type_args { resolved_args.push(resolve_type_expr(ctx, ta)) }
    Effect::CustomEffect { name: eff.name, type_args: resolved_args }
}

pub fn resolve_self_type(mut ctx: InferCtx, name: Str) -> Type {
    resolve_named_type(ctx, name, [], span_zero())
}

pub fn resolve_named_type(mut ctx: InferCtx, name: Str, type_args: List<TypeExpr>, span: Span) -> Type {
    if (name == BUILTIN_INT) { return INT }
    if (name == BUILTIN_FLOAT) { return FLOAT }
    if (name == BUILTIN_STR) { return STR }
    if (name == BUILTIN_BOOL) { return BOOL }
    if name == "Never" { return NEVER }
    if name == "Unit" { return UNIT }

    // Check type parameter scope
    match ctx.type_param_scope.get(name) {
        some(tp) => { return tp },
        none => {}
    }

    // Option<T>
    if name == BUILTIN_OPTION && type_args.len() == 1 {
        match type_args.get(0) {
            some(arg) => { return make_option_type(resolve_type_expr(ctx, arg)) },
            none => {}
        }
    }

    // Known struct
    if ctx.env.types.structs.contains_key(name) {
        match ctx.env.types.structs.get(name) {
            some(def) => {
                if type_args.len() > 0 && type_args.len() != def.type_params.len() {
                    let _ = type_error(ctx.sink, E0301,
                        "Type '${name}' expects ${def.type_params.len().to_str()} type argument(s), got ${type_args.len().to_str()}",
                        span, DiagnosticContext::TypeMismatch {
                            expected: "${def.type_params.len().to_str()} type args",
                            actual: "${type_args.len().to_str()} type args",
                            expression: none
                        })
                }
                let mut resolved_params: List<Type> = []
                if type_args.len() > 0 {
                    for a in type_args { resolved_params.push(resolve_type_expr(ctx, a)) }
                } else {
                    for _ in def.type_params { resolved_params.push(ctx.env.fresh_var()) }
                }
                return Type::StructType {
                    name: def.name,
                    type_params: resolved_params,
                    fields: def.fields
                }
            },
            none => {}
        }
    }

    // Known enum
    if ctx.env.types.enums.contains_key(name) {
        match ctx.env.types.enums.get(name) {
            some(def) => {
                if type_args.len() > 0 && type_args.len() != def.type_params.len() {
                    let _ = type_error(ctx.sink, E0301,
                        "Type '${name}' expects ${def.type_params.len().to_str()} type argument(s), got ${type_args.len().to_str()}",
                        span, DiagnosticContext::TypeMismatch {
                            expected: "${def.type_params.len().to_str()} type args",
                            actual: "${type_args.len().to_str()} type args",
                            expression: none
                        })
                }
                let mut resolved_params: List<Type> = []
                if type_args.len() > 0 {
                    for a in type_args { resolved_params.push(resolve_type_expr(ctx, a)) }
                } else {
                    for _ in def.type_params { resolved_params.push(ctx.env.fresh_var()) }
                }
                return Type::EnumType {
                    name: def.name,
                    type_params: resolved_params,
                    variants: def.variants
                }
            },
            none => {}
        }
    }

    // Type alias
    match ctx.env.types.type_aliases.get(name) {
        some(alias) => {
            if type_args.len() > 0 && type_args.len() != alias.type_params.len() {
                let _ = type_error(ctx.sink, E0301,
                    "Type '${name}' expects ${alias.type_params.len().to_str()} type argument(s), got ${type_args.len().to_str()}",
                    span, DiagnosticContext::TypeMismatch {
                        expected: "${alias.type_params.len().to_str()} type args",
                        actual: "${type_args.len().to_str()} type args",
                        expression: none
                    })
            }
            if alias.type_param_vars.len() == 0 { return alias.ty }
            let mut resolved_args: List<Type> = []
            for a in type_args { resolved_args.push(resolve_type_expr(ctx, a)) }
            let mut mapping: Map<Int, Type> = map_new()
            let mut i = 0
            let limit = if alias.type_param_vars.len() < resolved_args.len() { alias.type_param_vars.len() } else { resolved_args.len() }
            while i < limit {
                match (alias.type_param_vars.get(i), resolved_args.get(i)) {
                    (some(var_id), some(arg)) => { mapping.insert(var_id, arg) },
                    _ => {}
                }
                i = i + 1
            }
            return apply_subst_map(mapping, alias.ty)
        },
        none => {}
    }

    type_error(ctx.sink, E0204, "Unknown type: ${name}", span,
        DiagnosticContext::OtherContext { detail: some("unknown type '${name}'") })
}

// ============================================================
// Pattern binding
// ============================================================

pub fn bind_pattern(mut ctx: InferCtx, pattern: Pattern, expected_type: Type, subst: UnionFind) {
    match pattern {
        Pattern::Wildcard { .. } => {},
        Pattern::Binding { name, span } => {
            ctx.env.bind_mono(name, apply_subst(subst, expected_type))
            match ctx.env.lookup(name) {
                some(scheme) => match scheme.def_id {
                    some(did) => ctx.env.record_def_span(did, span),
                    none => {}
                },
                none => {}
            }
        },
        Pattern::Constructor { name, qualifier, fields, span } =>
            bind_constructor_pattern(ctx, name, qualifier, fields, expected_type, subst, span),
        Pattern::Literal { .. } => {},
        Pattern::NamedConstructor { name, qualifier, fields, span, .. } =>
            bind_named_constructor_pattern(ctx, name, qualifier, fields, expected_type, subst, span),
        Pattern::TuplePattern { elements, span } => {
            let resolved = apply_subst(subst, expected_type)
            match resolved {
                Type::TupleType { elements: type_elems } => {
                    if elements.len() != type_elems.len() {
                        let _ = type_error(ctx.sink, E0301,
                            "Tuple pattern has ${elements.len().to_str()} elements but type has ${type_elems.len().to_str()}",
                            span, DiagnosticContext::OtherContext { detail: some("tuple arity mismatch") })
                    }
                    let mut i = 0
                    while i < elements.len() {
                        match (elements.get(i), type_elems.get(i)) {
                            (some(pat), some(ty)) => bind_pattern(ctx, pat, ty, subst),
                            _ => {}
                        }
                        i = i + 1
                    }
                },
                _ => { let _ = type_error(ctx.sink, E0301,
                    "Tuple pattern requires tuple type, got ${type_to_string(resolved)}",
                    span, DiagnosticContext::TypeMismatch { expected: "tuple", actual: type_to_string(resolved), expression: none }) }
            }
        },
        Pattern::OrPattern { patterns, span } => {
            // Bind each sub-pattern against the same expected type.
            // For or-patterns without bindings, this just validates each alternative.
            // For or-patterns with bindings, each sub-pattern introduces the same names.
            for pat in patterns {
                bind_pattern(ctx, pat, expected_type, subst)
            }
        }
    }
}

fn bind_constructor_pattern(
    ctx: InferCtx, name: Str, qualifier: Str?, fields: List<Pattern>,
    expected_type: Type, subst: UnionFind, span: Span
) {
    let enum_name = resolve_pattern_enum(ctx, name, qualifier, span)
    match enum_name {
        some(ename) => match ctx.env.types.enums.get(ename) {
            some(enum_def) => {
                let variant = lookup_variant(enum_def, name)
                match variant {
                    some(v) => {
                        let resolved_expected = apply_subst(subst, expected_type)
                        match resolved_expected {
                            Type::EnumType { name: rname, .. } => {
                                if rname != ename {
                                    let _ = type_error(ctx.sink, E0301,
                                        "variant '${name}' belongs to enum '${ename}', not '${rname}'",
                                        span, DiagnosticContext::TypeMismatch { expected: rname, actual: ename, expression: none })
                                }
                            },
                            Type::TypeVar { .. } => {},
                            _ => { let _ = type_error(ctx.sink, E0301,
                                "cannot destructure type '${type_to_string(resolved_expected)}' with constructor pattern '${name}'",
                                span, DiagnosticContext::PatternError { detail: "constructor pattern on non-enum type" }) }
                        }
                        let inst_map = build_instantiation_map(enum_def.type_param_vars, resolved_expected)
                        if fields.len() != v.fields.len() {
                            let _ = type_error(ctx.sink, E0301,
                                "constructor '${name}' has ${v.fields.len().to_str()} field(s) but pattern has ${fields.len().to_str()}",
                                span, DiagnosticContext::OtherContext { detail: some("constructor arity mismatch") })
                        }
                        let mut i = 0
                        while i < fields.len() && i < v.fields.len() {
                            match (fields.get(i), v.fields.get(i)) {
                                (some(fpat), some(ftype)) => {
                                    let field_type = if inst_map.len() > 0 { apply_subst_map(inst_map, ftype) } else { ftype }
                                    bind_pattern(ctx, fpat, field_type, subst)
                                },
                                _ => {}
                            }
                            i = i + 1
                        }
                    },
                    none => {}
                }
            },
            none => {}
        },
        none => {}
    }
}

fn bind_named_constructor_pattern(
    ctx: InferCtx, name: Str, qualifier: Str?, fields: List<NamedPatternField>,
    expected_type: Type, subst: UnionFind, span: Span
) {
    // Resolve relative paths (self::/super::) to actual qualified names
    let mut resolved_qualifier = qualifier
    match qualifier {
        some(q) => {
            if q == "self" || q.starts_with("super") {
                match resolve_relative_qualifier(q, ctx.mod_path_stack) {
                    some(prefix) => {
                        if prefix == "" {
                            resolved_qualifier = none
                        } else {
                            resolved_qualifier = some(prefix)
                        }
                    },
                    none => {
                        let _ = type_error(ctx.sink, E0705,
                            "Cannot use '${q}' — relative path exceeds module nesting depth",
                            span, DiagnosticContext::OtherContext { detail: some("relative path out of scope") })
                        return
                    }
                }
            }
        },
        none => {}
    }

    // Try enum variant lookup first (non-error-reporting)
    let enum_name = try_resolve_pattern_enum(ctx, name, resolved_qualifier)
    match enum_name {
        some(ename) => match ctx.env.types.enums.get(ename) {
            some(enum_def) => {
                let variant = lookup_variant(enum_def, name)
                match variant {
                    some(v) => match v.field_names {
                        some(vfield_names) => {
                            let resolved_expected = apply_subst(subst, expected_type)
                            match resolved_expected {
                                Type::EnumType { name: rname, .. } => {
                                    if rname != ename {
                                        let _ = type_error(ctx.sink, E0301,
                                            "variant '${name}' belongs to enum '${ename}', not '${rname}'",
                                            span, DiagnosticContext::TypeMismatch { expected: rname, actual: ename, expression: none })
                                    }
                                },
                                _ => {}
                            }
                            let inst_map = build_instantiation_map(enum_def.type_param_vars, resolved_expected)
                            for field in fields {
                                let field_idx = vfield_names.index_of(field.name)
                                match field_idx {
                                    some(idx) => match v.fields.get(idx) {
                                        some(ftype) => {
                                            let field_type = if inst_map.len() > 0 { apply_subst_map(inst_map, ftype) } else { ftype }
                                            bind_pattern(ctx, field.pattern, field_type, subst)
                                        },
                                        none => {}
                                    },
                                    none => { let _ = type_error(ctx.sink, E0301,
                                        "variant '${name}' has no field '${field.name}'",
                                        field.span, DiagnosticContext::OtherContext { detail: some("unknown field '${field.name}'") }) }
                                }
                            }
                        },
                        none => {}
                    },
                    none => {}
                }
            },
            none => {}
        },
        none => {
            // Not an enum variant — try struct lookup
            let struct_name = match resolved_qualifier {
                some(q) => "${q}::${name}",
                none => name
            }
            bind_struct_pattern_fields(ctx, struct_name, name, fields, expected_type, subst, span)
        }
    }
}

fn bind_struct_pattern_fields(
    ctx: InferCtx, struct_name: Str, display_name: Str, fields: List<NamedPatternField>,
    expected_type: Type, subst: UnionFind, span: Span
) {
    match ctx.env.types.structs.get(struct_name) {
        some(struct_def) => {
            let resolved_expected = apply_subst(subst, expected_type)
            let inst_map = build_instantiation_map(struct_def.type_param_vars, resolved_expected)
            for field in fields {
                let found = struct_def.fields.find(fn(sf) { sf.name == field.name })
                match found {
                    some(sf) => {
                        let field_type = if inst_map.len() > 0 { apply_subst_map(inst_map, sf.ty) } else { sf.ty }
                        bind_pattern(ctx, field.pattern, field_type, subst)
                    },
                    none => {
                        let _ = type_error(ctx.sink, E0301,
                            "struct '${display_name}' has no field '${field.name}'",
                            field.span, DiagnosticContext::OtherContext { detail: some("unknown field '${field.name}'") })
                    }
                }
            }
        },
        none => {
            // Try with mod path prefix
            if ctx.mod_path_stack.len() > 0 {
                let mod_prefix = ctx.mod_path_stack.join("::")
                let full_name = "${mod_prefix}::${struct_name}"
                match ctx.env.types.structs.get(full_name) {
                    some(sdef) => {
                        let resolved_expected = apply_subst(subst, expected_type)
                        let inst_map = build_instantiation_map(sdef.type_param_vars, resolved_expected)
                        for field in fields {
                            let found = sdef.fields.find(fn(sf) { sf.name == field.name })
                            match found {
                                some(sf) => {
                                    let field_type = if inst_map.len() > 0 { apply_subst_map(inst_map, sf.ty) } else { sf.ty }
                                    bind_pattern(ctx, field.pattern, field_type, subst)
                                },
                                none => {}
                            }
                        }
                    },
                    none => {}
                }
            }
        }
    }
}

// Like resolve_pattern_enum but returns none silently if not found (no E0201 error).
// Used by bind_named_constructor_pattern where the name might be a struct, not an enum variant.
fn try_resolve_pattern_enum(ctx: InferCtx, variant_name: Str, qualifier: Str?) -> Str? {
    match qualifier {
        some(q) => {
            let direct = ctx.env.types.enums.get(q)
            match direct {
                some(enum_def) => {
                    if enum_def.variant_index.contains_key(variant_name) {
                        return some(enum_def.name)
                    }
                    return none
                },
                none => {}
            }
            if ctx.mod_path_stack.len() > 0 {
                let mod_prefix = ctx.mod_path_stack.join("::")
                let full_q = "${mod_prefix}::${q}"
                let fallback = ctx.env.types.enums.get(full_q)
                match fallback {
                    some(enum_def2) => {
                        if enum_def2.variant_index.contains_key(variant_name) {
                            return some(enum_def2.name)
                        }
                    },
                    none => {}
                }
            }
            none
        },
        none => ctx.env.types.variant_to_enum.get(variant_name)
    }
}

fn resolve_pattern_enum(ctx: InferCtx, variant_name: Str, qualifier: Str?, span: Span) -> Str? {
    match qualifier {
        some(q) => {
            // Try direct qualifier first
            let direct = ctx.env.types.enums.get(q)
            match direct {
                some(enum_def) => {
                    if enum_def.variant_index.contains_key(variant_name) {
                        return some(enum_def.name)
                    }
                    let _ = type_error(ctx.sink, E0201,
                        "'${q}' has no variant '${variant_name}'",
                        span, DiagnosticContext::UndefinedVariable { name: variant_name, scope_locals: none })
                    return none
                },
                none => {}
            }
            // Fallback: try prepending current mod path
            if ctx.mod_path_stack.len() > 0 {
                let mod_prefix = ctx.mod_path_stack.join("::")
                let full_q = "${mod_prefix}::${q}"
                let fallback = ctx.env.types.enums.get(full_q)
                match fallback {
                    some(enum_def2) => {
                        if enum_def2.variant_index.contains_key(variant_name) {
                            return some(enum_def2.name)
                        }
                    },
                    none => {}
                }
            }
            let _ = type_error(ctx.sink, E0201,
                "'${q}' has no variant '${variant_name}'",
                span, DiagnosticContext::UndefinedVariable { name: variant_name, scope_locals: none })
            none
        },
        none => ctx.env.types.variant_to_enum.get(variant_name)
    }
}

fn build_instantiation_map(type_param_vars: List<Int>, resolved_expected: Type) -> Map<Int, Type> {
    let mut inst_map: Map<Int, Type> = map_new()
    match resolved_expected {
        Type::EnumType { type_params, .. } => {
            let mut i = 0
            while i < type_param_vars.len() && i < type_params.len() {
                match (type_param_vars.get(i), type_params.get(i)) {
                    (some(var_id), some(tp)) => { inst_map.insert(var_id, tp) },
                    _ => {}
                }
                i = i + 1
            }
        },
        Type::StructType { type_params, .. } => {
            var i = 0
            while i < type_param_vars.len() && i < type_params.len() {
                match (type_param_vars.get(i), type_params.get(i)) {
                    (some(var_id), some(tp)) => { inst_map.insert(var_id, tp) },
                    _ => {}
                }
                i = i + 1
            }
        },
        _ => {}
    }
    inst_map
}

// ============================================================
// Effect removal helpers
// ============================================================

pub fn remove_fail_effect(row: EffectRow) -> EffectRow {
    let filtered = row.effects.filter(fn(e) {
        match e { Effect::FailEffect { .. } => false, _ => true }
    })
    EffectRow { effects: filtered, tail: row.tail }
}

// ============================================================
// Relative path resolution (self::/super::)
// ============================================================

// Resolves a qualifier containing "self"/"super" relative path
// segments against the current mod_path_stack.
// Returns the resolved fully-qualified prefix, or none on error.
pub fn resolve_relative_qualifier(qualifier: Str, mod_path_stack: List<Str>) -> Str? {
    if qualifier == "self" {
        if mod_path_stack.len() == 0 {
            return none
        }
        return some(mod_path_stack.join("::"))
    }
    // Handle "super" and "super::super" etc.
    let parts = qualifier.split("::")
    let mut super_count = 0
    for part in parts {
        if part == "super" {
            super_count = super_count + 1
        } else {
            break
        }
    }
    if super_count == 0 {
        return none
    }
    if super_count > mod_path_stack.len() {
        return none
    }
    // Build resolved prefix from mod_path_stack[0..len-super_count]
    let remaining = mod_path_stack.len() - super_count
    let mut resolved_parts: List<Str> = []
    let mut i = 0
    while i < remaining {
        resolved_parts.push(mod_path_stack.get(i).unwrap_or(""))
        i = i + 1
    }
    // Append any non-super trailing parts from qualifier
    let mut j = super_count
    while j < parts.len() {
        resolved_parts.push(parts.get(j).unwrap_or(""))
        j = j + 1
    }
    if resolved_parts.len() == 0 {
        return some("")
    }
    some(resolved_parts.join("::"))
}
