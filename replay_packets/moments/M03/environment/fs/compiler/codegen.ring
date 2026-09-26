use types::{Type, Effect, EffectRow, effect_kind_name}
use ast::{TypeParam}
use hir::{HExpr, HStmt, HDecl, HParam, HProgram, HStructField, HEnumVariant,
    HTraitMethod, TraitBound, DerivedImpl, HStringInterpPart, HMatchArm,
    HEffectHandler, HStructFieldInit,
    BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET, BUILTIN_STR, BUILTIN_INT,
    BUILTIN_FLOAT, BUILTIN_BOOL, BUILTIN_CELL, BUILTIN_OPTION,
    BUILTIN_STRING_BUILDER}
use builtin_methods::{CELL_METHODS, STR_METHODS, INT_METHODS, FLOAT_METHODS,
    LIST_NON_HOF_METHODS, MAP_NON_HOF_METHODS, SET_NON_HOF_METHODS,
    OPTION_NON_HOF_METHODS, STRINGBUILDER_METHODS}
use runtime::{RUNTIME_CODE}
use codegen_ctx::{CodegenCtx, HTraitDeclInfo, new_codegen_ctx,
    emit, emit_raw, push_indent, pop_indent, qualify, safe_ident,
    get_evidence_params}
use codegen_decl::{emit_decl, emit_toplevel_evidence}
use codegen_expr::{gen_expr}
use codegen_derive::{emit_derived_impl, get_derived_method_names}

// ============================================================
// Public API
// ============================================================

