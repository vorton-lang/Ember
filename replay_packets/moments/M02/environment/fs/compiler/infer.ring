use types::{Type, Effect, EffectRow, StructField, EnumVariant,
    INT, FLOAT, STR, BOOL, UNIT, NEVER, ANY, EMPTY_ROW,
    type_to_string, types_equal, make_option_type, is_option_type, option_inner,
    type_to_builtin_name, effect_row}
use ast::{Program, Decl, Expr, Stmt, Param, MatchArm, StructFieldInit,
    EffectHandler, StringInterpPart, Pattern, BinOp, UnaryOp, TypeExpr,
    TypeParam, TypeBound, Span, UseDecl, DestructureBinding, span_zero,
    NamedPatternField, EffectOpDecl}
use hir::{HExpr, HStmt, HDecl, HParam, HMatchArm, HEffectHandler,
    HStructFieldInit, HStringInterpPart, HProgram, DerivedImpl,
    TraitDispatch, DictDispatchInfo, DictRef, TraitBound,
    HStructField, HEnumVariant, HEffectOp, HTraitMethod,
    HForInDestructure, HLetDestructureBinding,
    variant_js_name, trait_dict_name, trait_bound_param_name,
    BUILTIN_RANGE, BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET,
    hexpr_type, hexpr_effects, hexpr_span}
use diagnostics::{DiagnosticContext, DiagnosticNote, CollectingSink, Severity, make_diag}
use codes::{E0201, E0203, E0205, E0206, E0208, E0301, E0303, E0304, E0305, E0306,
    E0307, E0308, E0402, E0504, E0601, E0705, W0001}
use union_find::{UnionFind, uf_find, uf_lookup}
use env::{TypeEnv, TypeScheme, SchemeBound, StructDef, EnumDef, EffectDef,
    EffectOpDef, TraitDef, TraitMethodDef, ImplEntry, TypeAliasDef,
    BuiltInKind, mono, apply_subst, apply_subst_row, apply_subst_map, has_impl, find_impl, lookup_variant}
use unify::{unify, empty_subst}
use infer_ctx::{InferCtx, InferResult, FnBoundsEntry, CompileError,
    type_error, type_error_with_notes, merge_effects, unify_at, unify_at_noted, update_fn_effects,
    resolve_type_expr, resolve_self_type, resolve_named_type,
    bind_pattern, build_scheme_var_map, resolve_dicts_from_scheme,
    remove_fail_effect,
    generalize, free_type_vars, resolve_relative_qualifier}
use exhaustive::{check_exhaustive}


struct MethodLookupResult {
    method_type: Type?,
    method_scheme: TypeScheme?
}


// ============================================================
// Value type check (for auto-boxing)
// ============================================================

fn is_value_type(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::BoolType => true,
        Type::StrType => true,
        _ => false
    }
}

// ============================================================
// Local mut effect cancellation
// ============================================================

// When calling a function that has mut<T> effects, if the argument
// corresponding to the mut parameter is a local variable (not a
// mut function parameter), the mutation is not observable outside
// the current function, so the mut<T> effect should be cancelled.
//
// callee_params: the callee's FnType parameter types
// callee_effects: the callee's FnType effect row
// hargs: inferred argument HExprs (same length as callee_params for regular calls;
//        for method calls, hargs[i] corresponds to callee_params[param_offset + i])
// param_offset: 0 for regular calls, 1 for method calls (skip self)
fn cancel_local_mut_effects(
    ctx: InferCtx,
    effects: EffectRow,
    callee_params: List<Type>,
    callee_effects: EffectRow,
    hargs: List<HExpr>,
    param_offset: Int,
    s: UnionFind
) -> EffectRow {
    // Collect mut effect state_types that should be cancelled
    let mut cancel_types: List<Type> = []
    for eff in callee_effects.effects {
        match eff {
            Effect::MutEffect { state_type } => {
                let resolved_st = apply_subst(s, state_type)
                // Find which param index has a matching type
                let mut pi = param_offset
                let mut ai = 0
                while ai < hargs.len() {
                    match callee_params.get(pi) {
                        some(pt) => {
                            let resolved_pt = apply_subst(s, pt)
                            if types_equal(resolved_pt, resolved_st) {
                                // Check if the argument is a local variable
                                match hargs.get(ai) {
                                    some(harg) => match harg {
                                        HExpr::Ident { def_id: some(did), .. } => {
                                            if !ctx.env.scope.mut_param_defs.contains(did) {
                                                cancel_types.push(resolved_st)
                                            }
                                        },
                                        _ => {}
                                    },
                                    none => {}
                                }
                            }
                        },
                        none => {}
                    }
                    pi = pi + 1
                    ai = ai + 1
                }
            },
            _ => {}
        }
    }

    if cancel_types.len() == 0 {
        return effects
    }

    // Filter out cancelled mut effects
    let filtered = effects.effects.filter(fn(e) {
        match e {
            Effect::MutEffect { state_type } => {
                let resolved_st = apply_subst(s, state_type)
                !cancel_types.any(fn(ct) { types_equal(ct, resolved_st) })
            },
            _ => true
        }
    })
    EffectRow { effects: filtered, tail: effects.tail }
}

// ============================================================
// Resolve substitution var chain
// ============================================================

fn resolve_var_id(id: Int, sub: UnionFind) -> Int {
    match uf_lookup(sub, id) {
        some(resolved) => match resolved {
            Type::TypeVar { id: new_id, .. } => resolve_var_id(new_id, sub),
            _ => id
        },
        none => uf_find(sub, id)
    }
}

// ============================================================
// Block inference (from infer-stmt.ts)
// ============================================================

pub fn infer_block(mut ctx: InferCtx, body: Expr, initial_subst: UnionFind?) -> InferResult {
    match body {
        Expr::Block { stmts, tail, span } => {
            let mut subst = match initial_subst { some(s) => s, none => ctx.subst }
            let mut effects: EffectRow = EMPTY_ROW
            let mut hstmts: List<HStmt> = []

            for stmt in stmts {
                let sr = infer_stmt(ctx, stmt, subst)
                subst = sr.subst
                let me = merge_effects(ctx.env, effects, sr.effects, subst)
                effects = me.0
                subst = me.1
                hstmts.push(sr.hstmt)
            }

            let mut tail_hexpr: HExpr? = none
            let mut block_type: Type = UNIT

            match tail {
                some(t) => {
                    let tr = infer_expr(ctx, t, subst)
                    subst = tr.subst
                    let me = merge_effects(ctx.env, effects, tr.effects, subst)
                    effects = me.0
                    subst = me.1
                    tail_hexpr = some(tr.hexpr)
                    block_type = hexpr_type(tr.hexpr)
                },
                none => {}
            }

            let hblock = HExpr::Block {
                stmts: hstmts, tail: tail_hexpr,
                ty: block_type, effects: effects, span: span
            }
            InferResult { hexpr: hblock, subst: subst, effects: effects }
        },
        _ => panic("unreachable: infer_block called with non-block expression")
    }
}

// ============================================================
// Statement inference result helper
// ============================================================

struct StmtResult {
    hstmt: HStmt,
    subst: UnionFind,
    effects: EffectRow
}

// ============================================================
// Statement inference (from infer-stmt.ts)
// ============================================================

pub fn infer_stmt(mut ctx: InferCtx, stmt: Stmt, subst: UnionFind) -> StmtResult {
    match stmt {
        Stmt::Let { name, name_span, type_annotation, init, span } => {
            let init_r = infer_expr(ctx, init, subst)
            let mut s = init_r.subst
            let mut var_type = hexpr_type(init_r.hexpr)
            match type_annotation {
                some(ta) => {
                    let annotated = resolve_type_expr(ctx, ta)
                    let notes: List<DiagnosticNote> = [
                        DiagnosticNote { message: "expected '${type_to_string(annotated)}' because variable '${name}' is declared with this type", span: some(name_span) },
                        DiagnosticNote { message: "initializer has type '${type_to_string(apply_subst(s, var_type))}'", span: some(hexpr_span(init_r.hexpr)) }
                    ]
                    s = unify_at_noted(ctx.sink, ctx.env, var_type, annotated, s, span, notes)
                    var_type = apply_subst(s, annotated)
                },
                none => {}
            }
            let resolved = apply_subst(s, var_type)
            // Optimization: skip the expensive free_type_vars_in_env scan when the resolved
            // type is ground (no type variables). Most function-local let bindings have ground
            // types, so this avoids a full env scan on each one.
            let ftv = free_type_vars(resolved, empty_subst())
            let scheme = if ftv.len() == 0 {
                mono(resolved)
            } else {
                generalize(ctx.env, resolved, s)
            }
            ctx.env.bind(name, scheme)
            let bound_scheme = ctx.env.lookup(name)
            let bound_def_id: Int? = match bound_scheme {
                some(bs) => {
                    match bs.def_id {
                        some(did) => {
                            ctx.env.record_def_span(did, name_span)
                            ctx.env.scope.let_defs.insert(did)
                            ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                            some(did)
                        },
                        none => none
                    }
                },
                none => none
            }
            StmtResult {
                hstmt: HStmt::Let { name: name, name_span: name_span, def_id: bound_def_id, ty: resolved, init: init_r.hexpr, span: span },
                subst: s,
                effects: init_r.effects
            }
        },
        Stmt::Var { name, name_span, type_annotation, init, span } => {
            let init_r = infer_expr(ctx, init, subst)
            let mut s = init_r.subst
            let mut var_type = hexpr_type(init_r.hexpr)
            match type_annotation {
                some(ta) => {
                    let annotated = resolve_type_expr(ctx, ta)
                    let notes: List<DiagnosticNote> = [
                        DiagnosticNote { message: "expected '${type_to_string(annotated)}' because variable '${name}' is declared with this type", span: some(name_span) },
                        DiagnosticNote { message: "initializer has type '${type_to_string(apply_subst(s, var_type))}'", span: some(hexpr_span(init_r.hexpr)) }
                    ]
                    s = unify_at_noted(ctx.sink, ctx.env, var_type, annotated, s, span, notes)
                    var_type = apply_subst(s, annotated)
                },
                none => {}
            }
            ctx.env.bind_mono(name, apply_subst(s, var_type))
            let var_scheme = ctx.env.lookup(name)
            match var_scheme {
                some(vs) => {
                    match vs.def_id {
                        some(did) => {
                            ctx.env.record_def_span(did, name_span)
                            ctx.env.scope.mutable_vars.insert(did)
                            ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                        },
                        none => {}
                    }
                    StmtResult {
                        hstmt: HStmt::Var { name: name, name_span: name_span, def_id: vs.def_id, ty: apply_subst(s, var_type), init: init_r.hexpr, span: span },
                        subst: s,
                        effects: init_r.effects
                    }
                },
                none => panic("unreachable: var_stmt lookup failed after bind")
            }
        },
        Stmt::Assign { target, value, span } => {
            check_assign_target_mutable(ctx, target)
            let target_r = infer_expr(ctx, target, subst)
            let value_r = infer_expr(ctx, value, target_r.subst)
            let assign_notes: List<DiagnosticNote> = [
                DiagnosticNote { message: "target has type '${type_to_string(apply_subst(value_r.subst, hexpr_type(target_r.hexpr)))}'", span: some(hexpr_span(target_r.hexpr)) },
                DiagnosticNote { message: "assigned value has type '${type_to_string(apply_subst(value_r.subst, hexpr_type(value_r.hexpr)))}'", span: some(hexpr_span(value_r.hexpr)) }
            ]
            let mut s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(target_r.hexpr), hexpr_type(value_r.hexpr), value_r.subst, span, assign_notes)
            let me = merge_effects(ctx.env, target_r.effects, value_r.effects, s)
            s = me.1
            StmtResult {
                hstmt: HStmt::Assign { target: target_r.hexpr, value: value_r.hexpr, span: span },
                subst: s,
                effects: me.0
            }
        },
        Stmt::ExprStmt { expr, span, .. } => {
            let r = infer_expr(ctx, expr, subst)
            StmtResult {
                hstmt: HStmt::ExprStmt { expr: r.hexpr, span: span },
                subst: r.subst,
                effects: r.effects
            }
        },
        Stmt::Return { value, span } => match value {
            some(v) => {
                let r = infer_expr(ctx, v, subst)
                let mut s = r.subst
                match ctx.current_fn_return_type {
                    some(ret_type) => {
                        let return_notes: List<DiagnosticNote> = [
                            DiagnosticNote { message: "function return type is '${type_to_string(apply_subst(s, ret_type))}'", span: none },
                            DiagnosticNote { message: "return value has type '${type_to_string(apply_subst(s, hexpr_type(r.hexpr)))}'", span: some(hexpr_span(r.hexpr)) }
                        ]
                        s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(r.hexpr), ret_type, s, span, return_notes)
                    },
                    none => {}
                }
                StmtResult {
                    hstmt: HStmt::Return { value: some(r.hexpr), span: span },
                    subst: s,
                    effects: r.effects
                }
            },
            none => {
                let mut s = subst
                match ctx.current_fn_return_type {
                    some(ret_type) => {
                        s = unify_at(ctx.sink, ctx.env, UNIT, ret_type, s, span)
                    },
                    none => {}
                }
                StmtResult {
                    hstmt: HStmt::Return { value: none, span: span },
                    subst: s,
                    effects: EMPTY_ROW
                }
            }
        },
        Stmt::While { condition, body, span } => {
            let cond_r = infer_expr(ctx, condition, subst)
            let mut s = unify_at(ctx.sink, ctx.env, hexpr_type(cond_r.hexpr), BOOL, cond_r.subst, span)
            ctx.env.push_scope()
            ctx.loop_depth = ctx.loop_depth + 1
            let body_result = some(infer_block(ctx, body, some(s))) catch { _ => none }
            ctx.loop_depth = ctx.loop_depth - 1
            ctx.env.pop_scope()
            match body_result {
                some(body_r) => {
                    s = body_r.subst
                    let me = merge_effects(ctx.env, cond_r.effects, body_r.effects, s)
                    StmtResult {
                        hstmt: HStmt::While { condition: cond_r.hexpr, body: body_r.hexpr, span: span },
                        subst: me.1,
                        effects: me.0
                    }
                },
                none => fail.raise(CompileError {})
            }
        },
        Stmt::ForIn { binding, binding_span, destructure, iterable, body, span } => {
            let iter_r = infer_expr(ctx, iterable, subst)
            let mut s = iter_r.subst
            let iter_type = apply_subst(s, hexpr_type(iter_r.hexpr))
            let is_destructure = destructure.is_some()
            let mut element_type: Type = ctx.env.fresh_var()
            let mut iterable_type_name: Str? = none
            let mut iter_type_name: Str? = none
            // Check for Range (builtin, keep special path)
            let is_range = match iter_type {
                Type::EnumType { name, .. } => name == BUILTIN_RANGE,
                _ => false
            }
            if is_range {
                match iter_type {
                    Type::EnumType { type_params, .. } => {
                        element_type = match type_params.first() { some(t) => t, none => INT }
                    },
                    _ => {}
                }
            } else {
                // Look up Iterable trait impl to resolve element type
                let type_name = type_to_builtin_name(iter_type)
                match type_name {
                    some(tn) => {
                        let iterable_impl = find_impl(ctx.env.trait_reg, tn, "Iterable")
                        match iterable_impl {
                            some(impl_entry) => {
                                iterable_type_name = some(tn)
                                // Get the Iter associated type from the Iterable impl
                                match impl_entry.assoc_types.get("Iter") {
                                    some(iter_assoc_ty) => {
                                        // Get the concrete iterable type params (e.g., [Int] for List<Int>)
                                        let concrete_type_params = match iter_type {
                                            Type::StructType { type_params: tps, .. } => tps,
                                            Type::EnumType { type_params: tps, .. } => tps,
                                            _ => []
                                        }
                                        // Extract the iterator type name from the assoc type
                                        let concrete_iter_name = type_to_builtin_name(iter_assoc_ty)
                                        match concrete_iter_name {
                                            some(itn) => {
                                                iter_type_name = some(itn)
                                                // Build the concrete iterator type by using iterable's type params
                                                // For impl<T> Iterable for List<T>, Iter = ListIterator<T>
                                                // The T in ListIterator<T> maps positionally to T in List<T>
                                                // So ListIterator gets the same concrete type params as List
                                                let concrete_iter_type = Type::StructType { name: itn, type_params: concrete_type_params, fields: [] }
                                                // Look up Iterator impl for the iterator type
                                                let iterator_impl = find_impl(ctx.env.trait_reg, itn, "Iterator")
                                                match iterator_impl {
                                                    some(iter_impl_entry) => {
                                                        // Get the Item associated type from Iterator impl
                                                        match iter_impl_entry.assoc_types.get("Item") {
                                                            some(item_assoc_ty) => {
                                                                // Build the concrete element type
                                                                // For simple cases (Item = T), use position-based mapping
                                                                // The item_assoc_ty contains TypeVars from the impl registration
                                                                // We substitute them using the concrete iterator type params
                                                                let item_name = type_to_builtin_name(item_assoc_ty)
                                                                match item_assoc_ty {
                                                                    Type::TypeVar { .. } => {
                                                                        // Item = T (single type var) — map to first concrete type param
                                                                        element_type = match concrete_type_params.first() {
                                                                            some(ct) => ct,
                                                                            none => element_type
                                                                        }
                                                                    },
                                                                    Type::TupleType { elements } => {
                                                                        // Item = (K, V) — map TypeVars positionally to concrete type params
                                                                        let mut concrete_elems: List<Type> = []
                                                                        let mut ei = 0
                                                                        for elem in elements {
                                                                            match elem {
                                                                                Type::TypeVar { .. } => {
                                                                                    match concrete_type_params.get(ei) {
                                                                                        some(ct) => { concrete_elems.push(ct) },
                                                                                        none => { concrete_elems.push(elem) }
                                                                                    }
                                                                                    ei = ei + 1
                                                                                },
                                                                                _ => { concrete_elems.push(elem) }
                                                                            }
                                                                        }
                                                                        element_type = Type::TupleType { elements: concrete_elems }
                                                                    },
                                                                    _ => {
                                                                        // Other types (struct, etc.) — use as-is
                                                                        element_type = item_assoc_ty
                                                                    }
                                                                }
                                                            },
                                                            none => {
                                                                let _ = type_error(ctx.sink, E0301,
                                                                    "Iterator impl for '${itn}' missing associated type 'Item'",
                                                                    span, DiagnosticContext::OtherContext { detail: some("Iterator impl must define type Item") })
                                                            }
                                                        }
                                                    },
                                                    none => {
                                                        let _ = type_error(ctx.sink, E0301,
                                                            "Type '${itn}' (Iter of '${tn}') does not implement Iterator",
                                                            span, DiagnosticContext::OtherContext { detail: some("Iter associated type must implement Iterator") })
                                                    }
                                                }
                                            },
                                            none => {
                                                let _ = type_error(ctx.sink, E0301,
                                                    "Cannot resolve iterator type for '${tn}'",
                                                    span, DiagnosticContext::OtherContext { detail: some("Iter associated type could not be resolved") })
                                            }
                                        }
                                    },
                                    none => {
                                        let _ = type_error(ctx.sink, E0301,
                                            "Iterable impl for '${tn}' missing associated type 'Iter'",
                                            span, DiagnosticContext::OtherContext { detail: some("Iterable impl must define type Iter") })
                                    }
                                }
                            },
                            none => {
                                let _ = type_error(ctx.sink, E0301,
                                    "for..in requires an iterable type (one that implements Iterable), got ${type_to_string(iter_type)}",
                                    span, DiagnosticContext::OtherContext { detail: some("Type does not implement the Iterable trait. Implement 'Iterable' for custom iteration.") })
                            }
                        }
                    },
                    none => {
                        let _ = type_error(ctx.sink, E0301,
                            "for..in requires an iterable type, got ${type_to_string(iter_type)}",
                            span, DiagnosticContext::OtherContext { detail: some("Primitive types are not iterable") })
                    }
                }
            }

            ctx.env.push_scope()
            let mut hdestructure: List<HForInDestructure>? = none
            match destructure {
                some(destr) => {
                    match element_type {
                        Type::TupleType { elements: type_elems } => {
                            if destr.names.len() != type_elems.len() {
                                let _ = type_error(ctx.sink, E0301,
                                    "Destructure binding expects ${destr.names.len().to_str()} elements, but iterable element type is ${type_to_string(element_type)}",
                                    span, DiagnosticContext::OtherContext { detail: some("tuple arity mismatch") })
                            }
                        },
                        _ => {
                            let _ = type_error(ctx.sink, E0301,
                                "Destructure binding expects tuple elements, but iterable element type is ${type_to_string(element_type)}",
                                span, DiagnosticContext::OtherContext { detail: some("tuple arity mismatch") })
                        }
                    }
                    let mut hd: List<HForInDestructure> = []
                    let mut di = 0
                    while di < destr.names.len() {
                        match destr.names.get(di) {
                            some(dname) => {
                                let elem_t = match element_type {
                                    Type::TupleType { elements: type_elems } => match type_elems.get(di) {
                                        some(et) => et,
                                        none => ctx.env.fresh_var()
                                    },
                                    _ => ctx.env.fresh_var()
                                }
                                ctx.env.bind_mono(dname, elem_t)
                                let dscheme = ctx.env.lookup(dname)
                                match dscheme {
                                    some(ds) => {
                                        match (ds.def_id, destr.spans.get(di)) {
                                            (some(did), some(dspan)) => {
                                                ctx.env.record_def_span(did, dspan)
                                                ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                                            },
                                            _ => {}
                                        }
                                        hd.push(HForInDestructure { name: dname, def_id: ds.def_id })
                                    },
                                    none => { hd.push(HForInDestructure { name: dname, def_id: none }) }
                                }
                            },
                            none => {}
                        }
                        di = di + 1
                    }
                    hdestructure = some(hd)
                },
                none => {
                    ctx.env.bind_mono(binding, element_type)
                }
            }
            let binding_scheme = ctx.env.lookup(binding)
            match binding_scheme {
                some(bs) => match bs.def_id {
                    some(did) => {
                        ctx.env.record_def_span(did, binding_span)
                        ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                    },
                    none => {}
                },
                none => {}
            }
            ctx.loop_depth = ctx.loop_depth + 1
            let body_result = some(infer_block(ctx, body, some(s))) catch { _ => none }
            ctx.loop_depth = ctx.loop_depth - 1
            ctx.env.pop_scope()
            match body_result {
                some(body_r) => {
                    s = body_r.subst
                    let me = merge_effects(ctx.env, iter_r.effects, body_r.effects, s)
                    StmtResult {
                        hstmt: HStmt::ForIn {
                            binding: binding, binding_span: binding_span,
                            def_id: match binding_scheme { some(bs) => bs.def_id, none => none },
                            destructure: hdestructure,
                            iterable: iter_r.hexpr, body: body_r.hexpr,
                            iterable_type_name: iterable_type_name,
                            iter_type_name: iter_type_name,
                            span: span
                        },
                        subst: me.1,
                        effects: me.0
                    }
                },
                none => fail.raise(CompileError {})
            }
        },
        Stmt::Break { span } => {
            if ctx.loop_depth == 0 {
                let _ = type_error(ctx.sink, E0206, "'break' can only be used inside a loop", span,
                    DiagnosticContext::OtherContext { detail: some("break outside loop") })
            }
            StmtResult { hstmt: HStmt::Break { span: span }, subst: subst, effects: EMPTY_ROW }
        },
        Stmt::Continue { span } => {
            if ctx.loop_depth == 0 {
                let _ = type_error(ctx.sink, E0206, "'continue' can only be used inside a loop", span,
                    DiagnosticContext::OtherContext { detail: some("continue outside loop") })
            }
            StmtResult { hstmt: HStmt::Continue { span: span }, subst: subst, effects: EMPTY_ROW }
        },
        Stmt::LetDestructure { pattern, init, span } => {
            let init_r = infer_expr(ctx, init, subst)
            let mut s = init_r.subst
            let init_type = apply_subst(s, hexpr_type(init_r.hexpr))
            match init_type {
                Type::TupleType { .. } => {},
                _ => { let _ = type_error(ctx.sink, E0301,
                    "let destructuring requires tuple type, got ${type_to_string(init_type)}",
                    span, DiagnosticContext::OtherContext { detail: some("not a tuple") }) }
            }
            let tuple_elements: List<Type> = match init_type {
                Type::TupleType { elements } => elements,
                _ => []
            }
            match pattern {
                Pattern::TuplePattern { elements: pat_elements, .. } => {
                    if pat_elements.len() != tuple_elements.len() {
                        let _ = type_error(ctx.sink, E0301,
                            "Tuple has ${tuple_elements.len().to_str()} elements but pattern has ${pat_elements.len().to_str()}",
                            span, DiagnosticContext::OtherContext { detail: some("tuple arity mismatch") })
                    }
                    let mut bindings: List<HLetDestructureBinding> = []
                    let mut bi = 0
                    while bi < pat_elements.len() {
                        match pat_elements.get(bi) {
                            some(p) => {
                                let elem_type = match tuple_elements.get(bi) { some(et) => et, none => UNIT }
                                match p {
                                    Pattern::Binding { name, span: pspan } => {
                                        ctx.env.bind_mono(name, elem_type)
                                        let bscheme = ctx.env.lookup(name)
                                        match bscheme {
                                            some(bs) => {
                                                match bs.def_id {
                                                    some(did) => {
                                                        ctx.env.record_def_span(did, pspan)
                                                        ctx.env.scope.let_defs.insert(did)
                                                    },
                                                    none => {}
                                                }
                                                bindings.push(HLetDestructureBinding { name: name, def_id: bs.def_id, ty: elem_type })
                                            },
                                            none => {
                                                bindings.push(HLetDestructureBinding { name: name, def_id: none, ty: elem_type })
                                            }
                                        }
                                    },
                                    Pattern::Wildcard { .. } => {
                                        bindings.push(HLetDestructureBinding { name: "_", def_id: none, ty: elem_type })
                                    },
                                    _ => {
                                        let _ = type_error(ctx.sink, E0301,
                                            "Only binding and wildcard patterns are supported in let destructuring",
                                            span, DiagnosticContext::OtherContext { detail: some("unsupported pattern kind") })
                                    }
                                }
                            },
                            none => {}
                        }
                        bi = bi + 1
                    }
                    StmtResult {
                        hstmt: HStmt::LetDestructure { pattern: pattern, bindings: bindings, init: init_r.hexpr, span: span },
                        subst: s,
                        effects: init_r.effects
                    }
                },
                _ => {
                    let _ = type_error(ctx.sink, E0301,
                        "let destructuring requires tuple pattern",
                        span, DiagnosticContext::OtherContext { detail: some("not a tuple pattern") })
                    StmtResult {
                        hstmt: HStmt::ExprStmt { expr: HExpr::IntLit { value: 0, ty: UNIT, effects: EMPTY_ROW, span: span }, span: span },
                        subst: s,
                        effects: init_r.effects
                    }
                }
            }
        },
        Stmt::IfLet { pattern, expr, then_block, else_block, span } => {
            let expr_r = infer_expr(ctx, expr, subst)
            let mut s = expr_r.subst
            let expr_type = apply_subst(s, hexpr_type(expr_r.hexpr))

            ctx.env.push_scope()
            let then_result = some({
                bind_pattern(ctx, pattern, expr_type, s)
                infer_block(ctx, then_block, some(s))
            }) catch { _ => none }
            ctx.env.pop_scope()

            match then_result {
                some(then_r) => {
                    s = then_r.subst
                    let mut combined = merge_effects(ctx.env, expr_r.effects, then_r.effects, s)
                    let mut combined_effects = combined.0
                    s = combined.1

                    let mut else_hblock: HExpr? = none
                    match else_block {
                        some(eb) => {
                            ctx.env.push_scope()
                            let else_result = some(infer_block(ctx, eb, some(s))) catch { _ => none }
                            ctx.env.pop_scope()
                            match else_result {
                                some(else_r) => {
                                    s = else_r.subst
                                    else_hblock = some(else_r.hexpr)
                                    let me2 = merge_effects(ctx.env, combined_effects, else_r.effects, s)
                                    combined_effects = me2.0
                                    s = me2.1
                                },
                                none => fail.raise(CompileError {})
                            }
                        },
                        none => {}
                    }

                    StmtResult {
                        hstmt: HStmt::IfLet {
                            pattern: pattern, expr: expr_r.hexpr,
                            then_block: then_r.hexpr, else_block: else_hblock, span: span
                        },
                        subst: s,
                        effects: combined_effects
                    }
                },
                none => fail.raise(CompileError {})
            }
        }
    }
}