pub fn generate(program: HProgram, skip_preamble: Bool, skip_main_call: Bool,
                module_prefix: Str?, imports_map: Map<Str, Str>?,
                external_struct_fields: Map<Str, List<Str>>?,
                external_impl_methods: Map<Str, Str?>?,
                module_imports: List<Str>?, module_exports: List<Str>?,
                external_fn_mut_params: Map<Str, List<Bool>>?) -> Str {
    let mut ctx = new_codegen_ctx(skip_preamble, skip_main_call)
    ctx.module_prefix = module_prefix
    ctx.imports_map = imports_map
    ctx.module_imports = module_imports
    ctx.module_exports = module_exports
    ctx.boxed_vars = program.boxed_vars

    // Pre-scan fn_mut_params from HDecl::Fn and HDecl::Impl methods
    scan_fn_mut_params(program.decls, ctx)

    // Load external fn_mut_params from other modules
    match external_fn_mut_params {
        some(efmp) => {
            for entry in efmp.entries() {
                let (k, v) = entry
                ctx.fn_mut_params.insert(k, v)
            }
        },
        none => {},
    }

    // Load external struct fields
    match external_struct_fields {
        some(esf) => {
            for entry in esf.entries() {
                let (k, v) = entry
                ctx.struct_field_order.insert(k, v)
            }
        },
        none => {},
    }

    // Load external impl methods
    match external_impl_methods {
        some(eim) => {
            for entry in eim.entries() {
                let (k, v) = entry
                ctx.impl_methods.insert(k, v)
            }
        },
        none => {},
    }

    // ESM mode: emit import statements
    let has_imports = match ctx.module_imports {
        some(imports) => imports.len() > 0,
        none => false,
    }
    if has_imports {
        match ctx.module_imports {
            some(imports) => {
                for imp in imports { emit_raw(ctx, imp) }
            },
            none => {},
        }
        let empty = ""
        emit_raw(ctx, empty)
    }

    // Collect local names, fn effects, struct field orders, trait decls, impl methods
    register_decl_info(program.decls, ctx)

    // Compute transitive effect closure
    if ctx.local_fn_effects.len() > 0 {
        let mut fn_callees: Map<Str, Set<Str>> = map_new()
        collect_fn_callees(program.decls, ctx.local_names, fn_callees)
        let mut changed = true
        while changed {
            changed = false
            for entry in fn_callees.entries() {
                let (name, callees) = entry
                for callee in callees.to_list() {
                    match ctx.local_fn_effects.get(callee) {
                        some(callee_effects) => {
                            match ctx.local_fn_effects.get(name) {
                                none => {
                                    let mut effs: List<Effect> = []
                                    for e in callee_effects.effects { effs.push(e) }
                                    ctx.local_fn_effects.insert(name, EffectRow { effects: effs, tail: none })
                                    changed = true
                                },
                                some(current) => {
                                    for e in callee_effects.effects {
                                        let ename = effect_kind_name(e)
                                        let mut found = false
                                        for ce in current.effects {
                                            if effect_kind_name(ce) == ename { found = true }
                                        }
                                        if found == false {
                                            current.effects.push(e)
                                            changed = true
                                        }
                                    }
                                },
                            }
                        },
                        none => {},
                    }
                }
            }
        }
    }

    // Register built-in impl methods
    register_builtin_methods(ctx, BUILTIN_CELL, CELL_METHODS)
    register_builtin_methods(ctx, BUILTIN_STR, STR_METHODS)
    register_builtin_methods(ctx, BUILTIN_LIST, LIST_NON_HOF_METHODS)
    register_builtin_methods(ctx, BUILTIN_MAP, MAP_NON_HOF_METHODS)
    register_builtin_methods(ctx, BUILTIN_SET, SET_NON_HOF_METHODS)
    register_builtin_methods(ctx, BUILTIN_INT, INT_METHODS)
    register_builtin_methods(ctx, BUILTIN_FLOAT, FLOAT_METHODS)
    register_builtin_methods(ctx, BUILTIN_OPTION, OPTION_NON_HOF_METHODS)
    register_builtin_methods(ctx, BUILTIN_STRING_BUILDER, STRINGBUILDER_METHODS)

    // Register builtin trait methods for UFCS dispatch
    for prim in [BUILTIN_INT, BUILTIN_FLOAT, BUILTIN_STR, BUILTIN_BOOL] {
        let key = "${safe_ident(prim)}.debug"
        ctx.impl_methods.insert(key, some("Debug"))
    }
    for coll in [BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET, BUILTIN_OPTION] {
        let key = "${safe_ident(coll)}.debug"
        ctx.impl_methods.insert(key, some("Debug"))
    }

    // Emit runtime preamble
    if ctx.skip_preamble == false {
        emit_raw(ctx, RUNTIME_CODE())
        emit_raw(ctx, "")
    }

    // Register auto-derive impl methods BEFORE emitting declarations
    for impl_ in program.derived_impls {
        for method_name in get_derived_method_names(impl_.trait_name) {
            let key = "${qualify(ctx, impl_.type_name)}.${method_name}"
            match ctx.impl_methods.get(key) {
                none => { ctx.impl_methods.insert(key, some(impl_.trait_name)) },
                some(_) => {},
            }
        }
    }

    // Emit declarations
    for decl in program.decls {
        emit_decl(ctx, decl)
        emit_raw(ctx, "")
    }

    // Emit auto-derived trait implementations
    for impl_ in program.derived_impls {
        emit_derived_impl(ctx, impl_)
        emit_raw(ctx, "")
    }

    // Auto-call main() if present
    if ctx.skip_main_call == false {
        for decl in program.decls {
            match decl {
                HDecl::Fn { name, effects, .. } => {
                    if name == "main" {
                        let fn_name = qualify(ctx, "main")
                        let ev_params = get_evidence_params(effects)
                        if ev_params.len() > 0 {
                            emit_toplevel_evidence(ctx, effects)
                            let ev_str = ev_params.join(", ")
                            emit(ctx, "${fn_name}(${ev_str});")
                        } else {
                            emit(ctx, "${fn_name}();")
                        }
                    }
                },
                _ => {},
            }
        }
    }

    // ESM mode: emit export statement
    match ctx.module_exports {
        some(exports) => {
            if exports.len() > 0 {
                emit_raw(ctx, "")
                let joined = exports.join(", ")
                emit_raw(ctx, "export { ${joined} };")
            }
        },
        none => {},
    }

    ctx.lines.join("\n")
}

fn register_builtin_methods(mut ctx: CodegenCtx, type_name: Str, methods: List<Str>) {
    let sn = safe_ident(type_name)
    for m in methods {
        let key = "${sn}.${m}"
        ctx.impl_methods.insert(key, none)
    }
}