fn check_assign_target_mutable(ctx: InferCtx, target: Expr) {
    match target {
        Expr::Ident { name, span, .. } => {
            let scheme = ctx.env.lookup(name)
            match scheme {
                some(s) => match s.def_id {
                    some(did) => {
                        if !ctx.env.scope.mutable_vars.contains(did) {
                            let _ = type_error(ctx.sink, E0205,
                                "Cannot assign to immutable variable '${name}' (declared with 'let'). Use 'let mut' for mutable bindings.",
                                span, DiagnosticContext::OtherContext { detail: some("'${name}' is declared with 'let'") })
                        }
                    },
                    none => {}
                },
                none => {}
            }
        },
        Expr::FieldAccess { receiver, span, .. } => {
            let root = find_root_expr(receiver)
            match root {
                Expr::Ident { name, span: rspan, .. } => {
                    let scheme = ctx.env.lookup(name)
                    match scheme {
                        some(s) => match s.def_id {
                            some(did) => {
                                if !ctx.env.scope.mutable_vars.contains(did) {
                                    let _ = type_error(ctx.sink, E0205,
                                        "Cannot assign to field of immutable variable '${name}'. Use 'let mut' for mutable bindings.",
                                        span, DiagnosticContext::OtherContext { detail: some("'${name}' is not mutable") })
                                }
                            },
                            none => {}
                        },
                        none => {}
                    }
                },
                _ => {
                    let _ = type_error(ctx.sink, E0205,
                        "Cannot assign to field of a temporary value. Store the value in a 'let mut' variable first.",
                        span, DiagnosticContext::OtherContext { detail: some("assignment to temporary value") })
                }
            }
        },
        Expr::IndexExpr { receiver, span, .. } => {
            // Index assignment (e.g. list[i] = val) — check receiver mutability
            let root = find_root_expr(receiver)
            match root {
                Expr::Ident { name, span: rspan, .. } => {
                    let scheme = ctx.env.lookup(name)
                    match scheme {
                        some(s) => match s.def_id {
                            some(did) => {
                                if !ctx.env.scope.mutable_vars.contains(did) {
                                    let _ = type_error(ctx.sink, E0205,
                                        "Cannot assign to index of immutable variable '${name}'. Use 'let mut' for mutable bindings.",
                                        span, DiagnosticContext::OtherContext { detail: some("'${name}' is not mutable") })
                                }
                            },
                            none => {}
                        },
                        none => {}
                    }
                },
                _ => {
                    let _ = type_error(ctx.sink, E0205,
                        "Cannot assign to index of a temporary value. Store the value in a 'let mut' variable first.",
                        span, DiagnosticContext::OtherContext { detail: some("assignment to temporary value") })
                }
            }
        },
        _ => {}
    }
}

fn find_root_expr(e: Expr) -> Expr {
    match e {
        Expr::FieldAccess { receiver, .. } => find_root_expr(receiver),
        Expr::IndexExpr { receiver, .. } => find_root_expr(receiver),
        _ => e
    }
}

// ============================================================
// Expression inference dispatch (from infer.ts)
// ============================================================

pub fn infer_expr(mut ctx: InferCtx, expr: Expr, subst: UnionFind) -> InferResult {
    match expr {
        Expr::IntLit { value, span } =>
            InferResult {
                hexpr: HExpr::IntLit { value: value, ty: INT, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            },
        Expr::FloatLit { value, span } =>
            InferResult {
                hexpr: HExpr::FloatLit { value: value, ty: FLOAT, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            },
        Expr::StrLit { value, span } =>
            InferResult {
                hexpr: HExpr::StrLit { value: value, ty: STR, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            },
        Expr::BoolLit { value, span } =>
            InferResult {
                hexpr: HExpr::BoolLit { value: value, ty: BOOL, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            },
        Expr::Ident { name, qualifier, span } =>
            infer_ident(ctx, name, span, subst, qualifier),
        Expr::BinOp { op, left, right, span } =>
            infer_bin_op(ctx, op, left, right, span, subst),
        Expr::UnaryOp { op, operand, span } =>
            infer_unary_op(ctx, op, operand, span, subst),
        Expr::Call { callee, args, span, .. } =>
            infer_call(ctx, callee, args, span, subst),
        Expr::MethodCall { receiver, method, args, span, .. } =>
            infer_method_call(ctx, receiver, method, args, span, subst),
        Expr::FieldAccess { receiver, field, span } =>
            infer_field_access(ctx, receiver, field, span, subst),
        Expr::StructLit { name, qualifier, fields, spread, span, .. } =>
            infer_struct_lit(ctx, name, fields, spread, span, subst, qualifier),
        Expr::MatchExpr { scrutinee, arms, span } =>
            infer_match(ctx, scrutinee, arms, span, subst),
        Expr::Block { .. } =>
            infer_block(ctx, expr, some(subst)),
        Expr::IfExpr { condition, then_branch, else_branch, span } =>
            infer_if(ctx, condition, then_branch, else_branch, span, subst),
        Expr::StringInterp { parts, span } =>
            infer_string_interp(ctx, parts, span, subst),
        Expr::CatchExpr { expr: catch_expr, arms, span } =>
            infer_catch(ctx, catch_expr, arms, span, subst),
        Expr::HandleExpr { body, handlers, span } =>
            infer_handle(ctx, body, handlers, span, subst),
        Expr::Lambda { params, body, span, .. } =>
            infer_lambda(ctx, params, body, span, subst, none),
        Expr::ListLit { elements, span } =>
            infer_list_literal(ctx, elements, span, subst),
        Expr::TupleLit { elements, span } => {
            let mut s = subst
            let mut helements: List<HExpr> = []
            let mut combined_effects: EffectRow = EMPTY_ROW
            for el in elements {
                let r = infer_expr(ctx, el, s)
                s = r.subst
                helements.push(r.hexpr)
                let me = merge_effects(ctx.env, combined_effects, r.effects, s)
                combined_effects = me.0
                s = me.1
            }
            let mut elem_types: List<Type> = []
            for he in helements { elem_types.push(apply_subst(s, hexpr_type(he))) }
            let tuple_type = Type::TupleType { elements: elem_types }
            InferResult {
                hexpr: HExpr::TupleLit { elements: helements, ty: tuple_type, effects: combined_effects, span: span },
                subst: s, effects: combined_effects
            }
        },
        Expr::Range { start, end, inclusive, span } => {
            let start_r = infer_expr(ctx, start, subst)
            let mut s = unify_at(ctx.sink, ctx.env, hexpr_type(start_r.hexpr), INT, start_r.subst, span)
            let end_r = infer_expr(ctx, end, s)
            s = unify_at(ctx.sink, ctx.env, hexpr_type(end_r.hexpr), INT, end_r.subst, span)
            let me = merge_effects(ctx.env, start_r.effects, end_r.effects, s)
            let mut range_effects = me.0
            s = me.1
            let range_type = Type::EnumType { name: BUILTIN_RANGE, type_params: [INT], variants: [] }
            InferResult {
                hexpr: HExpr::RangeExpr {
                    start: start_r.hexpr, end: end_r.hexpr, inclusive: inclusive,
                    ty: range_type, effects: range_effects, span: span
                },
                subst: s, effects: range_effects
            }
        },
        Expr::IndexExpr { receiver, index, span } =>
            infer_index_expr(ctx, receiver, index, span, subst)
    }
}

// ============================================================
// infer_index_expr: list[i] / map[key] / str[i]
// ============================================================

fn infer_index_expr(mut ctx: InferCtx, receiver: Expr, index: Expr, span: Span, subst: UnionFind) -> InferResult {
    let recv_r = infer_expr(ctx, receiver, subst)
    let mut s = recv_r.subst
    let mut combined_effects = recv_r.effects

    let idx_r = infer_expr(ctx, index, s)
    s = idx_r.subst
    let me = merge_effects(ctx.env, combined_effects, idx_r.effects, s)
    combined_effects = me.0
    s = me.1

    let recv_type = apply_subst(s, hexpr_type(recv_r.hexpr))
    let idx_type = apply_subst(s, hexpr_type(idx_r.hexpr))

    let mut result_ty: Type = Type::ErrorType

    match recv_type {
        Type::StructType { name, type_params, .. } => {
            if name == BUILTIN_LIST {
                // list[i]: index must be Int, result is element type T
                s = unify_at(ctx.sink, ctx.env, idx_type, INT, s, span)
                result_ty = if type_params.len() > 0 { type_params.get(0).unwrap() } else { Type::ErrorType }
            } else if name == BUILTIN_MAP {
                // map[key]: index must be key type K, result is value type V
                if type_params.len() >= 2 {
                    s = unify_at(ctx.sink, ctx.env, idx_type, type_params.get(0).unwrap(), s, span)
                    result_ty = type_params.get(1).unwrap()
                } else {
                    result_ty = Type::ErrorType
                }
            } else {
                let _ = type_error(ctx.sink, E0306,
                    "Type '${type_to_string(recv_type)}' does not support indexing",
                    span, DiagnosticContext::OtherContext { detail: some("only List, Map, and Str support subscript operator []") })
                result_ty = Type::ErrorType
            }
        },
        Type::StrType => {
            // str[i]: index must be Int, result is Str
            s = unify_at(ctx.sink, ctx.env, idx_type, INT, s, span)
            result_ty = STR
        },
        Type::ErrorType => {
            result_ty = Type::ErrorType
        },
        _ => {
            let _ = type_error(ctx.sink, E0306,
                "Type '${type_to_string(recv_type)}' does not support indexing",
                span, DiagnosticContext::OtherContext { detail: some("only List, Map, and Str support subscript operator []") })
            result_ty = Type::ErrorType
        }
    }

    InferResult {
        hexpr: HExpr::IndexExpr {
            receiver: recv_r.hexpr, index: idx_r.hexpr,
            ty: result_ty, effects: combined_effects, span: span
        },
        subst: s, effects: combined_effects
    }
}

// ============================================================
// infer_ident (from infer-expr.ts)
// ============================================================

fn infer_ident(mut ctx: InferCtx, name: Str, span: Span, subst: UnionFind, qualifier: Str?) -> InferResult {
    // Resolve relative paths (self::/super::) to actual qualified names
    let mut resolved_qualifier = qualifier
    match qualifier {
        some(q) => {
            if q == "self" || q.starts_with("super") {
                match resolve_relative_qualifier(q, ctx.mod_path_stack) {
                    some(prefix) => {
                        if prefix == "" {
                            // super from top-level mod — name is at root scope
                            resolved_qualifier = none
                        } else {
                            resolved_qualifier = some(prefix)
                        }
                    },
                    none => {
                        let _ = type_error(ctx.sink, E0705,
                            "Cannot use '${q}' — relative path exceeds module nesting depth",
                            span, DiagnosticContext::OtherContext { detail: some("relative path out of scope") })
                        return InferResult {
                            hexpr: HExpr::Ident { name: name, resolved_name: none, def_id: none, dict_closure_dicts: none, ty: Type::ErrorType, effects: EMPTY_ROW, span: span },
                            subst: subst, effects: EMPTY_ROW
                        }
                    }
                }
            }
        },
        none => {}
    }

    // Try module-qualified lookup first: qualifier::name
    match resolved_qualifier {
        some(q) => {
            let qualified_name = "${q}::${name}"
            let mod_scheme = ctx.env.lookup(qualified_name)
            match mod_scheme {
                some(ms) => {
                    let t = ctx.env.instantiate(ms)
                    return InferResult {
                        hexpr: HExpr::Ident { name: qualified_name, resolved_name: none, def_id: ms.def_id, dict_closure_dicts: none, ty: t, effects: EMPTY_ROW, span: span },
                        subst: subst, effects: EMPTY_ROW
                    }
                },
                none => {
                    // Fallback: try prepending current mod path for relative references
                    // e.g., inside mod outer, "inner::f" should resolve to "outer::inner::f"
                    if ctx.mod_path_stack.len() > 0 {
                        let mod_prefix = ctx.mod_path_stack.join("::")
                        let full_qualified = "${mod_prefix}::${qualified_name}"
                        let full_scheme = ctx.env.lookup(full_qualified)
                        match full_scheme {
                            some(fs) => {
                                let t = ctx.env.instantiate(fs)
                                return InferResult {
                                    hexpr: HExpr::Ident { name: full_qualified, resolved_name: none, def_id: fs.def_id, dict_closure_dicts: none, ty: t, effects: EMPTY_ROW, span: span },
                                    subst: subst, effects: EMPTY_ROW
                                }
                            },
                            none => {}
                        }
                    }
                }
            }
        },
        none => {}
    }

    let scheme = ctx.env.lookup(name)
    match scheme {
        none => {
            match resolved_qualifier {
                some(q) => {
                    let _ = type_error(ctx.sink, E0201, "'${q}' has no member '${name}'", span,
                        DiagnosticContext::UndefinedVariable { name: name, scope_locals: none })
                    return InferResult {
                        hexpr: HExpr::Ident { name: name, resolved_name: none, def_id: none, dict_closure_dicts: none, ty: Type::ErrorType, effects: EMPTY_ROW, span: span },
                        subst: subst, effects: EMPTY_ROW
                    }
                },
                none => {}
            }
            let _ = type_error(ctx.sink, E0201, "Undefined variable: ${name}", span,
                DiagnosticContext::UndefinedVariable { name: name, scope_locals: none })
            InferResult {
                hexpr: HExpr::Ident { name: name, resolved_name: none, def_id: none, dict_closure_dicts: none, ty: Type::ErrorType, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            }
        },
        some(s) => {
            let t = ctx.env.instantiate(s)
            // Auto-boxing: mark mutable vars captured by closures
            match s.def_id {
                some(did) => {
                    if ctx.env.scope.mutable_vars.contains(did) {
                        match ctx.var_lambda_depth.get(did) {
                            some(def_depth) => {
                                if ctx.lambda_depth > def_depth {
                                    ctx.boxed_vars.insert(did)
                                }
                            },
                            none => {}
                        }
                    }
                },
                none => {}
            }
            let mut resolved_name: Str? = none
            let mut enum_name: Str? = none
            // Check if this name was imported via use alias (e.g. use super::value)
            // If so, use the qualified name in HIR for correct codegen
            let actual_name = match ctx.use_aliases.get(name) {
                some(qualified) => qualified,
                none => name
            }
            match resolved_qualifier {
                some(q) => {
                    match ctx.env.types.enums.get(q) {
                        some(enum_def) => {
                            if enum_def.variant_index.contains_key(name) {
                                enum_name = some(enum_def.name)
                            } else {
                                let _ = type_error(ctx.sink, E0201, "'${q}' has no variant '${name}'", span,
                                    DiagnosticContext::UndefinedVariable { name: name, scope_locals: none })
                            }
                        },
                        none => { let _ = type_error(ctx.sink, E0201, "'${q}' has no variant '${name}'", span,
                            DiagnosticContext::UndefinedVariable { name: name, scope_locals: none }) }
                    }
                },
                none => { enum_name = ctx.env.types.variant_to_enum.get(name) }
            }
            match enum_name {
                some(en) => { resolved_name = some(variant_js_name(en, name)) },
                none => {}
            }
            InferResult {
                hexpr: HExpr::Ident { name: actual_name, resolved_name: resolved_name, def_id: s.def_id, dict_closure_dicts: none, ty: t, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            }
        }
    }
}

// ============================================================
// infer_bin_op (from infer-expr.ts)
// ============================================================

fn infer_bin_op(mut ctx: InferCtx, op: BinOp, left: Expr, right: Expr, span: Span, subst: UnionFind) -> InferResult {
    let lr = infer_expr(ctx, left, subst)
    let rr = infer_expr(ctx, right, lr.subst)
    let mut s = rr.subst
    let mut result_type: Type = UNIT
    let mut eq_dispatch: TraitDispatch? = none
    let mut ord_dispatch: TraitDispatch? = none

    match op {
        BinOp::Add => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "+"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Sub => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "-"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Mul => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "*"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Div => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "/"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Mod => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "%"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Eq | BinOp::Neq => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span)
            result_type = BOOL
            let resolved = apply_subst(s, hexpr_type(lr.hexpr))
            let is_builtin = is_primitive_eq(resolved) || is_tuple_type(resolved)
            let op_sym = match op { BinOp::Eq => "==", _ => "!=" }
            eq_dispatch = some(resolve_trait_dispatch(ctx, resolved, "Eq", E0307, s, span, op_sym, is_builtin))
        },
        BinOp::Lt | BinOp::Lte | BinOp::Gt | BinOp::Gte => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span)
            result_type = BOOL
            let resolved = apply_subst(s, hexpr_type(lr.hexpr))
            let op_sym = match op { BinOp::Lt => "<", BinOp::Lte => "<=", BinOp::Gt => ">", _ => ">=" }
            ord_dispatch = some(resolve_trait_dispatch(ctx, resolved, "Ord", E0308, s, span, op_sym, is_primitive_ord(resolved)))
        },
        BinOp::And => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), BOOL, s, span)
            s = unify_at(ctx.sink, ctx.env, hexpr_type(rr.hexpr), BOOL, s, span)
            result_type = BOOL
        },
        BinOp::Or => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), BOOL, s, span)
            s = unify_at(ctx.sink, ctx.env, hexpr_type(rr.hexpr), BOOL, s, span)
            result_type = BOOL
        }
    }

    let me = merge_effects(ctx.env, lr.effects, rr.effects, s)
    let mut effects = me.0
    s = me.1
    InferResult {
        hexpr: HExpr::BinOp { op: op, left: lr.hexpr, right: rr.hexpr, eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch, ty: result_type, effects: effects, span: span },
        subst: s, effects: effects
    }
}