// Recursively collect local names, fn effects, struct field orders, trait decls, and impl methods.
// Replaces 3 separate hand-unrolled 3-level-nested match loops (B-049).
fn register_decl_info(decls: List<HDecl>, mut ctx: CodegenCtx) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, effects, .. } => {
                ctx.local_names.insert(name)
                if effects.effects.len() > 0 {
                    ctx.local_fn_effects.insert(name, effects)
                }
            },
            HDecl::Struct { name, fields, .. } => {
                ctx.local_names.insert(name)
                let qname = qualify(ctx, name)
                let mut field_names: List<Str> = []
                for f in fields { field_names.push(f.name) }
                ctx.struct_field_order.insert(qname, field_names)
            },
            HDecl::Enum { name, variants, .. } => {
                ctx.local_names.insert(name)
                for v in variants {
                    ctx.local_names.insert(v.name)
                    ctx.local_names.insert("${name}_${v.name}")
                }
            },
            HDecl::Trait { name, methods, supertraits, .. } => {
                ctx.local_names.insert(name)
                ctx.trait_decls.insert(name, HTraitDeclInfo { name: name, methods: methods, supertraits: supertraits })
            },
            HDecl::Impl { target_type, trait_name, methods, .. } => {
                ctx.local_names.insert(target_type)
                // Collect explicitly declared method names
                let mut explicit_methods: Set<Str> = set_new()
                for method in methods {
                    match method {
                        HDecl::Fn { name, .. } => {
                            explicit_methods.insert(name)
                            let key = "${qualify(ctx, target_type)}.${name}"
                            match trait_name {
                                none => {
                                    match ctx.impl_methods.get(key) {
                                        none => { ctx.impl_methods.insert(key, none) },
                                        some(_) => {},
                                    }
                                },
                                some(tn) => {
                                    match ctx.impl_methods.get(key) {
                                        none => { ctx.impl_methods.insert(key, some(tn)) },
                                        some(_) => {},
                                    }
                                },
                            }
                        },
                        _ => {},
                    }
                }
                // #84: Register un-overridden default methods from the trait
                match trait_name {
                    some(tn) => {
                        match ctx.trait_decls.get(tn) {
                            some(trait_info) => {
                                for tm in trait_info.methods {
                                    if tm.has_default && !explicit_methods.contains(tm.name) {
                                        let key = "${qualify(ctx, target_type)}.${tm.name}"
                                        match ctx.impl_methods.get(key) {
                                            none => { ctx.impl_methods.insert(key, some(tn)) },
                                            some(_) => {},
                                        }
                                    }
                                }
                            },
                            none => {},
                        }
                    },
                    none => {},
                }
            },
            HDecl::Effect { name, .. } => { ctx.local_names.insert(name) },
            HDecl::Const { name, .. } => { ctx.local_names.insert(name) },
            HDecl::ModBlock { name, decls: mod_decls, .. } => {
                ctx.local_names.insert(name)
                register_decl_info(mod_decls, ctx)
            },
            HDecl::Test { .. } => {},
            HDecl::ExternFn { .. } => {},
            HDecl::ExternType { .. } => {},
            HDecl::TypeAlias { .. } => {},
            HDecl::Sig { .. } => {},
        }
    }
}

// Recursively collect fn callees for transitive effect closure computation (B-049).
fn collect_fn_callees(decls: List<HDecl>, local_names: Set<Str>, mut fn_callees: Map<Str, Set<Str>>) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, body, .. } => {
                let mut callees = set_new()
                collect_local_calls(body, local_names, callees)
                fn_callees.insert(name, callees)
            },
            HDecl::Impl { methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, body: mb, .. } => {
                            let mut callees = set_new()
                            collect_local_calls(mb, local_names, callees)
                            fn_callees.insert(mn, callees)
                        },
                        _ => {},
                    }
                }
            },
            HDecl::ModBlock { decls: mod_decls, .. } => {
                collect_fn_callees(mod_decls, local_names, fn_callees)
            },
            _ => {},
        }
    }
}

fn collect_local_calls(expr: HExpr, local_names: Set<Str>, mut out: Set<Str>) {
    match expr {
        HExpr::Call { callee, args, .. } => {
            match callee {
                HExpr::Ident { name, .. } => {
                    if local_names.contains(name) { out.insert(name) }
                },
                HExpr::FieldAccess { field, .. } => {
                    if local_names.contains(field) { out.insert(field) }
                },
                _ => {},
            }
            collect_local_calls(callee, local_names, out)
            for a in args { collect_local_calls(a, local_names, out) }
        },
        HExpr::Block { stmts, tail, .. } => {
            for s in stmts { collect_local_calls_stmt(s, local_names, out) }
            match tail {
                some(t) => collect_local_calls(t, local_names, out),
                none => {},
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            collect_local_calls(condition, local_names, out)
            collect_local_calls(then_branch, local_names, out)
            match else_branch {
                some(eb) => collect_local_calls(eb, local_names, out),
                none => {},
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            collect_local_calls(scrutinee, local_names, out)
            for arm in arms {
                collect_local_calls(arm.body, local_names, out)
                match arm.guard {
                    some(g) => collect_local_calls(g, local_names, out),
                    none => {},
                }
            }
        },
        HExpr::BinOp { left, right, .. } => {
            collect_local_calls(left, local_names, out)
            collect_local_calls(right, local_names, out)
        },
        HExpr::UnaryOp { operand, .. } => {
            collect_local_calls(operand, local_names, out)
        },
        HExpr::FieldAccess { receiver, .. } => {
            collect_local_calls(receiver, local_names, out)
        },
        HExpr::StructLit { fields, spread, .. } => {
            for f in fields { collect_local_calls(f.value, local_names, out) }
            match spread {
                some(s) => collect_local_calls(s, local_names, out),
                none => {},
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for f in fields { collect_local_calls(f.value, local_names, out) }
            match spread {
                some(s) => collect_local_calls(s, local_names, out),
                none => {},
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for p in parts {
                match p {
                    HStringInterpPart::Expression(e) => collect_local_calls(e, local_names, out),
                    HStringInterpPart::Literal(_) => {},
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            collect_local_calls(body, local_names, out)
            for arm in arms { collect_local_calls(arm.body, local_names, out) }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            collect_local_calls(body, local_names, out)
            for h in handlers { collect_local_calls(h.body, local_names, out) }
        },
        HExpr::Lambda { body, .. } => {
            collect_local_calls(body, local_names, out)
        },
        HExpr::RangeExpr { start, end, .. } => {
            collect_local_calls(start, local_names, out)
            collect_local_calls(end, local_names, out)
        },
        HExpr::ListLit { elements, .. } => {
            for e in elements { collect_local_calls(e, local_names, out) }
        },
        HExpr::TupleLit { elements, .. } => {
            for e in elements { collect_local_calls(e, local_names, out) }
        },
        HExpr::EffectOp { args, .. } => {
            for a in args { collect_local_calls(a, local_names, out) }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            collect_local_calls(receiver, local_names, out)
            collect_local_calls(index, local_names, out)
        },
        _ => {},
    }
}

// Pre-scan fn_mut_params: build a map from function name → list of param mutability flags.
// Used by codegen to wrap/unwrap mut value-type parameters at call sites.
// Check if an HParam type is a value type (Int/Float/Bool/Str) for auto-boxing
fn is_codegen_value_type(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::BoolType => true,
        Type::StrType => true,
        _ => false
    }
}

fn scan_fn_mut_params(decls: List<HDecl>, mut ctx: CodegenCtx) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, params, .. } => {
                let mut flags: List<Bool> = []
                for p in params {
                    // Only flag params that are mut AND value-type.
                    // self params and reference-type params are never boxed.
                    if p.name == "self" || !p.is_mutable {
                        flags.push(false)
                    } else {
                        flags.push(is_codegen_value_type(p.ty))
                    }
                }
                ctx.fn_mut_params.insert(name, flags)
                // Also register with qualify(ctx, name) for module-prefixed lookup
                let qname = qualify(ctx, name)
                if qname != name {
                    ctx.fn_mut_params.insert(qname, flags)
                }
            },
            HDecl::Impl { target_type, methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, params: mp, .. } => {
                            let mut flags: List<Bool> = []
                            for p in mp {
                                if p.name == "self" || !p.is_mutable {
                                    flags.push(false)
                                } else {
                                    flags.push(is_codegen_value_type(p.ty))
                                }
                            }
                            let ufcs_name = "${qualify(ctx, target_type)}_${safe_ident(mn)}"
                            ctx.fn_mut_params.insert(ufcs_name, flags)
                        },
                        _ => {}
                    }
                }
            },
            HDecl::ModBlock { decls: mod_decls, .. } => {
                scan_fn_mut_params(mod_decls, ctx)
            },
            HDecl::Struct { .. } => {},
            HDecl::Enum { .. } => {},
            HDecl::Trait { .. } => {},
            HDecl::Effect { .. } => {},
            HDecl::Test { .. } => {},
            HDecl::ExternFn { .. } => {},
            HDecl::ExternType { .. } => {},
            HDecl::TypeAlias { .. } => {},
            HDecl::Const { .. } => {},
            HDecl::Sig { .. } => {},
        }
    }
}

fn collect_local_calls_stmt(stmt: HStmt, local_names: Set<Str>, mut out: Set<Str>) {
    match stmt {
        HStmt::Let { init, .. } => collect_local_calls(init, local_names, out),
        HStmt::Var { init, .. } => collect_local_calls(init, local_names, out),
        HStmt::Assign { target, value, .. } => {
            collect_local_calls(target, local_names, out)
            collect_local_calls(value, local_names, out)
        },
        HStmt::ExprStmt { expr, .. } => collect_local_calls(expr, local_names, out),
        HStmt::Return { value, .. } => {
            match value {
                some(v) => collect_local_calls(v, local_names, out),
                none => {},
            }
        },
        HStmt::While { condition, body, .. } => {
            collect_local_calls(condition, local_names, out)
            collect_local_calls(body, local_names, out)
        },
        HStmt::ForIn { iterable, body, .. } => {
            collect_local_calls(iterable, local_names, out)
            collect_local_calls(body, local_names, out)
        },
        HStmt::LetDestructure { init, .. } => collect_local_calls(init, local_names, out),
        HStmt::IfLet { expr, then_block, else_block, .. } => {
            collect_local_calls(expr, local_names, out)
            collect_local_calls(then_block, local_names, out)
            match else_block {
                some(eb) => collect_local_calls(eb, local_names, out),
                none => {},
            }
        },
        _ => {},
    }
}