fn infer_numeric_op(ctx: InferCtx, left: HExpr, right: HExpr, s: UnionFind, span: Span, op_str: Str) -> Type {
    let resolved = apply_subst(s, hexpr_type(left))
    match resolved {
        Type::TypeVar { id: tv_id, .. } => {
            // Check if this TypeVar is a rigid type parameter (from fn<T> etc.)
            // Rigid type params should not silently unify to Int — report E0303.
            // Fresh inference variables (e.g. from fold callback) can unify to Int.
            let mut rigid_ids: Set<Int> = set_new()
            for entry in ctx.type_param_scope.entries() {
                let tp_type = entry.1
                match tp_type {
                    Type::TypeVar { id: tp_id, .. } => {
                        rigid_ids.insert(resolve_var_id(tp_id, s))
                    },
                    _ => {}
                }
            }
            let is_rigid = rigid_ids.contains(resolve_var_id(tv_id, s))
            if is_rigid {
                type_error(ctx.sink, E0303,
                    "Operator ${op_str} requires numeric types (Int or Float), got unresolved type",
                    span, DiagnosticContext::TypeMismatch { expected: "Int or Float", actual: "unresolved type", expression: none })
            } else {
                let _ = unify_at(ctx.sink, ctx.env, resolved, INT, s, span)
                INT
            }
        },
        Type::IntType => INT,
        Type::FloatType => FLOAT,
        _ => type_error(ctx.sink, E0303,
            "Operator ${op_str} requires numeric types, got ${type_to_string(resolved)}",
            span, DiagnosticContext::TypeMismatch { expected: "Int or Float", actual: type_to_string(resolved), expression: none })
    }
}

fn is_primitive_eq(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::StrType => true,
        Type::BoolType => true,
        Type::UnitType => true,
        Type::NeverType => true,
        Type::AnyType => true,
        _ => false
    }
}

fn is_primitive_ord(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::StrType => true,
        Type::BoolType => true,
        _ => false
    }
}

fn is_tuple_type(t: Type) -> Bool {
    match t { Type::TupleType { .. } => true, _ => false }
}

fn resolve_trait_dispatch(ctx: InferCtx, resolved: Type, trait_name: Str, error_code: Str, subst: UnionFind, span: Span, op: Str, is_builtin: Bool) -> TraitDispatch {
    if is_builtin { return TraitDispatch::Builtin }

    match resolved {
        Type::TypeVar { id, .. } => {
            let bound = ctx.current_fn_bounds.find(fn(fb) {
                if fb.trait_name != trait_name { false } else
                if fb.type_param_var_id == id { true } else
                if uf_find(subst, fb.type_param_var_id) == id { true } else {
                    // Also check through type bindings: uf_bind stores var-to-var
                    // bindings in the types map, not the parent map, so uf_find alone
                    // may miss them. Resolve the bound var fully via apply_subst.
                    let bound_resolved = apply_subst(subst, Type::TypeVar { id: fb.type_param_var_id, name: none })
                    match bound_resolved {
                        Type::TypeVar { id: bid, .. } => bid == id,
                        _ => false
                    }
                }
            })
            match bound {
                some(b) => { return TraitDispatch::Dict { param: trait_bound_param_name(b.type_param_name, trait_name) } },
                none => {}
            }
            match ctx.env.scope.var_bounds.get(id) {
                some(var_bounds) => {
                    if var_bounds.contains(trait_name) { return TraitDispatch::Builtin }
                },
                none => {}
            }
            let _ = type_error(ctx.sink, error_code,
                "Type does not implement ${trait_name}, cannot use '${op}'",
                span, DiagnosticContext::TraitError { detail: "type does not implement ${trait_name}" })
            TraitDispatch::Builtin
        },
        Type::StructType { name, type_params, .. } => {
            if has_impl(ctx.env.trait_reg, name, trait_name) {
                let extra_dicts = resolve_trait_extra_dicts(ctx, type_params, subst, trait_name)
                return TraitDispatch::Direct { dict: trait_dict_name(name, trait_name), extra_dicts: match extra_dicts { some(d) => d, none => [] } }
            }
            let _ = type_error(ctx.sink, error_code,
                "Type '${type_to_string(resolved)}' does not implement ${trait_name}, cannot use '${op}'",
                span, DiagnosticContext::TraitError { detail: "type '${type_to_string(resolved)}' does not implement ${trait_name}" })
            TraitDispatch::Builtin
        },
        Type::EnumType { name, type_params, .. } => {
            if has_impl(ctx.env.trait_reg, name, trait_name) {
                let extra_dicts = resolve_trait_extra_dicts(ctx, type_params, subst, trait_name)
                return TraitDispatch::Direct { dict: trait_dict_name(name, trait_name), extra_dicts: match extra_dicts { some(d) => d, none => [] } }
            }
            let _ = type_error(ctx.sink, error_code,
                "Type '${type_to_string(resolved)}' does not implement ${trait_name}, cannot use '${op}'",
                span, DiagnosticContext::TraitError { detail: "type '${type_to_string(resolved)}' does not implement ${trait_name}" })
            TraitDispatch::Builtin
        },
        _ => {
            let _ = type_error(ctx.sink, error_code,
                "Type '${type_to_string(resolved)}' does not implement ${trait_name}, cannot use '${op}'",
                span, DiagnosticContext::TraitError { detail: "type '${type_to_string(resolved)}' does not implement ${trait_name}" })
            TraitDispatch::Builtin
        }
    }
}

fn resolve_trait_extra_dicts(ctx: InferCtx, type_args: List<Type>, subst: UnionFind, trait_name: Str) -> List<DictRef>? {
    if type_args.len() == 0 { return none }
    let mut dicts: List<DictRef> = []
    for arg in type_args {
        let resolved = apply_subst(subst, arg)
        let dict = resolve_type_to_dict_ref(ctx, resolved, subst, trait_name)
        match dict {
            some(d) => dicts.push(d),
            none => { return none }
        }
    }
    some(dicts)
}

fn resolve_type_to_dict_ref(ctx: InferCtx, t: Type, subst: UnionFind, trait_name: Str) -> DictRef? {
    match type_to_builtin_name(t) {
        some(builtin_name) => match t {
            Type::StructType { .. } => {},
            Type::EnumType { .. } => {},
            _ => { return some(DictRef::Simple(trait_dict_name(builtin_name, trait_name))) }
        },
        none => {}
    }
    match t {
        Type::TypeVar { id, .. } => {
            let bound = ctx.current_fn_bounds.find(fn(fb) {
                fb.type_param_var_id == id && fb.trait_name == trait_name
            })
            match bound {
                some(b) => some(DictRef::Simple(trait_bound_param_name(b.type_param_name, trait_name))),
                none => none
            }
        },
        Type::StructType { name, type_params, .. } => {
            if has_impl(ctx.env.trait_reg, name, trait_name) {
                if type_params.len() > 0 {
                    let inner = resolve_trait_extra_dicts(ctx, type_params, subst, trait_name)
                    match inner {
                        some(inner_dicts) => some(DictRef::Wrapped {
                            dict: trait_dict_name(name, trait_name),
                            trait_name: trait_name,
                            inner_dicts: inner_dicts
                        }),
                        none => some(DictRef::Simple(trait_dict_name(name, trait_name)))
                    }
                } else {
                    some(DictRef::Simple(trait_dict_name(name, trait_name)))
                }
            } else { none }
        },
        Type::EnumType { name, type_params, .. } => {
            if has_impl(ctx.env.trait_reg, name, trait_name) {
                if type_params.len() > 0 {
                    let inner = resolve_trait_extra_dicts(ctx, type_params, subst, trait_name)
                    match inner {
                        some(inner_dicts) => some(DictRef::Wrapped {
                            dict: trait_dict_name(name, trait_name),
                            trait_name: trait_name,
                            inner_dicts: inner_dicts
                        }),
                        none => some(DictRef::Simple(trait_dict_name(name, trait_name)))
                    }
                } else {
                    some(DictRef::Simple(trait_dict_name(name, trait_name)))
                }
            } else { none }
        },
        _ => none
    }
}

// ============================================================
// infer_unary_op
// ============================================================

fn infer_unary_op(mut ctx: InferCtx, op: UnaryOp, operand: Expr, span: Span, subst: UnionFind) -> InferResult {
    let r = infer_expr(ctx, operand, subst)
    let mut s = r.subst
    let mut result_type: Type = UNIT
    match op {
        UnaryOp::Neg => {
            let resolved = apply_subst(s, hexpr_type(r.hexpr))
            match resolved {
                Type::TypeVar { .. } => { s = unify_at(ctx.sink, ctx.env, resolved, INT, s, span); result_type = INT },
                Type::IntType => { result_type = INT },
                Type::FloatType => { result_type = FLOAT },
                _ => { let _ = type_error(ctx.sink, E0303,
                    "Unary - requires numeric type, got ${type_to_string(resolved)}",
                    span, DiagnosticContext::TypeMismatch { expected: "Int or Float", actual: type_to_string(resolved), expression: none }) }
            }
        },
        UnaryOp::Not => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(r.hexpr), BOOL, s, span)
            result_type = BOOL
        }
    }
    InferResult {
        hexpr: HExpr::UnaryOp { op: op, operand: r.hexpr, ty: result_type, effects: r.effects, span: span },
        subst: s, effects: r.effects
    }
}

// ============================================================
// infer_call
// ============================================================

fn infer_call(mut ctx: InferCtx, callee: Expr, args: List<Expr>, span: Span, subst: UnionFind) -> InferResult {
    let callee_r = infer_expr(ctx, callee, subst)
    let mut s = callee_r.subst
    let mut effects = callee_r.effects

    // Resolve callee type for lambda bidirectional inference
    let resolved_callee = apply_subst(s, hexpr_type(callee_r.hexpr))
    let callee_fn_type: Type? = match resolved_callee {
        Type::FnType { .. } => some(resolved_callee),
        _ => none
    }

    let mut hargs: List<HExpr> = []
    let mut arg_types: List<Type> = []
    let mut ai = 0
    for arg in args {
        let mut ar: InferResult = match arg {
            Expr::Lambda { params: lparams, body: lbody, span: lspan, .. } => {
                match callee_fn_type {
                    some(cft) => match cft {
                        Type::FnType { params: cft_params, .. } => {
                            if ai < cft_params.len() {
                                match cft_params.get(ai) {
                                    some(expected_raw) => {
                                        let expected = apply_subst(s, expected_raw)
                                        match expected {
                                            Type::FnType { params: exp_params, .. } => {
                                                infer_lambda(ctx, lparams, lbody, lspan, s, some(exp_params))
                                            },
                                            _ => infer_expr(ctx, arg, s)
                                        }
                                    },
                                    none => infer_expr(ctx, arg, s)
                                }
                            } else { infer_expr(ctx, arg, s) }
                        },
                        _ => infer_expr(ctx, arg, s)
                    },
                    none => infer_expr(ctx, arg, s)
                }
            },
            _ => infer_expr(ctx, arg, s)
        }
        s = ar.subst
        let me = merge_effects(ctx.env, effects, ar.effects, s)
        effects = me.0
        s = me.1
        hargs.push(ar.hexpr)
        arg_types.push(hexpr_type(ar.hexpr))
        ai = ai + 1
    }

    let ret_var = ctx.env.fresh_var()
    let effect_tail = ctx.env.fresh_var_id()
    let expected_fn = Type::FnType {
        params: arg_types,
        return_type: ret_var,
        effects: EffectRow { effects: [], tail: some(effect_tail) }
    }

    let callee_name_for_note: Str = match callee { Expr::Ident { name: cn, .. } => cn, _ => "<expression>" }
    let call_notes: List<DiagnosticNote> = [
        DiagnosticNote { message: "calling '${callee_name_for_note}' with ${arg_types.len().to_str()} argument(s)", span: some(span) }
    ]
    s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(callee_r.hexpr), expected_fn, s, span, call_notes)
    let resolved_callee_type = apply_subst(s, hexpr_type(callee_r.hexpr))

    match resolved_callee_type {
        Type::FnType { params: callee_params, effects: fn_effects, .. } => {
            let me = merge_effects(ctx.env, effects, fn_effects, s)
            effects = me.0
            s = me.1
            // Cancel mut<T> effects for arguments that are local variables
            effects = cancel_local_mut_effects(ctx, effects, callee_params, fn_effects, hargs, 0, s)
        },
        _ => {}
    }

    let result_type = apply_subst(s, ret_var)

    let mut resolved_dicts: List<DictRef> = []
    match callee {
        Expr::Ident { name: callee_name, .. } => {
            match ctx.env.lookup(callee_name) {
                some(callee_scheme) => {
                    if callee_scheme.bounds.len() > 0 {
                        resolved_dicts = resolve_dicts_from_scheme(ctx.sink, ctx.env, ctx.current_fn_bounds, callee_scheme, hexpr_type(callee_r.hexpr), s, span)
                    }
                },
                none => {}
            }
        },
        _ => {}
    }

    // Call-site pre-boxing: if callee has mut value-type params, mark mutable var args as boxed
    match callee {
        Expr::Ident { name: callee_name, .. } => {
            match ctx.fn_mut_params.get(callee_name) {
                some(mut_flags) => {
                    let mut mi = 0
                    while mi < mut_flags.len() && mi < args.len() {
                        match (mut_flags.get(mi), hargs.get(mi)) {
                            (some(is_mut), some(harg)) => {
                                if is_mut {
                                    // Check if the arg is a mutable variable Ident
                                    match harg {
                                        HExpr::Ident { def_id: some(arg_did), .. } => {
                                            if ctx.env.scope.mutable_vars.contains(arg_did) {
                                                // Check if the param type is a value type
                                                match resolved_callee_type {
                                                    Type::FnType { params: fn_params, .. } => {
                                                        match fn_params.get(mi) {
                                                            some(pt) => {
                                                                let resolved_pt = apply_subst(s, pt)
                                                                if is_value_type(resolved_pt) {
                                                                    ctx.boxed_vars.insert(arg_did)
                                                                }
                                                            },
                                                            none => {}
                                                        }
                                                    },
                                                    _ => {}
                                                }
                                            }
                                        },
                                        _ => {}
                                    }
                                }
                            },
                            _ => {}
                        }
                        mi = mi + 1
                    }
                },
                none => {}
            }
        },
        _ => {}
    }

    // Post-process: resolve dict_closure_dicts for ident args
    let mut final_hargs: List<HExpr> = []
    for harg in hargs {
        final_hargs.push(resolve_arg_dict_closure(ctx, harg, s))
    }

    InferResult {
        hexpr: HExpr::Call {
            callee: callee_r.hexpr, args: final_hargs, type_args: [],
            resolved_dicts: resolved_dicts, dict_dispatch: none,
            ty: result_type, effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

fn resolve_arg_dict_closure(ctx: InferCtx, harg: HExpr, s: UnionFind) -> HExpr {
    match harg {
        HExpr::Ident { name, resolved_name, def_id, ty, effects, span, .. } => {
            let arg_scheme = ctx.env.lookup(name)
            match arg_scheme {
                some(as_) => {
                    if as_.bounds.len() == 0 { return harg }
                    let var_map = build_scheme_var_map(as_, ty)
                    let mut dicts: List<Str> = []
                    for bound in as_.bounds {
                        match var_map.get(bound.type_var) {
                            some(fresh_var) => {
                                let concrete = apply_subst(s, fresh_var)
                                resolve_arg_bound_dict(ctx, concrete, bound.trait_name, dicts)
                            },
                            none => {}
                        }
                    }
                    if dicts.len() > 0 {
                        HExpr::Ident { name: name, resolved_name: resolved_name, def_id: def_id,
                            dict_closure_dicts: some(dicts), ty: ty, effects: effects, span: span }
                    } else { harg }
                },
                none => harg
            }
        },
        _ => harg
    }
}

fn resolve_arg_bound_dict(ctx: InferCtx, concrete: Type, trait_name: Str, mut dicts: List<Str>) {
    match concrete {
        Type::StructType { name, .. } => {
            if has_impl(ctx.env.trait_reg, name, trait_name) {
                dicts.push(trait_dict_name(name, trait_name))
            }
        },
        Type::EnumType { name, .. } => {
            if has_impl(ctx.env.trait_reg, name, trait_name) {
                dicts.push(trait_dict_name(name, trait_name))
            }
        },
        Type::TypeVar { id, .. } => {
            let matching = ctx.current_fn_bounds.find(fn(fb) {
                fb.type_param_var_id == id && fb.trait_name == trait_name
            })
            match matching {
                some(fb) => dicts.push(trait_bound_param_name(fb.type_param_name, fb.trait_name)),
                none => {}
            }
        },
        _ => {
            match type_to_builtin_name(concrete) {
                some(prim_name) => {
                    if has_impl(ctx.env.trait_reg, prim_name, trait_name) {
                        dicts.push(trait_dict_name(prim_name, trait_name))
                    }
                },
                none => {}
            }
        }
    }
}

// ============================================================
// Mutability check for method calls
// ============================================================

fn check_expr_is_let_def(ctx: InferCtx, expr: Expr) -> Bool {
    match expr {
        Expr::Ident { name, .. } => {
            match ctx.env.lookup(name) {
                some(s) => match s.def_id {
                    some(did) => ctx.env.scope.let_defs.contains(did),
                    none => false
                },
                none => false
            }
        },
        Expr::FieldAccess { receiver: inner, .. } => check_expr_is_let_def(ctx, inner),
        _ => false
    }
}

fn get_expr_def_id(ctx: InferCtx, expr: Expr) -> Int? {
    match expr {
        Expr::Ident { name, .. } => {
            match ctx.env.lookup(name) {
                some(s) => s.def_id,
                none => none
            }
        },
        // Do not recurse through FieldAccess: only direct ident receivers
        // qualify for mut<T> injection (e.g. list.push, not ctx.field.push)
        _ => none
    }
}

fn is_mut_method_call(ctx: InferCtx, recv_type: Type, method: Str) -> Bool {
    let mut type_name: Str? = none
    match recv_type {
        Type::StructType { name, .. } => { type_name = some(name) },
        Type::EnumType { name, .. } => { type_name = some(name) },
        _ => {
            match type_to_builtin_name(recv_type) {
                some(n) => { type_name = some(n) },
                none => {}
            }
        }
    }
    match type_name {
        some(tname) => {
            match ctx.env.trait_reg.mut_methods.get(tname) {
                some(mut_set) => mut_set.contains(method),
                none => false
            }
        },
        none => false
    }
}

fn check_receiver_mutability(mut ctx: InferCtx, receiver: Expr, recv_type: Type, method: Str, span: Span) {
    let mut type_name: Str? = none
    match recv_type {
        Type::StructType { name, .. } => { type_name = some(name) },
        Type::EnumType { name, .. } => { type_name = some(name) },
        _ => {
            match type_to_builtin_name(recv_type) {
                some(n) => { type_name = some(n) },
                none => {}
            }
        }
    }

    match type_name {
        some(tname) => {
            match ctx.env.trait_reg.mut_methods.get(tname) {
                some(mut_set) => {
                    if mut_set.contains(method) {
                        let is_let_def = check_expr_is_let_def(ctx, receiver)
                        if is_let_def {
                            let _ = type_error(ctx.sink, E0208,
                                "Cannot call mutating method '${method}' on immutable binding. Use 'let mut' to make it mutable.",
                                span, DiagnosticContext::OtherContext { detail: some("'${method}' requires a mutable receiver") })
                        }
                    }
                },
                none => {}
            }
        },
        none => {}
    }
}

// ============================================================
// infer_method_call
// ============================================================

fn infer_method_call(mut ctx: InferCtx, receiver: Expr, method: Str, args: List<Expr>, span: Span, subst: UnionFind) -> InferResult {
    // Check if receiver is an effect module
    match receiver {
        Expr::Ident { name: recv_name, qualifier, .. } => {
            let full_effect_name = match qualifier {
                some(q) => "${q}::${recv_name}",
                none => recv_name
            }
            match ctx.env.types.effects.get(full_effect_name) {
                some(_) => { return infer_effect_op(ctx, full_effect_name, method, args, span, subst) },
                none => {}
            }
        },
        _ => {}
    }

    let recv_r = infer_expr(ctx, receiver, subst)
    let mut s = recv_r.subst
    let mut effects = recv_r.effects
    let recv_type = apply_subst(s, hexpr_type(recv_r.hexpr))

    // Check receiver mutability for mut self methods
    check_receiver_mutability(ctx, receiver, recv_type, method, span)

    // Inject mut<T> effect when calling mut method on a mut function parameter
    if is_mut_method_call(ctx, recv_type, method) {
        match get_expr_def_id(ctx, receiver) {
            some(did) => {
                if ctx.env.scope.mut_param_defs.contains(did) {
                    let mut_eff = Effect::MutEffect { state_type: recv_type }
                    let me = merge_effects(ctx.env, effects, effect_row([mut_eff]), s)
                    effects = me.0
                    s = me.1
                }
            },
            none => {}
        }
    }

    let mut method_type: Type? = none
    let mut method_scheme: TypeScheme? = none

    // Look up method in impl for struct/enum
    match recv_type {
        Type::StructType { name, .. } => {
            let r = lookup_impl_method(ctx, name, method)
            method_type = r.method_type
            method_scheme = r.method_scheme
        },
        Type::EnumType { name, .. } => {
            let r = lookup_impl_method(ctx, name, method)
            method_type = r.method_type
            method_scheme = r.method_scheme
        },
        _ => {}
    }

    // Method lookup for primitive types
    if method_type.is_none() {
        match type_to_builtin_name(recv_type) {
            some(prim_name) => {
                let r = lookup_impl_method(ctx, prim_name, method)
                method_type = r.method_type
                method_scheme = r.method_scheme
            },
            none => {}
        }
    }

    // Check trait impls
    if method_type.is_none() {
        match type_to_builtin_name(recv_type) {
            some(type_name) => {
                method_type = lookup_trait_method(ctx, type_name, method, span)
            },
            none => {}
        }
    }

    // Check fn bounds for type variable receivers
    let mut dict_dispatch: DictDispatchInfo? = none
    let recv_raw_type = hexpr_type(recv_r.hexpr)
    let recv_var_id = match recv_raw_type {
        Type::TypeVar { id, .. } => some(resolve_var_id(id, s)),
        _ => none
    }
    if method_type.is_none() {
        match recv_var_id {
            some(rvid) => {
                for fb in ctx.current_fn_bounds {
                    if resolve_var_id(fb.type_param_var_id, s) == rvid {
                        match ctx.env.trait_reg.traits.get(fb.trait_name) {
                            some(trait_def) => {
                                let tm = trait_def.methods.find(fn(m) { m.name == method })
                                match tm {
                                    some(found_method) => {
                                        method_type = some(ctx.env.instantiate(TypeScheme { ty: found_method.ty, type_vars: trait_def.type_param_vars, bounds: [], def_id: none }))
                                        dict_dispatch = some(DictDispatchInfo { dict_param: trait_bound_param_name(fb.type_param_name, fb.trait_name), method: method })
                                    },
                                    none => {}
                                }
                            },
                            none => {}
                        }
                    }
                }
            },
            none => {}
        }
    }

    // Early receiver-method unification for bidirectional type checking
    match method_type {
        some(mt) => match mt {
            Type::FnType { params: mt_params, .. } => {
                if mt_params.len() > 0 {
                    match mt_params.first() {
                        some(first_param) => {
                            let recv_notes: List<DiagnosticNote> = [
                                DiagnosticNote { message: "method '${method}' expects receiver of type '${type_to_string(apply_subst(s, first_param))}'", span: some(span) },
                                DiagnosticNote { message: "receiver has type '${type_to_string(apply_subst(s, hexpr_type(recv_r.hexpr)))}'", span: some(hexpr_span(recv_r.hexpr)) }
                            ]
                            s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(recv_r.hexpr), first_param, s, span, recv_notes)
                        },
                        none => {}
                    }
                }
            },
            _ => {}
        },
        none => {}
    }

    // Infer arguments with lambda type propagation
    let mut hargs: List<HExpr> = []
    let mut ai = 0
    for arg in args {
        let mut ar: InferResult = match arg {
            Expr::Lambda { params: lparams, body: lbody, span: lspan, .. } => {
                match method_type {
                    some(mt) => match mt {
                        Type::FnType { params: mt_params, .. } => {
                            if ai + 1 < mt_params.len() {
                                match mt_params.get(ai + 1) {
                                    some(expected_raw) => {
                                        let expected = apply_subst(s, expected_raw)
                                        match expected {
                                            Type::FnType { params: exp_params, .. } => {
                                                infer_lambda(ctx, lparams, lbody, lspan, s, some(exp_params))
                                            },
                                            _ => infer_expr(ctx, arg, s)
                                        }
                                    },
                                    none => infer_expr(ctx, arg, s)
                                }
                            } else { infer_expr(ctx, arg, s) }
                        },
                        _ => infer_expr(ctx, arg, s)
                    },
                    none => infer_expr(ctx, arg, s)
                }
            },
            _ => infer_expr(ctx, arg, s)
        }
        s = ar.subst
        let me = merge_effects(ctx.env, effects, ar.effects, s)
        effects = me.0
        s = me.1
        hargs.push(ar.hexpr)
        ai = ai + 1
    }

    let mut result_type: Type = ctx.env.fresh_var()
    match method_type {
        some(mt) => match mt {
            Type::FnType { params: mt_params, return_type: mt_ret, effects: mt_effects, .. } => {
                let mut i = 0
                for harg in hargs {
                    if i + 1 < mt_params.len() {
                        match mt_params.get(i + 1) {
                            some(expected_param) => {
                                let arg_num = (i + 1).to_str()
                                let marg_notes: List<DiagnosticNote> = [
                                    DiagnosticNote { message: "argument ${arg_num} of method '${method}' expects type '${type_to_string(apply_subst(s, expected_param))}'", span: some(span) },
                                    DiagnosticNote { message: "argument has type '${type_to_string(apply_subst(s, hexpr_type(harg)))}'", span: some(hexpr_span(harg)) }
                                ]
                                s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(harg), expected_param, s, span, marg_notes)
                            },
                            none => {}
                        }
                    }
                    i = i + 1
                }
                result_type = apply_subst(s, mt_ret)
                let me = merge_effects(ctx.env, effects, mt_effects, s)
                effects = me.0
                s = me.1
                // Cancel mut<T> effects for method arguments that are local variables
                // param_offset=1 because mt_params[0] is self
                effects = cancel_local_mut_effects(ctx, effects, mt_params, mt_effects, hargs, 1, s)
            },
            _ => {
                match recv_type {
                    Type::TypeVar { .. } => {},
                    _ => { let _ = type_error(ctx.sink, E0305,
                        "Type '${type_to_string(recv_type)}' has no method '${method}'",
                        span, DiagnosticContext::OtherContext { detail: some("no method '${method}' on type '${type_to_string(recv_type)}'") }) }
                }
            }
        },
        none => {
            match recv_type {
                Type::TypeVar { .. } => {},
                _ => { let _ = type_error(ctx.sink, E0305,
                    "Type '${type_to_string(recv_type)}' has no method '${method}'",
                    span, DiagnosticContext::OtherContext { detail: some("no method '${method}' on type '${type_to_string(recv_type)}'") }) }
            }
        }
    }

    let mut resolved_dicts: List<DictRef> = []
    match method_scheme {
        some(ms) => {
            if ms.bounds.len() > 0 {
                match method_type {
                    some(mt) => {
                        resolved_dicts = resolve_dicts_from_scheme(ctx.sink, ctx.env, ctx.current_fn_bounds, ms, mt, s, span)
                    },
                    none => {}
                }
            }
        },
        none => {}
    }

    let callee_type = match method_type { some(mt) => mt, none => ctx.env.fresh_var() }
    InferResult {
        hexpr: HExpr::Call {
            callee: HExpr::FieldAccess { receiver: recv_r.hexpr, field: method, ty: callee_type, effects: EMPTY_ROW, span: span },
            args: hargs, type_args: [], resolved_dicts: resolved_dicts,
            dict_dispatch: dict_dispatch, ty: result_type, effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

fn lookup_impl_method(mut ctx: InferCtx, type_name: Str, method: Str) -> MethodLookupResult {
    match ctx.env.trait_reg.impl_methods.get(type_name) {
        some(impl_methods) => match impl_methods.get(method) {
            some(scheme) => MethodLookupResult {
                method_type: some(ctx.env.instantiate(scheme)),
                method_scheme: some(scheme)
            },
            none => MethodLookupResult { method_type: none, method_scheme: none }
        },
        none => MethodLookupResult { method_type: none, method_scheme: none }
    }
}

fn lookup_trait_method(mut ctx: InferCtx, type_name: Str, method: Str, span: Span) -> Type? {
    let mut found_type: Type? = none
    let mut found_trait_name: Str? = none
    match ctx.env.trait_reg.trait_impls.get(type_name) {
        some(type_impls) => {
            for impl_entry in type_impls {
                match ctx.env.trait_reg.traits.get(impl_entry.trait_name) {
                    some(trait_def) => {
                        let tm = trait_def.methods.find(fn(m) { m.name == method })
                        match tm {
                            some(found_method) => {
                                match found_trait_name {
                                    some(prev_trait) => {
                                        let _ = type_error(ctx.sink, E0504,
                                            "Ambiguous method '${method}' on '${type_name}': found in trait '${prev_trait}' and '${impl_entry.trait_name}'",
                                            span, DiagnosticContext::OtherContext { detail: some("disambiguate by calling TraitName::${method}") })
                                        return found_type
                                    },
                                    none => {
                                        found_type = some(ctx.env.instantiate(TypeScheme { ty: found_method.ty, type_vars: trait_def.type_param_vars, bounds: [], def_id: none }))
                                        found_trait_name = some(impl_entry.trait_name)
                                    }
                                }
                            },
                            none => {}
                        }
                    },
                    none => {}
                }
            }
        },
        none => {}
    }
    found_type
}

// ============================================================
// infer_effect_op
// ============================================================

fn infer_effect_op(mut ctx: InferCtx, effect_name: Str, op_name: Str, args: List<Expr>, span: Span, subst: UnionFind) -> InferResult {
    let effect_def_opt = ctx.env.types.effects.get(effect_name)
    match effect_def_opt {
        none => {
            let _ = type_error(ctx.sink, E0402,
                "Unknown effect: ${effect_name}",
                span, DiagnosticContext::OtherContext { detail: some("effect '${effect_name}' not found") })
            return InferResult {
                hexpr: HExpr::EffectOp { effect_name: effect_name, op_name: op_name, args: [], ty: Type::ErrorType, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            }
        },
        _ => {}
    }
    let effect_def = match effect_def_opt { some(ed) => ed, none => panic("unreachable: effect_def_opt after none early return") }
    // Use canonical name from EffectDef so mod-internal unqualified references
    // (e.g. "Greeter") resolve to the declaration name (e.g. "fx::Greeter")
    let canonical_effect_name = effect_def.name
    let op_opt = effect_def.ops.find(fn(o) { o.name == op_name })
    match op_opt {
        none => {
            let _ = type_error(ctx.sink, E0402,
                "Effect ${canonical_effect_name} has no operation ${op_name}",
                span, DiagnosticContext::OtherContext { detail: some("no operation '${op_name}' on effect '${canonical_effect_name}'") })
            return InferResult {
                hexpr: HExpr::EffectOp { effect_name: canonical_effect_name, op_name: op_name, args: [], ty: Type::ErrorType, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            }
        },
        _ => {}
    }
    let op = match op_opt { some(o) => o, none => panic("unreachable: op_opt after none early return") }

    // Instantiate effect type params with fresh variables
    let mut inst_map: Map<Int, Type> = map_new()
    let mut inst_type_args: List<Type> = []
    let mut tpi = 0
    for tpv in effect_def.type_param_vars {
        let fresh = ctx.env.fresh_var()
        inst_map.insert(tpv, fresh)
        inst_type_args.push(fresh)
        tpi = tpi + 1
    }

    // Apply instantiation to op param types and return type
    let mut inst_params: List<Type> = []
    for pt in op.params {
        inst_params.push(apply_subst_map(inst_map, pt))
    }
    let inst_ret = apply_subst_map(inst_map, op.return_type)

    if args.len() != inst_params.len() {
        let _ = type_error(ctx.sink, E0301,
            "Effect operation '${effect_name}.${op_name}' expects ${inst_params.len().to_str()} argument(s), got ${args.len().to_str()}",
            span, DiagnosticContext::TypeMismatch { expected: "${inst_params.len().to_str()} args", actual: "${args.len().to_str()} args", expression: none })
    }

    let mut s = subst
    let mut effects: EffectRow = EMPTY_ROW
    let mut hargs: List<HExpr> = []

    let mut i = 0
    for arg in args {
        let ar = infer_expr(ctx, arg, s)
        s = ar.subst
        let me = merge_effects(ctx.env, effects, ar.effects, s)
        effects = me.0
        s = me.1
        hargs.push(ar.hexpr)
        match inst_params.get(i) {
            some(param_type) => { s = unify_at(ctx.sink, ctx.env, hexpr_type(ar.hexpr), param_type, s, span) },
            none => {}
        }
        i = i + 1
    }

    let mut eff: Effect = Effect::CustomEffect { name: canonical_effect_name, type_args: inst_type_args }
    match effect_def.built_in_kind {
        some(bik) => match bik {
            BuiltInKind::BkIo => { eff = Effect::IoEffect },
            BuiltInKind::BkFail => {
                let error_type = if hargs.len() > 0 { apply_subst(s, hexpr_type(match hargs.first() { some(h) => h, none => panic("unreachable: hargs.first() after len > 0 check") })) } else { UNIT }
                eff = Effect::FailEffect { error_type: error_type }
            },
            BuiltInKind::BkMut => { eff = Effect::MutEffect { state_type: ctx.env.fresh_var() } }
        },
        none => {}
    }

    let me = merge_effects(ctx.env, effects, effect_row([eff]), s)
    effects = me.0
    s = me.1

    InferResult {
        hexpr: HExpr::EffectOp { effect_name: canonical_effect_name, op_name: op_name, args: hargs, ty: inst_ret, effects: effects, span: span },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_field_access
// ============================================================

fn infer_field_access(mut ctx: InferCtx, receiver: Expr, field: Str, span: Span, subst: UnionFind) -> InferResult {
    let recv_r = infer_expr(ctx, receiver, subst)
    let s = recv_r.subst
    let recv_type = apply_subst(s, hexpr_type(recv_r.hexpr))

    let mut field_type: Type = ctx.env.fresh_var()
    match recv_type {
        Type::StructType { name, type_params, .. } => {
            match ctx.env.types.structs.get(name) {
                some(struct_def) => {
                    let f = struct_def.fields.find(fn(f_) { f_.name == field })
                    match f {
                        some(found_field) => {
                            let mut inst_map: Map<Int, Type> = map_new()
                            let mut fi = 0
                            while fi < struct_def.type_param_vars.len() && fi < type_params.len() {
                                match (struct_def.type_param_vars.get(fi), type_params.get(fi)) {
                                    (some(var_id), some(tp)) => inst_map.insert(var_id, tp),
                                    _ => {}
                                }
                                fi = fi + 1
                            }
                            field_type = apply_subst_map(inst_map, found_field.ty)
                        },
                        none => { let _ = type_error(ctx.sink, E0304,
                            "Struct ${name} has no field ${field}",
                            span, DiagnosticContext::MissingField { field: field, ty: name, available: none }) }
                    }
                },
                none => { let _ = type_error(ctx.sink, E0203,
                    "Unknown struct: ${name}",
                    span, DiagnosticContext::OtherContext { detail: some("unknown struct '${name}'") }) }
            }
        },
        Type::RecordType { fields: rec_fields, tail, .. } => {
            let f = rec_fields.find(fn(f_) { f_.name == field })
            match f {
                some(found_field) => { field_type = found_field.ty },
                none => match tail {
                    some(_) => {},
                    none => { let _ = type_error(ctx.sink, E0304,
                        "Record type has no field '${field}'",
                        span, DiagnosticContext::MissingField { field: field, ty: "record", available: none }) }
                }
            }
        },
        Type::TupleType { elements } => {
            match parse_int(field) {
                none => { let _ = type_error(ctx.sink, E0304,
                    "Cannot access named field '${field}' on tuple type; use .0, .1, etc.",
                    span, DiagnosticContext::MissingField { field: field, ty: "tuple", available: none }) },
                some(i) => {
                    if i < 0 || i >= elements.len() {
                        let _ = type_error(ctx.sink, E0304,
                            "Tuple index ${field} out of bounds; tuple has ${elements.len().to_str()} elements",
                            span, DiagnosticContext::MissingField { field: field, ty: "tuple", available: none })
                    }
                    match elements.get(i) {
                        some(t) => { field_type = t },
                        none => panic("unreachable: tuple index bounds already checked")
                    }
                }
            }
        },
        Type::TypeVar { .. } => {},
        _ => { let _ = type_error(ctx.sink, E0304,
            "Cannot access field '${field}' on type ${type_to_string(recv_type)}",
            span, DiagnosticContext::MissingField { field: field, ty: type_to_string(recv_type), available: none }) }
    }

    InferResult {
        hexpr: HExpr::FieldAccess { receiver: recv_r.hexpr, field: field, ty: field_type, effects: recv_r.effects, span: span },
        subst: s, effects: recv_r.effects
    }
}

// ============================================================
// infer_struct_lit
// ============================================================

fn infer_struct_lit(mut ctx: InferCtx, name: Str, fields: List<StructFieldInit>, spread: Expr?, span: Span, subst: UnionFind, qualifier: Str?) -> InferResult {
    // Resolve relative paths (self::/super::)
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
                        return InferResult {
                            hexpr: HExpr::StructLit { name: name, type_args: [], fields: [], spread: none, ty: Type::ErrorType, effects: EMPTY_ROW, span: span },
                            subst: subst, effects: EMPTY_ROW
                        }
                    }
                }
            }
        },
        none => {}
    }

    // Try module-qualified struct lookup: qualifier::name
    match resolved_qualifier {
        some(q) => {
            let qualified_name = "${q}::${name}"
            let mod_struct = ctx.env.types.structs.get(qualified_name)
            match mod_struct {
                some(_) => {
                    return infer_struct_lit(ctx, qualified_name, fields, spread, span, subst, none)
                },
                none => {
                    // Fallback: try prepending current mod path for relative references
                    if ctx.mod_path_stack.len() > 0 {
                        let mod_prefix = ctx.mod_path_stack.join("::")
                        let full_qualified = "${mod_prefix}::${qualified_name}"
                        let full_struct = ctx.env.types.structs.get(full_qualified)
                        match full_struct {
                            some(_) => {
                                return infer_struct_lit(ctx, full_qualified, fields, spread, span, subst, none)
                            },
                            none => {}
                        }
                    }
                }
            }
        },
        none => {}
    }

    // Check for named enum variant
    let mut variant_enum: Str? = none
    match resolved_qualifier {
        some(q) => {
            match ctx.env.types.enums.get(q) {
                some(enum_def) => {
                    if enum_def.variant_index.contains_key(name) { variant_enum = some(enum_def.name) }
                },
                none => {
                    // Fallback: try prepending current mod path
                    if ctx.mod_path_stack.len() > 0 {
                        let mod_prefix = ctx.mod_path_stack.join("::")
                        let full_q = "${mod_prefix}::${q}"
                        match ctx.env.types.enums.get(full_q) {
                            some(enum_def) => {
                                if enum_def.variant_index.contains_key(name) { variant_enum = some(enum_def.name) }
                            },
                            none => {}
                        }
                    }
                }
            }
        },
        none => { variant_enum = ctx.env.types.variant_to_enum.get(name) }
    }
    if variant_enum.is_none() && resolved_qualifier.is_some() {
        match resolved_qualifier {
            some(q) => { let _ = type_error(ctx.sink, E0201, "'${q}' has no variant '${name}'", span,
                DiagnosticContext::UndefinedVariable { name: name, scope_locals: none }) },
            none => {}
        }
    }
    match variant_enum {
        some(ve) => match ctx.env.types.enums.get(ve) {
            some(enum_def) => {
                let variant = lookup_variant(enum_def, name)
                match variant {
                    some(v) => match v.field_names {
                        some(_) => { return infer_named_variant_construct(ctx, ve, name, v, enum_def, fields, spread, span, subst) },
                        none => {}
                    },
                    none => {}
                }
            },
            none => {}
        },
        none => {}
    }

    let struct_def_opt = ctx.env.types.structs.get(name)
    match struct_def_opt {
        none => {
            let _ = type_error(ctx.sink, E0203, "Unknown struct: ${name}", span,
                DiagnosticContext::OtherContext { detail: some("unknown struct '${name}'") })
            return InferResult {
                hexpr: HExpr::StructLit { name: name, type_args: [], fields: [], spread: none, ty: Type::ErrorType, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            }
        },
        _ => {}
    }
    let struct_def = match struct_def_opt { some(sd) => sd, none => panic("unreachable: struct_def_opt after none early return") }

    let mut inst_map: Map<Int, Type> = map_new()
    let mut type_param_types: List<Type> = []
    let mut tpi = 0
    while tpi < struct_def.type_param_vars.len() {
        match struct_def.type_param_vars.get(tpi) {
            some(var_id) => {
                let tv = ctx.env.fresh_var()
                inst_map.insert(var_id, tv)
                type_param_types.push(tv)
            },
            none => {}
        }
        tpi = tpi + 1
    }

    let mut s = subst
    let mut effects: EffectRow = EMPTY_ROW
    let mut hfields: List<HStructFieldInit> = []

    let mut hspread: HExpr? = none
    match spread {
        some(sp) => {
            let sr = infer_expr(ctx, sp, s)
            s = sr.subst
            let me = merge_effects(ctx.env, effects, sr.effects, s)
            effects = me.0
            s = me.1
            let mut spread_fields: List<StructField> = []
            for f in struct_def.fields {
                spread_fields.push(StructField { name: f.name, ty: apply_subst_map(inst_map, f.ty), is_pub: f.is_pub })
            }
            let spread_type = Type::StructType { name: struct_def.name, type_params: type_param_types, fields: spread_fields }
            s = unify_at(ctx.sink, ctx.env, hexpr_type(sr.hexpr), spread_type, s, span)
            hspread = some(sr.hexpr)
        },
        none => {}
    }

    for field in fields {
        let fr = infer_expr(ctx, field.value, s)
        s = fr.subst
        let me = merge_effects(ctx.env, effects, fr.effects, s)
        effects = me.0
        s = me.1
        let def_field = struct_def.fields.find(fn(f) { f.name == field.name })
        match def_field {
            some(df) => {
                let ft = apply_subst_map(inst_map, df.ty)
                let field_notes: List<DiagnosticNote> = [
                    DiagnosticNote { message: "field '${field.name}' of struct '${name}' expects type '${type_to_string(ft)}'", span: some(field.span) },
                    DiagnosticNote { message: "provided value has type '${type_to_string(apply_subst(s, hexpr_type(fr.hexpr)))}'", span: some(hexpr_span(fr.hexpr)) }
                ]
                s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(fr.hexpr), ft, s, span, field_notes)
            },
            none => { let _ = type_error(ctx.sink, E0203,
                "Struct '${name}' has no field '${field.name}'",
                field.span, DiagnosticContext::MissingField { field: field.name, ty: name, available: none }) }
        }
        hfields.push(HStructFieldInit { name: field.name, value: fr.hexpr })
    }

    if spread.is_none() {
        let mut provided: Set<Str> = set_new()
        for f in fields { provided.insert(f.name) }
        for df in struct_def.fields {
            if !provided.contains(df.name) {
                let _ = type_error(ctx.sink, E0203,
                    "Missing field '${df.name}' in struct literal '${name}'",
                    span, DiagnosticContext::MissingField { field: df.name, ty: name, available: none })
            }
        }
    }

    let struct_type = Type::StructType {
        name: struct_def.name, type_params: type_param_types,
        fields: struct_def.fields
    }

    InferResult {
        hexpr: HExpr::StructLit { name: struct_def.name, type_args: [], fields: hfields, spread: hspread, ty: struct_type, effects: effects, span: span },
        subst: s, effects: effects
    }
}

fn infer_named_variant_construct(mut ctx: InferCtx, enum_name: Str, variant_name: Str, variant: EnumVariant, enum_def: EnumDef, fields: List<StructFieldInit>, spread: Expr?, span: Span, subst: UnionFind) -> InferResult {
    let field_names = match variant.field_names { some(fn_) => fn_, none => [] }

    let mut inst_map: Map<Int, Type> = map_new()
    let mut type_param_types: List<Type> = []
    let mut tpi = 0
    while tpi < enum_def.type_param_vars.len() {
        match enum_def.type_param_vars.get(tpi) {
            some(var_id) => {
                let tv = ctx.env.fresh_var()
                inst_map.insert(var_id, tv)
                type_param_types.push(tv)
            },
            none => {}
        }
        tpi = tpi + 1
    }

    let mut s = subst
    let mut effects: EffectRow = EMPTY_ROW
    let mut hfields: List<HStructFieldInit> = []

    let mut hspread: HExpr? = none
    match spread {
        some(sp) => {
            let sr = infer_expr(ctx, sp, s)
            s = sr.subst
            let me = merge_effects(ctx.env, effects, sr.effects, s)
            effects = me.0
            s = me.1
            let spread_enum_type = Type::EnumType { name: enum_name, type_params: type_param_types, variants: enum_def.variants }
            s = unify_at(ctx.sink, ctx.env, hexpr_type(sr.hexpr), spread_enum_type, s, span)
            hspread = some(sr.hexpr)
        },
        none => {}
    }

    for field in fields {
        let fr = infer_expr(ctx, field.value, s)
        s = fr.subst
        let me = merge_effects(ctx.env, effects, fr.effects, s)
        effects = me.0
        s = me.1
        let field_idx = field_names.index_of(field.name)
        match field_idx {
            some(idx) => match variant.fields.get(idx) {
                some(ftype) => {
                    let ft = apply_subst_map(inst_map, ftype)
                    s = unify_at(ctx.sink, ctx.env, hexpr_type(fr.hexpr), ft, s, span)
                },
                none => {}
            },
            none => { let _ = type_error(ctx.sink, E0203,
                "Variant '${variant_name}' has no field '${field.name}'",
                field.span, DiagnosticContext::MissingField { field: field.name, ty: variant_name, available: none }) }
        }
        hfields.push(HStructFieldInit { name: field.name, value: fr.hexpr })
    }

    if spread.is_none() {
        let mut provided: Set<Str> = set_new()
        for f in fields { provided.insert(f.name) }
        for fn_name in field_names {
            if !provided.contains(fn_name) {
                let _ = type_error(ctx.sink, E0203,
                    "Missing field '${fn_name}' in variant '${variant_name}'",
                    span, DiagnosticContext::MissingField { field: fn_name, ty: variant_name, available: none })
            }
        }
    }

    let enum_type = Type::EnumType { name: enum_name, type_params: type_param_types, variants: enum_def.variants }

    InferResult {
        hexpr: HExpr::NamedVariantConstruct {
            enum_name: enum_name, variant_name: variant_name,
            fields: hfields, spread: hspread, ty: enum_type, effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

// ============================================================
// rewrite_bare_enum_bindings — recursively convert Binding→Constructor
// for zero-field enum variants inside nested patterns (#79)
// ============================================================

fn rewrite_bare_enum_bindings(env: TypeEnv, pattern: Pattern) -> Pattern {
    match pattern {
        Pattern::Binding { name, span } => {
            match env.types.variant_to_enum.get(name) {
                some(ve) => match env.types.enums.get(ve) {
                    some(edef) => {
                        let v = lookup_variant(edef, name)
                        match v {
                            some(found_v) => {
                                if found_v.fields.len() == 0 {
                                    let empty_pats: List<Pattern> = []
                                    Pattern::Constructor { name: name, qualifier: none, fields: empty_pats, span: span }
                                } else {
                                    pattern
                                }
                            },
                            none => pattern,
                        }
                    },
                    none => pattern,
                },
                none => pattern,
            }
        },
        Pattern::TuplePattern { elements, span } => {
            let mut new_elems: List<Pattern> = []
            for elem in elements {
                new_elems.push(rewrite_bare_enum_bindings(env, elem))
            }
            Pattern::TuplePattern { elements: new_elems, span: span }
        },
        Pattern::Constructor { name, qualifier, fields, span } => {
            let mut new_fields: List<Pattern> = []
            for f in fields {
                new_fields.push(rewrite_bare_enum_bindings(env, f))
            }
            Pattern::Constructor { name: name, qualifier: qualifier, fields: new_fields, span: span }
        },
        Pattern::NamedConstructor { name, qualifier, fields, rest, span } => {
            let mut new_fields: List<NamedPatternField> = []
            for f in fields {
                new_fields.push(NamedPatternField { name: f.name, pattern: rewrite_bare_enum_bindings(env, f.pattern), span: f.span })
            }
            Pattern::NamedConstructor { name: name, qualifier: qualifier, fields: new_fields, rest: rest, span: span }
        },
        Pattern::OrPattern { patterns, span } => {
            let mut new_pats: List<Pattern> = []
            for p in patterns {
                new_pats.push(rewrite_bare_enum_bindings(env, p))
            }
            Pattern::OrPattern { patterns: new_pats, span: span }
        },
        _ => pattern,
    }
}

// ============================================================
// infer_match
// ============================================================

fn infer_match(mut ctx: InferCtx, scrutinee: Expr, arms: List<MatchArm>, span: Span, subst: UnionFind) -> InferResult {
    let scrut_r = infer_expr(ctx, scrutinee, subst)
    let mut s = scrut_r.subst
    let mut effects = scrut_r.effects
    let result_type = ctx.env.fresh_var()
    let mut harms: List<HMatchArm> = []

    for arm in arms {
        ctx.env.push_scope()
        let arm_result = some({
            let match_pattern = rewrite_bare_enum_bindings(ctx.env, arm.pattern)
            bind_pattern(ctx, match_pattern, hexpr_type(scrut_r.hexpr), s)

            let mut guard_hexpr: HExpr? = none
            match arm.guard {
                some(g) => {
                    let gr = infer_expr(ctx, g, s)
                    s = gr.subst
                    s = unify_at(ctx.sink, ctx.env, hexpr_type(gr.hexpr), BOOL, s, arm.span)
                    let me = merge_effects(ctx.env, effects, gr.effects, s)
                    effects = me.0
                    s = me.1
                    guard_hexpr = some(gr.hexpr)
                },
                none => {}
            }

            let body_r = infer_expr(ctx, arm.body, s)
            s = body_r.subst
            let me = merge_effects(ctx.env, effects, body_r.effects, s)
            effects = me.0
            s = me.1
            let match_notes: List<DiagnosticNote> = [
                DiagnosticNote { message: "match arms must all have the same type", span: some(arm.span) },
                DiagnosticNote { message: "this arm has type '${type_to_string(apply_subst(s, hexpr_type(body_r.hexpr)))}'", span: some(hexpr_span(body_r.hexpr)) }
            ]
            s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(body_r.hexpr), result_type, s, arm.span, match_notes)

            harms.push(HMatchArm { pattern: match_pattern, guard: guard_hexpr, body: body_r.hexpr, span: arm.span })
            true
        }) catch { _ => none }
        ctx.env.pop_scope()
        match arm_result {
            none => fail.raise(CompileError {}),
            _ => {}
        }
    }

    let scrut_type_resolved = apply_subst(s, hexpr_type(scrut_r.hexpr))
    let missing = check_exhaustive(ctx.env, harms, scrut_type_resolved, s)
    match missing {
        some(m) => {
            let msg = if m == "_" {
                "Non-exhaustive match: non-finite type '${type_to_string(scrut_type_resolved)}' requires a wildcard '_' or binding pattern"
            } else {
                "Non-exhaustive match on type ${type_to_string(scrut_type_resolved)}: missing pattern for ${m}"
            }
            let _ = type_error(ctx.sink, E0601,
                msg,
                span, DiagnosticContext::PatternError { detail: "missing: ${m}" })
        },
        none => {}
    }

    let final_type = apply_subst(s, result_type)
    InferResult {
        hexpr: HExpr::MatchExpr { scrutinee: scrut_r.hexpr, arms: harms, ty: final_type, effects: effects, span: span },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_if
// ============================================================

fn infer_if(mut ctx: InferCtx, condition: Expr, then_branch: Expr, else_branch: Expr?, span: Span, subst: UnionFind) -> InferResult {
    let cond_r = infer_expr(ctx, condition, subst)
    let mut s = cond_r.subst
    s = unify_at(ctx.sink, ctx.env, hexpr_type(cond_r.hexpr), BOOL, s, span)
    let mut effects = cond_r.effects

    let then_r = infer_block(ctx, then_branch, some(s))
    s = then_r.subst
    let me = merge_effects(ctx.env, effects, then_r.effects, s)
    effects = me.0
    s = me.1

    let mut else_hexpr: HExpr? = none
    let mut result_type: Type = UNIT

    match else_branch {
        some(eb) => match eb {
            Expr::Block { .. } => {
                let else_r = infer_block(ctx, eb, some(s))
                s = else_r.subst
                let me2 = merge_effects(ctx.env, effects, else_r.effects, s)
                effects = me2.0
                s = me2.1
                let if_notes: List<DiagnosticNote> = [
                    DiagnosticNote { message: "then branch has type '${type_to_string(apply_subst(s, hexpr_type(then_r.hexpr)))}'", span: some(hexpr_span(then_r.hexpr)) },
                    DiagnosticNote { message: "else branch has type '${type_to_string(apply_subst(s, hexpr_type(else_r.hexpr)))}'", span: some(hexpr_span(else_r.hexpr)) }
                ]
                s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(then_r.hexpr), hexpr_type(else_r.hexpr), s, span, if_notes)
                result_type = apply_subst(s, hexpr_type(then_r.hexpr))
                else_hexpr = some(else_r.hexpr)
            },
            Expr::IfExpr { condition: ec, then_branch: etb, else_branch: eeb, span: espan } => {
                let else_if_r = infer_if(ctx, ec, etb, eeb, espan, s)
                s = else_if_r.subst
                let me2 = merge_effects(ctx.env, effects, else_if_r.effects, s)
                effects = me2.0
                s = me2.1
                let elif_notes: List<DiagnosticNote> = [
                    DiagnosticNote { message: "then branch has type '${type_to_string(apply_subst(s, hexpr_type(then_r.hexpr)))}'", span: some(hexpr_span(then_r.hexpr)) },
                    DiagnosticNote { message: "else branch has type '${type_to_string(apply_subst(s, hexpr_type(else_if_r.hexpr)))}'", span: some(hexpr_span(else_if_r.hexpr)) }
                ]
                s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(then_r.hexpr), hexpr_type(else_if_r.hexpr), s, span, elif_notes)
                result_type = apply_subst(s, hexpr_type(then_r.hexpr))
                else_hexpr = some(HExpr::Block {
                    stmts: [], tail: some(else_if_r.hexpr),
                    ty: hexpr_type(else_if_r.hexpr), effects: else_if_r.effects, span: espan
                })
            },
            _ => { panic("unreachable: unexpected else branch form in infer_if") }
        },
        none => {}
    }

    InferResult {
        hexpr: HExpr::IfExpr {
            condition: cond_r.hexpr, then_branch: then_r.hexpr, else_branch: else_hexpr,
            ty: result_type, effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_string_interp
// ============================================================

fn infer_string_interp(mut ctx: InferCtx, parts: List<StringInterpPart>, span: Span, subst: UnionFind) -> InferResult {
    let mut s = subst
    let mut effects: EffectRow = EMPTY_ROW
    let mut hparts: List<HStringInterpPart> = []

    for part in parts {
        match part {
            StringInterpPart::LitPart(str_val) => hparts.push(HStringInterpPart::Literal(str_val)),
            StringInterpPart::ExprPart(expr) => {
                let r = infer_expr(ctx, expr, s)
                s = r.subst
                let me = merge_effects(ctx.env, effects, r.effects, s)
                effects = me.0
                s = me.1
                hparts.push(HStringInterpPart::Expression(r.hexpr))
            }
        }
    }

    InferResult {
        hexpr: HExpr::StringInterp { parts: hparts, ty: STR, effects: effects, span: span },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_catch
// ============================================================

fn infer_catch(mut ctx: InferCtx, expr: Expr, arms: List<MatchArm>, span: Span, subst: UnionFind) -> InferResult {
    let expr_r = infer_expr(ctx, expr, subst)
    let mut s = expr_r.subst
    let mut effects = expr_r.effects

    // Extract error type from the body's fail effects, unifying if multiple
    let mut error_type: Type = ctx.env.fresh_var()
    let mut found_fail = false
    for eff in effects.effects {
        match eff {
            Effect::FailEffect { error_type: et } => {
                if found_fail {
                    s = unify_at(ctx.sink, ctx.env, error_type, et, s, span)
                } else {
                    error_type = et
                    found_fail = true
                }
            },
            _ => {}
        }
    }

    // Warn only when the body's effect row is closed (no open tail) and has no fail effect.
    // An open tail means the body may have fail effects from polymorphic call sites.
    let resolved_row = apply_subst_row(s, effects)
    let has_open_tail = match resolved_row.tail {
        some(_) => true,
        none => false
    }
    if found_fail == false && has_open_tail == false {
        let warn = make_diag(W0001, Severity::SevWarning,
            "catch on expression with no fail effect; handler will never execute",
            span,
            DiagnosticContext::OtherContext { detail: some("body has no fail effect") })
        ctx.sink.report(warn)
    }

    let result_type = ctx.env.fresh_var()
    s = unify_at(ctx.sink, ctx.env, hexpr_type(expr_r.hexpr), result_type, s, span)
    let mut harms: List<HMatchArm> = []

    for arm in arms {
        ctx.env.push_scope()
        let arm_result = some({
            bind_pattern(ctx, arm.pattern, error_type, s)

            let mut guard_hexpr: HExpr? = none
            match arm.guard {
                some(g) => {
                    let gr = infer_expr(ctx, g, s)
                    s = gr.subst
                    s = unify_at(ctx.sink, ctx.env, hexpr_type(gr.hexpr), BOOL, s, arm.span)
                    let me = merge_effects(ctx.env, effects, gr.effects, s)
                    effects = me.0
                    s = me.1
                    guard_hexpr = some(gr.hexpr)
                },
                none => {}
            }

            let body_r = infer_expr(ctx, arm.body, s)
            s = body_r.subst
            let me = merge_effects(ctx.env, effects, body_r.effects, s)
            effects = me.0
            s = me.1
            s = unify_at(ctx.sink, ctx.env, hexpr_type(body_r.hexpr), result_type, s, arm.span)

            harms.push(HMatchArm { pattern: arm.pattern, guard: guard_hexpr, body: body_r.hexpr, span: arm.span })
            true
        }) catch { _ => none }
        ctx.env.pop_scope()
        match arm_result {
            none => fail.raise(CompileError {}),
            _ => {}
        }
    }

    // Check exhaustiveness of catch arms against the error type
    let error_type_resolved = apply_subst(s, error_type)
    let missing = check_exhaustive(ctx.env, harms, error_type_resolved, s)
    match missing {
        some(m) => {
            let msg = if m == "_" {
                "Non-exhaustive catch: non-finite error type '${type_to_string(error_type_resolved)}' requires a wildcard '_' or binding pattern"
            } else {
                "Non-exhaustive catch on error type ${type_to_string(error_type_resolved)}: missing pattern for ${m}"
            }
            let _ = type_error(ctx.sink, E0601,
                msg,
                span, DiagnosticContext::PatternError { detail: "missing: ${m}" })
        },
        none => {}
    }

    // catch always fully consumes the fail effect
    effects = remove_fail_effect(effects)

    let final_type = apply_subst(s, result_type)
    InferResult {
        hexpr: HExpr::TryCatch { body: expr_r.hexpr, arms: harms, ty: final_type, effects: effects, span: span },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_handle
// ============================================================

fn infer_handle(mut ctx: InferCtx, body: Expr, handlers: List<EffectHandler>, span: Span, subst: UnionFind) -> InferResult {
    let body_r = infer_expr(ctx, body, subst)
    let mut s = body_r.subst
    let mut effects = body_r.effects

    let mut hhandlers: List<HEffectHandler> = []
    let mut handled_effects: Set<Str> = set_new()

    for handler in handlers {
        ctx.env.push_scope()
        let effect_def = ctx.env.types.effects.get(handler.effect_name)

        // Instantiate effect type params with fresh variables for handler
        let mut handler_inst_map: Map<Int, Type> = map_new()
        match effect_def {
            some(ed) => {
                for tpv in ed.type_param_vars {
                    let fresh = ctx.env.fresh_var()
                    handler_inst_map.insert(tpv, fresh)
                }
            },
            none => {}
        }

        let mut op_def: EffectOpDef? = none
        match effect_def {
            some(ed) => { op_def = ed.ops.find(fn(o) { o.name == handler.op_name }) },
            none => {}
        }

        let mut hparams: List<HParam> = []
        let mut hi = 0
        for p in handler.params {
            let pt = match p.type_annotation {
                some(ta) => resolve_type_expr(ctx, ta),
                none => match op_def {
                    some(od) => match od.params.get(hi) {
                        some(odt) => apply_subst_map(handler_inst_map, odt),
                        none => ctx.env.fresh_var()
                    },
                    none => ctx.env.fresh_var()
                }
            }
            ctx.env.bind_mono(p.name, pt)
            hparams.push(HParam { name: p.name, ty: pt, def_id: none, is_mutable: false })
            hi = hi + 1
        }

        match handler.resume_name {
            some(rn) => {
                let resume_param = match op_def {
                    some(od) => apply_subst_map(handler_inst_map, od.return_type),
                    none => ctx.env.fresh_var()
                }
                let resume_ret = ctx.env.fresh_var()
                ctx.env.bind_mono(rn, Type::FnType { params: [resume_param], return_type: resume_ret, effects: EMPTY_ROW })
            },
            none => {}
        }

        let handler_body_result = some(infer_expr(ctx, handler.body, s)) catch { _ => none }
        ctx.env.pop_scope()

        match handler_body_result {
            some(hbr) => {
                s = hbr.subst
                hhandlers.push(HEffectHandler {
                    effect_name: handler.effect_name, op_name: handler.op_name,
                    params: hparams, resume_name: handler.resume_name, body: hbr.hexpr
                })
            },
            none => fail.raise(CompileError {})
        }

        handled_effects.insert(handler.effect_name)
    }

    let resolved_effects = apply_subst_row(s, effects)
    let mut filtered_effects: List<Effect> = []
    for e in resolved_effects.effects {
        let should_keep = match e {
            Effect::IoEffect => !handled_effects.contains("io"),
            Effect::CustomEffect { name, .. } => !handled_effects.contains(name),
            Effect::FailEffect { .. } => !handled_effects.contains("fail"),
            Effect::MutEffect { .. } => !handled_effects.contains("mut")
        }
        if should_keep { filtered_effects.push(e) }
    }
    effects = EffectRow { effects: filtered_effects, tail: resolved_effects.tail }

    InferResult {
        hexpr: HExpr::HandleExpr {
            body: body_r.hexpr, handlers: hhandlers,
            ty: hexpr_type(body_r.hexpr), effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_lambda
// ============================================================

fn infer_lambda(mut ctx: InferCtx, params: List<Param>, body: Expr, span: Span, subst: UnionFind, expected_param_types: List<Type>?) -> InferResult {
    ctx.env.push_scope()
    ctx.lambda_depth = ctx.lambda_depth + 1
    let mut s = subst
    let mut hparams: List<HParam> = []
    let mut param_types: List<Type> = []

    let mut pi = 0
    for p in params {
        let pt = match p.type_annotation {
            some(ta) => resolve_type_expr(ctx, ta),
            none => ctx.env.fresh_var()
        }
        match expected_param_types {
            some(epts) => {
                if p.type_annotation.is_none() {
                    match epts.get(pi) {
                        some(expected_t) => { s = unify_at(ctx.sink, ctx.env, pt, expected_t, s, span) },
                        none => {}
                    }
                }
            },
            none => {}
        }
        ctx.env.bind_mono(p.name, pt)
        let lam_scheme = ctx.env.lookup(p.name)
        match lam_scheme {
            some(ls) => {
                match ls.def_id {
                    some(did) => {
                        ctx.env.record_def_span(did, p.span)
                        ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                        if p.is_mutable {
                            ctx.env.scope.mutable_vars.insert(did)
                            ctx.env.scope.mut_param_defs.insert(did)
                        } else {
                            ctx.env.scope.let_defs.insert(did)
                        }
                    },
                    none => {}
                }
                hparams.push(HParam { name: p.name, ty: pt, def_id: ls.def_id, is_mutable: p.is_mutable })
            },
            none => {
                hparams.push(HParam { name: p.name, ty: pt, def_id: none, is_mutable: p.is_mutable })
            }
        }
        param_types.push(pt)
        pi = pi + 1
    }

    let body_result = some(infer_expr(ctx, body, s)) catch { _ => none }
    ctx.lambda_depth = ctx.lambda_depth - 1
    ctx.env.pop_scope()

    match body_result {
        some(body_r) => {
            s = body_r.subst
            let mut applied_params: List<Type> = []
            for pt in param_types { applied_params.push(apply_subst(s, pt)) }
            let applied_ret = apply_subst(s, hexpr_type(body_r.hexpr))

            let fn_type = Type::FnType { params: applied_params, return_type: applied_ret, effects: body_r.effects }

            let mut final_hparams: List<HParam> = []
            for hp in hparams {
                final_hparams.push(HParam { name: hp.name, ty: apply_subst(s, hp.ty), def_id: hp.def_id, is_mutable: hp.is_mutable })
            }

            InferResult {
                hexpr: HExpr::Lambda {
                    params: final_hparams, return_type: applied_ret,
                    body: body_r.hexpr, ty: fn_type, effects: EMPTY_ROW, span: span
                },
                subst: s, effects: EMPTY_ROW
            }
        },
        none => fail.raise(CompileError {})
    }
}

// ============================================================
// infer_list_literal
// ============================================================

fn infer_list_literal(mut ctx: InferCtx, elements: List<Expr>, span: Span, subst: UnionFind) -> InferResult {
    if elements.len() == 0 {
        let elem_type = ctx.env.fresh_var()
        let list_type = Type::StructType { name: BUILTIN_LIST, type_params: [elem_type], fields: [] }
        return InferResult {
            hexpr: HExpr::ListLit { elements: [], ty: list_type, effects: EMPTY_ROW, span: span },
            subst: subst, effects: EMPTY_ROW
        }
    }
    let mut s = subst
    let mut helements: List<HExpr> = []
    let mut elem_type: Type = ctx.env.fresh_var()
    let mut combined_effects: EffectRow = EMPTY_ROW
    for el in elements {
        let r = infer_expr(ctx, el, s)
        s = r.subst
        s = unify_at(ctx.sink, ctx.env, apply_subst(s, hexpr_type(r.hexpr)), apply_subst(s, elem_type), s, span)
        elem_type = apply_subst(s, elem_type)
        helements.push(r.hexpr)
        let me = merge_effects(ctx.env, combined_effects, r.effects, s)
        combined_effects = me.0
        s = me.1
    }
    let list_type = Type::StructType { name: BUILTIN_LIST, type_params: [apply_subst(s, elem_type)], fields: [] }
    InferResult {
        hexpr: HExpr::ListLit { elements: helements, ty: list_type, effects: combined_effects, span: span },
        subst: s, effects: combined_effects
    }
}
