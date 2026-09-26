use types::{Type, Effect, EffectRow, StructField, EnumVariant,
    EMPTY_ROW, effects_same_kind, type_to_builtin_name, type_to_string, effect_to_string}
use ast::{Decl, Span, TypeParam, Param, TypeExpr, EffectOpDecl, StructFieldDecl,
    EnumVariantDecl, NamedEnumField, TypeBound, span_zero, EffectExpr, SigMember}
use env::{TypeEnv, TypeScheme, SchemeBound, AssocConstraintEntry, StructDef, EnumDef, EffectDef, EffectOpDef,
    TraitDef, TraitMethodDef, ImplEntry, TypeAliasDef, FnBound, SigDef, EffectAliasDef, AssocTypeDef, mono, apply_subst, apply_subst_effect_map, add_impl, has_impl, find_impl}
use diagnostics::{DiagnosticContext}
use codes::{E0207, E0406, E0407, E0501, E0502, E0505, E0506, E0507, E0508, E0509, E0510, E0511, E0513, E0514}
use infer_ctx::{InferCtx, CompileError, type_error, resolve_type_expr, resolve_self_type}

// ============================================================
// Public entry points
// ============================================================

pub fn register_decl_public(mut ctx: InferCtx, decl: Decl) {
    register_decl(ctx, decl)
}

pub fn insert_mod_aliases(mut ctx: InferCtx, mod_name: Str, decls: List<Decl>, guard: Bool) {
    for d in decls {
        match d {
            Decl::Struct { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.structs.contains_key(name) {
                    match ctx.env.types.structs.get(qualified) {
                        some(sdef) => { ctx.env.types.structs.insert(name, sdef) },
                        none => {}
                    }
                }
            },
            Decl::Enum { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.enums.contains_key(name) {
                    match ctx.env.types.enums.get(qualified) {
                        some(edef) => { ctx.env.types.enums.insert(name, edef) },
                        none => {}
                    }
                }
            },
            Decl::Trait { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.trait_reg.traits.contains_key(name) {
                    match ctx.env.trait_reg.traits.get(qualified) {
                        some(tdef) => { ctx.env.trait_reg.traits.insert(name, tdef) },
                        none => {}
                    }
                }
            },
            Decl::Effect { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.effects.contains_key(name) {
                    match ctx.env.types.effects.get(qualified) {
                        some(edef) => { ctx.env.types.effects.insert(name, edef) },
                        none => {}
                    }
                }
            },
            Decl::EffectAlias { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.effect_aliases.contains_key(name) {
                    match ctx.env.types.effect_aliases.get(qualified) {
                        some(adef) => { ctx.env.types.effect_aliases.insert(name, adef) },
                        none => {}
                    }
                }
            },
            _ => {}
        }
    }
}

pub fn prefix_decl_name(mod_name: Str, decl: Decl) -> Decl {
    match decl {
        Decl::Fn { name, type_params, params, return_type, declared_effects, body, is_pub, is_abstract, span } =>
            Decl::Fn { name: "${mod_name}::${name}", type_params: type_params, params: params,
                       return_type: return_type, declared_effects: declared_effects, body: body,
                       is_pub: is_pub, is_abstract: is_abstract, span: span },
        Decl::Struct { name, type_params, fields, is_pub, span } =>
            Decl::Struct { name: "${mod_name}::${name}", type_params: type_params, fields: fields,
                          is_pub: is_pub, span: span },
        Decl::Enum { name, type_params, variants, is_pub, span } =>
            Decl::Enum { name: "${mod_name}::${name}", type_params: type_params, variants: variants,
                        is_pub: is_pub, span: span },
        Decl::ExternFn { name, type_params, params, return_type, declared_effects, is_pub, span } =>
            Decl::ExternFn { name: "${mod_name}::${name}", type_params: type_params, params: params,
                            return_type: return_type, declared_effects: declared_effects,
                            is_pub: is_pub, span: span },
        Decl::Const { name, type_annotation, init, is_pub, span } =>
            Decl::Const { name: "${mod_name}::${name}", type_annotation: type_annotation, init: init,
                         is_pub: is_pub, span: span },
        Decl::Sig { name, members, is_pub, span } =>
            Decl::Sig { name: "${mod_name}::${name}", members: members, is_pub: is_pub, span: span },
        Decl::Impl { target_type, type_params, trait_name, methods, span } => {
            let prefixed_target = if target_type.contains("::") {
                target_type
            } else {
                "${mod_name}::${target_type}"
            }
            Decl::Impl { target_type: prefixed_target, type_params: type_params,
                         trait_name: trait_name, methods: methods, span: span }
        },
        Decl::Trait { name, type_params, supertraits, methods, is_pub, span } =>
            Decl::Trait { name: "${mod_name}::${name}", type_params: type_params, supertraits: supertraits,
                         methods: methods, is_pub: is_pub, span: span },
        Decl::Effect { name, type_params, ops, is_pub, span } =>
            Decl::Effect { name: "${mod_name}::${name}", type_params: type_params, ops: ops,
                          is_pub: is_pub, span: span },
        Decl::ExternType { name, type_params, is_pub, span } =>
            Decl::ExternType { name: "${mod_name}::${name}", type_params: type_params,
                              is_pub: is_pub, span: span },
        Decl::TypeAlias { name, type_params, type_expr, is_pub, span } =>
            Decl::TypeAlias { name: "${mod_name}::${name}", type_params: type_params, type_expr: type_expr,
                             is_pub: is_pub, span: span },
        Decl::EffectAlias { name, type_params, effects, is_pub, span } =>
            Decl::EffectAlias { name: "${mod_name}::${name}", type_params: type_params, effects: effects,
                               is_pub: is_pub, span: span },
        Decl::ModBlock { name, uses, decls, required_effects, is_pub, span } =>
            Decl::ModBlock { name: "${mod_name}::${name}", uses: uses, decls: decls,
                            required_effects: required_effects, is_pub: is_pub, span: span },
        Decl::AssocType { .. } => decl,  // Associated types are nested inside trait/impl, not prefixed
        _ => decl
    }
}

// Shared 5-pass ModBlock registration strategy.
// When deferred_struct_names/deferred_enum_names are provided (some), operates in phase1 mode
// (preregister struct/enum only, defer field/variant completion).
// When none, operates in register_decl mode (complete struct/enum immediately).
fn register_mod_block_items(
    mut ctx: InferCtx, mod_name: Str, mod_decls: List<Decl>,
    deferred_struct_names: List<Str>?, deferred_enum_names: List<Str>?
) {
    // Pass 1a: register struct/enum types first
    for d in mod_decls {
        match d {
            Decl::Struct { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            },
            Decl::Enum { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            },
            _ => {}
        }
    }
    // Incremental aliases: struct/enum short names available for trait bounds
    insert_mod_aliases(ctx, mod_name, mod_decls, true)
    // Pass 1b-1: traits -- alias after each so supertraits resolve by short name (#83)
    for d in mod_decls {
        match d {
            Decl::Trait { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
                // Incremental alias: makes this trait's short name available
                // for subsequent traits' supertrait lookup (#83)
                insert_mod_aliases(ctx, mod_name, mod_decls, true)
            },
            _ => {}
        }
    }
    // Pass 1b-2: effects, effect aliases, extern types
    for d in mod_decls {
        match d {
            Decl::Effect { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            },
            Decl::EffectAlias { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            },
            Decl::ExternType { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            },
            _ => {}
        }
    }
    // Final aliases: all names available for remaining declarations
    insert_mod_aliases(ctx, mod_name, mod_decls, true)
    // Pass 2: register everything else (functions, impls, consts, etc.)
    for d in mod_decls {
        match d {
            Decl::Struct { .. } => {},
            Decl::Enum { .. } => {},
            Decl::Trait { .. } => {},
            Decl::Effect { .. } => {},
            Decl::EffectAlias { .. } => {},
            Decl::ExternType { .. } => {},
            _ => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            }
        }
    }
}

// Dispatch a single declaration to the appropriate registration function.
// When deferred lists are provided, operates in phase1 mode; otherwise in register_decl mode.
fn register_mod_item(
    mut ctx: InferCtx, decl: Decl,
    deferred_struct_names: List<Str>?, deferred_enum_names: List<Str>?
) {
    match deferred_struct_names {
        some(dsn) => match deferred_enum_names {
            some(den) => register_phase1(ctx, decl, dsn, den),
            none => register_decl(ctx, decl)
        },
        none => register_decl(ctx, decl)
    }
}

fn register_phase1(mut ctx: InferCtx, decl: Decl, mut deferred_struct_names: List<Str>, mut deferred_enum_names: List<Str>) {
    match decl {
        Decl::Struct { name, type_params, fields, span, .. } => {
            preregister_struct(ctx, name, type_params)
            deferred_struct_names.push(name)
        },
        Decl::Enum { name, type_params, variants, span, .. } => {
            preregister_enum(ctx, name, type_params)
            deferred_enum_names.push(name)
        },
        Decl::ModBlock { name: mod_name, decls: mod_decls, .. } => {
            register_mod_block_items(ctx, mod_name, mod_decls, some(deferred_struct_names), some(deferred_enum_names))
        },
        _ => register_decl(ctx, decl)
    }
}

fn register_phase2_struct(mut ctx: InferCtx, decl: Decl) {
    match decl {
        Decl::Struct { name, type_params, fields, span, .. } =>
            complete_struct_fields(ctx, name, fields),
        Decl::ModBlock { name: mod_name, decls: mod_decls, .. } => {
            for d in mod_decls {
                let prefixed = prefix_decl_name(mod_name, d)
                register_phase2_struct(ctx, prefixed)
            }
        },
        _ => {}
    }
}

fn register_phase2_enum(mut ctx: InferCtx, decl: Decl) {
    match decl {
        Decl::Enum { name, type_params, variants, span, .. } =>
            complete_enum_variants(ctx, name, type_params, variants),
        Decl::ModBlock { name: mod_name, decls: mod_decls, .. } => {
            for d in mod_decls {
                let prefixed = prefix_decl_name(mod_name, d)
                register_phase2_enum(ctx, prefixed)
            }
        },
        _ => {}
    }
}

pub fn register_decls_two_phase(mut ctx: InferCtx, decls: List<Decl>) {
    let mut deferred_struct_names: List<Str> = []
    let mut deferred_enum_names: List<Str> = []

    for decl in decls {
        let result = some(register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names)) catch { _ => none }
    }

    for decl in decls {
        let result = some(register_phase2_struct(ctx, decl)) catch { _ => none }
    }
    for decl in decls {
        let result = some(register_phase2_enum(ctx, decl)) catch { _ => none }
    }

    // Phase 3: process delegates (after struct/enum fields are complete)
    for decl in decls {
        register_phase3_delegate(ctx, decl)
    }
}

fn register_phase3_delegate(mut ctx: InferCtx, decl: Decl) {
    match decl {
        Decl::Impl { target_type, type_params, methods, span, .. } => {
            // Check if any methods are delegates
            let mut has_delegates = false
            for m in methods {
                match m { Decl::Delegate { .. } => { has_delegates = true }, _ => {} }
            }
            if has_delegates {
                // Reconstruct type param scope and impl_methods_map for registration
                let saved = map_clone(ctx.type_param_scope)
                let mut impl_tv_ids: List<Int> = []
                for tp in type_params {
                    let tv = ctx.env.fresh_var()
                    match tv { Type::TypeVar { id, .. } => { impl_tv_ids.push(id) }, _ => {} }
                    ctx.type_param_scope.insert(tp.name, tv)
                }

                let mut impl_scheme_bounds: List<SchemeBound> = []
                let mut tp_idx = 0
                for tp in type_params {
                    for b in tp.bounds {
                        if tp_idx < impl_tv_ids.len() {
                            let tv_id = impl_tv_ids.get(tp_idx).unwrap()
                            impl_scheme_bounds.push(SchemeBound { type_var: tv_id, trait_name: b.trait_name, assoc_constraints: [] })
                            let supers = collect_all_supertraits(ctx, b.trait_name)
                            for st_name in supers {
                                impl_scheme_bounds.push(SchemeBound { type_var: tv_id, trait_name: st_name, assoc_constraints: [] })
                            }
                        }
                    }
                    tp_idx = tp_idx + 1
                }

                let mut impl_methods_map = match ctx.env.trait_reg.impl_methods.get(target_type) {
                    some(m) => m,
                    none => {
                        let mut new_map: Map<Str, TypeScheme> = map_new()
                        ctx.env.trait_reg.impl_methods.insert(target_type, new_map)
                        new_map
                    }
                }

                for m in methods {
                    match m {
                        Decl::Delegate { field, trait_names, span: dspan } => {
                            register_delegate(ctx, impl_methods_map, impl_tv_ids, target_type,
                                field, trait_names, dspan, impl_scheme_bounds, saved, type_params)
                        },
                        _ => {}
                    }
                }

                ctx.type_param_scope = saved
            }
        },
        Decl::ModBlock { name: mod_name, decls: mod_decls, .. } => {
            for d in mod_decls {
                let prefixed = prefix_decl_name(mod_name, d)
                register_phase3_delegate(ctx, prefixed)
            }
        },
        _ => {}
    }
}

// ============================================================
// Struct registration
// ============================================================

fn preregister_struct(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>) {
    let mut tp_names: List<Str> = []
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let def = StructDef { name: name, type_params: tp_names, type_param_vars: tp_vars, fields: [], is_extern: false }
    ctx.env.types.structs.insert(name, def)
}

fn complete_struct_fields(mut ctx: InferCtx, name: Str, fields: List<StructFieldDecl>) {
    match ctx.env.types.structs.get(name) {
        some(def) => {
            let saved = map_clone(ctx.type_param_scope)
            let mut i = 0
            while i < def.type_params.len() {
                match (def.type_params.get(i), def.type_param_vars.get(i)) {
                    (some(tp_name), some(tp_var)) =>
                        ctx.type_param_scope.insert(tp_name, Type::TypeVar { id: tp_var, name: none }),
                    _ => {}
                }
                i = i + 1
            }
            for f in fields {
                def.fields.push(StructField {
                    name: f.name,
                    ty: resolve_type_expr(ctx, f.type_annotation),
                    is_pub: f.is_pub
                })
            }
            ctx.type_param_scope = saved
        },
        none => {}
    }
}

// ============================================================
// Enum registration
// ============================================================

fn preregister_enum(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>) {
    let mut tp_names: List<Str> = []
    let mut tv_ids: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tv_ids.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let def = EnumDef { name: name, type_params: tp_names, type_param_vars: tv_ids, variants: [], variant_index: map_new() }
    ctx.env.types.enums.insert(name, def)
}

fn complete_enum_variants(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, variants: List<EnumVariantDecl>) {
    match ctx.env.types.enums.get(name) {
        some(def) => {
            let saved = map_clone(ctx.type_param_scope)
            let mut tv_types: List<Type> = []
            let mut i = 0
            while i < def.type_params.len() {
                match (def.type_params.get(i), def.type_param_vars.get(i)) {
                    (some(tp_name), some(tp_var)) => {
                        let tv = Type::TypeVar { id: tp_var, name: none }
                        ctx.type_param_scope.insert(tp_name, tv)
                        tv_types.push(tv)
                    },
                    _ => {}
                }
                i = i + 1
            }

            let mut vi = 0
            for v in variants {
                match v.named_fields {
                    some(nf) => {
                        if nf.len() > 0 {
                            let mut field_types: List<Type> = []
                            let mut field_names: List<Str> = []
                            for f in nf {
                                field_types.push(resolve_type_expr(ctx, f.type_expr))
                                field_names.push(f.name)
                            }
                            def.variants.push(EnumVariant { name: v.name, fields: field_types, field_names: some(field_names) })
                        } else {
                            let mut field_types: List<Type> = []
                            for f in v.fields { field_types.push(resolve_type_expr(ctx, f)) }
                            def.variants.push(EnumVariant { name: v.name, fields: field_types, field_names: none })
                        }
                    },
                    none => {
                        let mut field_types: List<Type> = []
                        for f in v.fields { field_types.push(resolve_type_expr(ctx, f)) }
                        def.variants.push(EnumVariant { name: v.name, fields: field_types, field_names: none })
                    }
                }
                def.variant_index.insert(v.name, vi)
                vi = vi + 1
            }

            let enum_type = Type::EnumType { name: name, type_params: tv_types, variants: def.variants }
            let tv_ids = def.type_param_vars
            for variant in def.variants {
                ctx.env.types.variant_to_enum.insert(variant.name, name)
                if variant.field_names.is_some() {
                    bind_variant_constructor(ctx, variant.name, enum_type, tv_ids)
                } else if variant.fields.len() == 0 {
                    bind_variant_constructor(ctx, variant.name, enum_type, tv_ids)
                } else {
                    let fn_type = Type::FnType { params: variant.fields, return_type: enum_type, effects: EMPTY_ROW }
                    if tv_ids.len() > 0 {
                        ctx.env.bind(variant.name, TypeScheme { ty: fn_type, type_vars: tv_ids, bounds: [], def_id: none })
                    } else {
                        ctx.env.bind_mono(variant.name, fn_type)
                    }
                }
            }

            ctx.type_param_scope = saved
        },
        none => {}
    }
}

fn bind_variant_constructor(mut ctx: InferCtx, variant_name: Str, enum_type: Type, tv_ids: List<Int>) {
    if tv_ids.len() > 0 {
        ctx.env.bind(variant_name, TypeScheme { ty: enum_type, type_vars: tv_ids, bounds: [], def_id: none })
    } else {
        ctx.env.bind_mono(variant_name, enum_type)
    }
}

// ============================================================
// Effect registration
// ============================================================

fn register_effect(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, ops: List<EffectOpDecl>) {
    let saved = map_clone(ctx.type_param_scope)
    let mut tp_names: List<Str> = []
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let mut effect_ops: List<EffectOpDef> = []
    for op in ops {
        let mut param_types: List<Type> = []
        for p in op.params {
            match p.type_annotation {
                some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
                none => param_types.push(ctx.env.fresh_var())
            }
        }
        let ret = resolve_type_expr(ctx, op.return_type)
        let op_has_default = op.body.is_some()
        effect_ops.push(EffectOpDef { name: op.name, params: param_types, return_type: ret, has_default: op_has_default })
    }
    let mut all_defaults = true
    for eop in effect_ops {
        if !eop.has_default { all_defaults = false }
    }
    if effect_ops.len() == 0 { all_defaults = false }
    ctx.type_param_scope = saved
    ctx.env.types.effects.insert(name, EffectDef { name: name, type_params: tp_names, type_param_vars: tp_vars, ops: effect_ops, built_in_kind: none, all_have_defaults: all_defaults })
}

// ============================================================
// Trait registration
// ============================================================

// Recursively collect all supertraits (transitive closure).
// For example, if Top: Mid, Mid: Base, then collect_all_supertraits(_, "Top") = ["Mid", "Base"]
pub fn collect_all_supertraits(ctx: InferCtx, trait_name: Str) -> List<Str> {
    let mut result: List<Str> = []
    let mut visited: Set<Str> = set_new()
    let mut stack: List<Str> = []
    match ctx.env.trait_reg.traits.get(trait_name) {
        some(tdef) => {
            for st in tdef.supertraits { stack.push(st) }
        },
        none => {}
    }
    while stack.len() > 0 {
        let current = stack.pop().unwrap()
        if visited.contains(current) { continue }
        visited.insert(current)
        result.push(current)
        match ctx.env.trait_reg.traits.get(current) {
            some(parent_def) => {
                for parent_st in parent_def.supertraits {
                    stack.push(parent_st)
                }
            },
            none => {}
        }
    }
    result
}

fn register_trait(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, supertraits: List<TypeBound>, methods: List<Decl>, span: Span) {
    let saved = map_clone(ctx.type_param_scope)
    let saved_qualified_assoc = map_clone(ctx.qualified_assoc_scope)
    let mut tp_names: List<Str> = []
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }

    // Validate and collect supertrait names
    let mut supertrait_names: List<Str> = []
    for st in supertraits {
        if !ctx.env.trait_reg.traits.contains_key(st.trait_name) {
            let _ = type_error(ctx.sink, E0501,
                "Unknown supertrait: ${st.trait_name}", span,
                DiagnosticContext::TraitError { detail: "unknown supertrait '${st.trait_name}'" })
        } else {
            supertrait_names.push(st.trait_name)
        }
    }

    // Detect cyclic supertrait inheritance via DFS
    for st_name in supertrait_names {
        let mut visited: Set<Str> = set_new()
        visited.insert(name)
        let mut stack: List<Str> = [st_name]
        while stack.len() > 0 {
            let current = stack.pop().unwrap()
            if visited.contains(current) {
                let _ = type_error(ctx.sink, E0506,
                    "Cyclic supertrait inheritance: '${name}' -> '${current}'", span,
                    DiagnosticContext::TraitError { detail: "cyclic supertrait inheritance" })
                break
            }
            visited.insert(current)
            match ctx.env.trait_reg.traits.get(current) {
                some(parent_def) => {
                    for parent_st in parent_def.supertraits {
                        stack.push(parent_st)
                    }
                },
                none => {}
            }
        }
    }

    let self_var = ctx.env.fresh_var()

    // Collect associated types first, inject into type_param_scope
    let mut assoc_type_defs: List<AssocTypeDef> = []
    for method in methods {
        match method {
            Decl::AssocType { name: aname, bounds: abounds, value: avalue, .. } => {
                // Create a named type variable for this associated type
                // so error messages show "Item" instead of "?NNN"
                let at_var_id = ctx.env.fresh_var_id()
                let at_var = Type::TypeVar { id: at_var_id, name: some(aname) }
                ctx.type_param_scope.insert(aname, at_var)
                let mut bound_names: List<Str> = []
                for b in abounds {
                    bound_names.push(b.trait_name)
                }
                let default_ty = match avalue {
                    some(v) => some(resolve_type_expr(ctx, v)),
                    none => none
                }
                assoc_type_defs.push(AssocTypeDef { name: aname, bounds: bound_names, default_type: default_ty, var_id: at_var_id })
            },
            _ => {}
        }
    }

    // Inject Self into type_param_scope so Self::Item resolves in trait method signatures
    ctx.type_param_scope.insert("Self", self_var)
    // Inject Self::Item into qualified_assoc_scope
    for atd in assoc_type_defs {
        match ctx.type_param_scope.get(atd.name) {
            some(at_ty) => {
                ctx.qualified_assoc_scope.insert("Self::${atd.name}", at_ty)
            },
            none => {}
        }
    }

    let mut trait_methods: List<TraitMethodDef> = []
    for method in methods {
        match method {
            Decl::Fn { name: mname, type_params: method_tps, params, return_type, declared_effects, is_abstract, .. } => {
                let mut param_types: List<Type> = []
                let mut param_muts: List<Bool> = []
                for p in params {
                    param_muts.push(p.is_mutable)
                    if p.name == "self" {
                        param_types.push(self_var)
                    } else {
                        match p.type_annotation {
                            some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
                            none => param_types.push(ctx.env.fresh_var())
                        }
                    }
                }
                let ret = match return_type {
                    some(rt) => resolve_type_expr(ctx, rt),
                    none => ctx.env.fresh_var()
                }
                // #77: Resolve declared effects so delegate forwarding can propagate evidence
                let method_effects = match declared_effects {
                    some(de) => resolve_declared_effects(ctx, de),
                    none => EMPTY_ROW
                }
                let fn_type = Type::FnType { params: param_types, return_type: ret, effects: method_effects }
                trait_methods.push(TraitMethodDef { name: mname, ty: fn_type, has_default: !is_abstract, param_mutabilities: param_muts, method_type_params: method_tps })
            },
            _ => {}
        }
    }

    ctx.type_param_scope = saved
    ctx.qualified_assoc_scope = saved_qualified_assoc
    ctx.env.trait_reg.traits.insert(name, TraitDef { name: name, type_params: tp_names, type_param_vars: tp_vars, methods: trait_methods, supertraits: supertrait_names, assoc_types: assoc_type_defs })
}

// ============================================================
// Impl registration
// ============================================================

fn register_impl(mut ctx: InferCtx, target_type: Str, type_params: List<TypeParam>, trait_name: Str?, methods: List<Decl>, span: Span) {
    let mut impl_methods_map = match ctx.env.trait_reg.impl_methods.get(target_type) {
        some(m) => m,
        none => {
            let mut new_map: Map<Str, TypeScheme> = map_new()
            ctx.env.trait_reg.impl_methods.insert(target_type, new_map)
            new_map
        }
    }

    let saved = map_clone(ctx.type_param_scope)
    let saved_qualified_assoc = map_clone(ctx.qualified_assoc_scope)
    let mut impl_tv_ids: List<Int> = []
    for tp in type_params {
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { impl_tv_ids.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }

    let mut impl_scheme_bounds: List<SchemeBound> = []
    let mut tp_idx = 0
    for tp in type_params {
        for b in tp.bounds {
            if tp_idx < impl_tv_ids.len() {
                let tv_id = impl_tv_ids.get(tp_idx).unwrap()
                impl_scheme_bounds.push(SchemeBound { type_var: tv_id, trait_name: b.trait_name, assoc_constraints: [] })
                // Expand supertrait bounds
                let supers = collect_all_supertraits(ctx, b.trait_name)
                for st_name in supers {
                    impl_scheme_bounds.push(SchemeBound { type_var: tv_id, trait_name: st_name, assoc_constraints: [] })
                }
            }
        }
        tp_idx = tp_idx + 1
    }

    // Collect associated type assignments from impl
    let mut assoc_type_map: Map<Str, Type> = map_new()
    for method in methods {
        match method {
            Decl::AssocType { name: aname, value: avalue, span: aspan, .. } => {
                match avalue {
                    some(v) => {
                        let resolved_ty = resolve_type_expr(ctx, v)
                        assoc_type_map.insert(aname, resolved_ty)
                        // Also inject into type_param_scope so method signatures can reference it
                        ctx.type_param_scope.insert(aname, resolved_ty)
                    },
                    none => {
                        // impl must provide a value
                        let _ = type_error(ctx.sink, E0510,
                            "Associated type '${aname}' must have a value in impl",
                            aspan, DiagnosticContext::TraitError { detail: "missing associated type value" })
                    }
                }
            },
            _ => {}
        }
    }

    // Inject Self into type_param_scope so Self::Item resolves in impl method signatures
    let impl_self_type = resolve_impl_self_type(ctx, target_type, type_params)
    ctx.type_param_scope.insert("Self", impl_self_type)
    // Inject Self::Item into qualified_assoc_scope
    for entry in assoc_type_map.entries() {
        let (aname, aty) = entry
        ctx.qualified_assoc_scope.insert("Self::${aname}", aty)
    }

    for method in methods {
        match method {
            Decl::Fn { name: mname, type_params: mtps, params, return_type, declared_effects, .. } =>
                register_impl_method(ctx, impl_methods_map, impl_tv_ids, target_type, mname, mtps, params, return_type, declared_effects, impl_scheme_bounds, saved, type_params, false),
            Decl::ExternFn { name: mname, type_params: mtps, params, return_type, declared_effects, .. } =>
                register_impl_method(ctx, impl_methods_map, impl_tv_ids, target_type, mname, mtps, params, return_type, declared_effects, impl_scheme_bounds, saved, type_params, true),
            Decl::Delegate { .. } => {},  // Deferred to register_phase3_delegate (needs complete struct fields)
            Decl::AssocType { .. } => {},  // Already handled above
            _ => {}
        }
    }

    match trait_name {
        some(tname) => {
            match ctx.env.trait_reg.traits.get(tname) {
                some(trait_def) => {
                    let mut impl_method_names: Set<Str> = set_new()
                    for m in methods {
                        match m { Decl::Fn { name: mn, .. } => { impl_method_names.insert(mn) }, _ => {} }
                    }
                    for tm in trait_def.methods {
                        if !tm.has_default && !impl_method_names.contains(tm.name) {
                            let _ = type_error(ctx.sink, E0502,
                                "Missing method '${tm.name}' in impl ${tname} for ${target_type}",
                                span, DiagnosticContext::TraitError { detail: "missing method '${tm.name}'" })
                        }
                    }

                    // Validate associated types
                    let mut impl_assoc_names: Set<Str> = set_new()
                    for entry in assoc_type_map.entries() {
                        let (aname, _) = entry
                        impl_assoc_names.insert(aname)
                    }
                    // Check: every trait assoc type is provided (or has default)
                    for atdef in trait_def.assoc_types {
                        if !impl_assoc_names.contains(atdef.name) {
                            match atdef.default_type {
                                some(dt) => {
                                    // Use the default
                                    assoc_type_map.insert(atdef.name, dt)
                                },
                                none => {
                                    let _ = type_error(ctx.sink, E0510,
                                        "Missing associated type '${atdef.name}' in impl ${tname} for ${target_type}",
                                        span, DiagnosticContext::TraitError { detail: "missing associated type '${atdef.name}'" })
                                }
                            }
                        }
                    }
                    // Check: no extra assoc types in impl that trait doesn't declare
                    let mut trait_assoc_names: Set<Str> = set_new()
                    for atdef in trait_def.assoc_types {
                        trait_assoc_names.insert(atdef.name)
                    }
                    for entry in assoc_type_map.entries() {
                        let (aname, _) = entry
                        if !trait_assoc_names.contains(aname) {
                            let _ = type_error(ctx.sink, E0514,
                                "Unexpected associated type '${aname}' in impl ${tname} for ${target_type}; trait '${tname}' does not declare it",
                                span, DiagnosticContext::TraitError { detail: "unexpected associated type '${aname}'" })
                        }
                    }

                    // Validate associated type bounds are satisfied
                    for atdef in trait_def.assoc_types {
                        if atdef.bounds.len() > 0 {
                            match assoc_type_map.get(atdef.name) {
                                some(concrete_ty) => {
                                    let concrete_name = type_to_builtin_name(concrete_ty)
                                    match concrete_name {
                                        some(cname) => {
                                            for bound_trait in atdef.bounds {
                                                if !has_impl(ctx.env.trait_reg, cname, bound_trait) {
                                                    let _ = type_error(ctx.sink, E0513,
                                                        "Associated type '${atdef.name}' requires '${bound_trait}', but '${type_to_string(concrete_ty)}' does not implement it",
                                                        span, DiagnosticContext::TraitError { detail: "associated type bound '${bound_trait}' not satisfied by '${cname}'" })
                                                }
                                            }
                                        },
                                        none => {}  // TypeVar or other non-named types: skip bound check
                                    }
                                },
                                none => {}  // Missing assoc type already reported via E0510
                            }
                        }
                    }

                    // Validate supertrait impls exist (recursively)
                    let all_supertraits = collect_all_supertraits(ctx, tname)
                    for required_st in all_supertraits {
                        if !has_impl(ctx.env.trait_reg, target_type, required_st) {
                            let _ = type_error(ctx.sink, E0505,
                                "Type '${target_type}' does not implement supertrait '${required_st}' required by '${tname}'",
                                span, DiagnosticContext::TraitError { detail: "missing supertrait impl '${required_st}'" })
                        }
                    }

                    let mut tp_names: List<Str> = []
                    for tp in type_params { tp_names.push(tp.name) }
                    let mut method_names: List<Str> = []
                    for m in methods {
                        match m {
                            Decl::Fn { name: mn, .. } => { method_names.push(mn) },
                            Decl::ExternFn { name: mn, .. } => { method_names.push(mn) },
                            _ => {}
                        }
                    }
                    add_impl(ctx.env.trait_reg, ImplEntry {
                        trait_name: tname, target_type_name: target_type,
                        type_params: tp_names, method_names: method_names,
                        assoc_types: map_clone(assoc_type_map)
                    })
                },
                none => { let _ = type_error(ctx.sink, E0501,
                    "Unknown trait: ${tname}", span,
                    DiagnosticContext::TraitError { detail: "unknown trait '${tname}'" }) }
            }
        },
        none => {}
    }

    ctx.type_param_scope = saved
    ctx.qualified_assoc_scope = saved_qualified_assoc
}

// Construct the self type for an impl method, using the impl's type params
// from type_param_scope instead of creating unrelated fresh vars.
// This ensures the self type shares the same type variables as the rest of
// the method signature, so instantiation correctly replaces all occurrences.
fn resolve_impl_self_type(mut ctx: InferCtx, target_type: Str, impl_type_params: List<TypeParam>) -> Type {
    if impl_type_params.len() == 0 {
        return resolve_self_type(ctx, target_type)
    }
    let mut impl_tp_types: List<Type> = []
    for tp in impl_type_params {
        match ctx.type_param_scope.get(tp.name) {
            some(tv) => impl_tp_types.push(tv),
            none => impl_tp_types.push(ctx.env.fresh_var())
        }
    }
    match ctx.env.types.structs.get(target_type) {
        some(def) => Type::StructType { name: def.name, type_params: impl_tp_types, fields: def.fields },
        none => match ctx.env.types.enums.get(target_type) {
            some(def) => Type::EnumType { name: def.name, type_params: impl_tp_types, variants: def.variants },
            none => resolve_self_type(ctx, target_type)
        }
    }
}

fn register_impl_method(
    mut ctx: InferCtx, mut methods_map: Map<Str, TypeScheme>, impl_tv_ids: List<Int>,
    target_type: Str, mname: Str, mtps: List<TypeParam>, params: List<Param>,
    return_type: TypeExpr?, declared_effects: List<EffectExpr>?, impl_scheme_bounds: List<SchemeBound>, outer_saved: Map<Str, Type>,
    impl_type_params: List<TypeParam>, is_extern: Bool
) {
    let saved_method = map_clone(ctx.type_param_scope)
    let mut method_tv_ids: List<Int> = []
    for mtp in mtps {
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { method_tv_ids.push(id) }, _ => {} }
        ctx.type_param_scope.insert(mtp.name, tv)
    }

    let self_type = resolve_impl_self_type(ctx, target_type, impl_type_params)
    let mut param_types: List<Type> = []
    for p in params {
        match p.type_annotation {
            some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
            none => if p.name == "self" { param_types.push(self_type) } else { param_types.push(ctx.env.fresh_var()) }
        }
    }
    let ret = match return_type { some(rt) => resolve_type_expr(ctx, rt), none => ctx.env.fresh_var() }

    let mut all_tvs = list_clone(impl_tv_ids)
    for mtv in method_tv_ids { all_tvs.push(mtv) }

    // Non-extern methods: filter unused type variables from outer scope
    if !is_extern {
        let mut declared_names: Set<Str> = set_new()
        for entry in ctx.type_param_scope.entries() {
            let (tpname, _) = entry
            if outer_saved.contains_key(tpname) { declared_names.insert(tpname) }
        }
        for entry in ctx.type_param_scope.entries() {
            let (tpname, tv) = entry
            if !outer_saved.contains_key(tpname) && !declared_names.contains(tpname) {
                match tv { Type::TypeVar { id, .. } => {
                    if !all_tvs.contains(id) { all_tvs.push(id) }
                }, _ => {} }
            }
        }
    }

    let impl_m_effects = match declared_effects {
        some(de) => resolve_declared_effects(ctx, de),
        none => EMPTY_ROW
    }
    let fn_type = Type::FnType { params: param_types, return_type: ret, effects: impl_m_effects }
    methods_map.insert(mname, TypeScheme { ty: fn_type, type_vars: all_tvs, bounds: impl_scheme_bounds, def_id: none })

    // Track mut self methods
    if params.len() > 0 {
        match params.first() {
            some(first_p) => {
                if first_p.name == "self" && first_p.is_mutable {
                    let mut mut_set = match ctx.env.trait_reg.mut_methods.get(target_type) {
                        some(s) => s,
                        none => {
                            let mut new_set: Set<Str> = set_new()
                            ctx.env.trait_reg.mut_methods.insert(target_type, new_set)
                            new_set
                        }
                    }
                    mut_set.insert(mname)
                }
            },
            none => {}
        }
    }

    ctx.type_param_scope = saved_method
}

// ============================================================
// Delegate registration
// ============================================================

fn register_delegate(
    mut ctx: InferCtx, mut methods_map: Map<Str, TypeScheme>, impl_tv_ids: List<Int>,
    target_type: Str, field: Str, trait_names: List<Str>, span: Span,
    impl_scheme_bounds: List<SchemeBound>, outer_saved: Map<Str, Type>,
    impl_type_params: List<TypeParam>
) {
    // 1. Validate field exists on target struct
    match ctx.env.types.structs.get(target_type) {
        none => {
            let _ = type_error(ctx.sink, E0507,
                "delegate can only be used on struct types, '${target_type}' is not a struct",
                span, DiagnosticContext::TraitError { detail: "delegate on non-struct type" })
        },
        some(struct_def) => {
            let mut field_type: Type? = none
            for f in struct_def.fields {
                if f.name == field {
                    field_type = some(f.ty)
                }
            }
            match field_type {
                none => {
                    let _ = type_error(ctx.sink, E0507,
                        "field '${field}' not found in struct '${target_type}'",
                        span, DiagnosticContext::TraitError { detail: "delegate field not found" })
                },
                some(ft) => {
                    // Get the field type name for looking up trait impls
                    let mut field_type_name: Str? = none
                    match ft {
                        Type::StructType { name, .. } => { field_type_name = some(name) },
                        Type::EnumType { name, .. } => { field_type_name = some(name) },
                        _ => {
                            let _ = type_error(ctx.sink, E0507,
                                "delegate field '${field}' must have a named type (struct or enum)",
                                span, DiagnosticContext::TraitError { detail: "delegate field has unnamed type" })
                        }
                    }
                    match field_type_name {
                        none => {},
                        some(ftn) => {
                            register_delegate_traits(ctx, methods_map, impl_tv_ids, target_type,
                                field, trait_names, span, impl_scheme_bounds, impl_type_params, ftn, ft)
                        }
                    }
                }
            }
        }
    }
}

fn register_delegate_traits(
    mut ctx: InferCtx, mut methods_map: Map<Str, TypeScheme>, impl_tv_ids: List<Int>,
    target_type: Str, field: Str, trait_names: List<Str>, span: Span,
    impl_scheme_bounds: List<SchemeBound>, impl_type_params: List<TypeParam>,
    field_type_name: Str, ft: Type
) {
    for tname in trait_names {
        match ctx.env.trait_reg.traits.get(tname) {
            none => {
                let _ = type_error(ctx.sink, E0501,
                    "Unknown trait: ${tname}",
                    span, DiagnosticContext::TraitError { detail: "unknown trait '${tname}'" })
            },
            some(trait_def) => {
                // Validate that the field type implements the trait
                if !has_impl(ctx.env.trait_reg, field_type_name, tname) {
                    let _ = type_error(ctx.sink, E0508,
                        "type '${field_type_name}' (field '${field}') does not implement trait '${tname}'",
                        span, DiagnosticContext::TraitError { detail: "delegate field type missing trait impl" })
                } else {
                    // Check for conflict: same trait already implemented (hand-written) for this type
                    if has_impl(ctx.env.trait_reg, target_type, tname) {
                        let _ = type_error(ctx.sink, E0509,
                            "trait '${tname}' is already implemented for '${target_type}'; cannot delegate the same trait",
                            span, DiagnosticContext::TraitError { detail: "delegate conflicts with existing impl" })
                        continue
                    }
                    // Collect all traits to register: the explicit trait + its supertraits
                    let mut all_traits_to_register: List<Str> = [tname]
                    let supers = collect_all_supertraits(ctx, tname)
                    for st_name in supers {
                        all_traits_to_register.push(st_name)
                    }

                    let self_type = resolve_impl_self_type(ctx, target_type, impl_type_params)

                    for reg_tname in all_traits_to_register {
                        // Check if this trait (or supertrait) is already implemented
                        if has_impl(ctx.env.trait_reg, target_type, reg_tname) { continue }

                        // Validate that the field type implements this trait
                        if !has_impl(ctx.env.trait_reg, field_type_name, reg_tname) { continue }

                        match ctx.env.trait_reg.traits.get(reg_tname) {
                            none => {},
                            some(reg_trait_def) => {
                                // #128: Copy assoc_types from field type's ImplEntry
                                let mut field_assoc_types: Map<Str, Type> = map_new()
                                match find_impl(ctx.env.trait_reg, field_type_name, reg_tname) {
                                    some(field_impl) => { field_assoc_types = map_clone(field_impl.assoc_types) },
                                    none => {}
                                }

                                // Register ImplEntry
                                let mut tp_names: List<Str> = []
                                for tp in impl_type_params { tp_names.push(tp.name) }
                                let mut method_names: List<Str> = []
                                for tm in reg_trait_def.methods { method_names.push(tm.name) }
                                add_impl(ctx.env.trait_reg, ImplEntry {
                                    trait_name: reg_tname, target_type_name: target_type,
                                    type_params: tp_names, method_names: method_names,
                                    assoc_types: map_clone(field_assoc_types)
                                })

                                // #125: Get field type's registered methods for resolved assoc types
                                let field_methods = ctx.env.trait_reg.impl_methods.get(field_type_name)

                                // Register forwarding methods for each trait method
                                for tm in reg_trait_def.methods {
                                    match tm.ty {
                                        Type::FnType { params: trait_params, return_type: trait_ret_ty, effects: trait_eff } => {
                                            // #125: Use resolved return type/effects from field type's
                                            // method (has concrete assoc types) if available. Keep trait
                                            // def's param types for Self type var structure.
                                            let resolved_method_scheme = match field_methods {
                                                some(fm_map) => fm_map.get(tm.name),
                                                none => none
                                            }
                                            let ret_ty = match resolved_method_scheme {
                                                some(rs) => match rs.ty {
                                                    Type::FnType { return_type: rr, .. } => rr,
                                                    _ => trait_ret_ty
                                                },
                                                none => trait_ret_ty
                                            }
                                            let eff = match resolved_method_scheme {
                                                some(rs) => match rs.ty {
                                                    Type::FnType { effects: re, .. } => re,
                                                    _ => trait_eff
                                                },
                                                none => trait_eff
                                            }
                                            // Build param types: replace first param (Self) with target_type
                                            let mut param_types: List<Type> = []
                                            let mut first = true
                                            for tp in trait_params {
                                                if first {
                                                    param_types.push(self_type)
                                                    first = false
                                                } else {
                                                    param_types.push(tp)
                                                }
                                            }
                                            let fn_type = Type::FnType { params: param_types, return_type: ret_ty, effects: eff }
                                            methods_map.insert(tm.name, TypeScheme { ty: fn_type, type_vars: list_clone(impl_tv_ids), bounds: impl_scheme_bounds, def_id: none })
                                        },
                                        _ => {}
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ============================================================
// Effect annotation resolution
// ============================================================

pub fn resolve_effect_expr(mut ctx: InferCtx, eff: EffectExpr) -> Effect {
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
    // Custom effects
    // Check custom effect exists; use the canonical (qualified) name from EffectDef
    // so that mod-internal unqualified references (e.g. "Greeter") resolve to the
    // same name as the declaration (e.g. "fx::Greeter") for evidence matching.
    let canonical_name = match ctx.env.types.effects.get(eff.name) {
        some(edef) => edef.name,
        none => {
            let _ = type_error(ctx.sink, E0407,
                "Unknown effect '${eff.name}'", eff.span,
                DiagnosticContext::OtherContext { detail: some("unknown effect") })
            eff.name
        }
    }
    let mut resolved_args: List<Type> = []
    for ta in eff.type_args {
        resolved_args.push(resolve_type_expr(ctx, ta))
    }
    Effect::CustomEffect { name: canonical_name, type_args: resolved_args }
}

fn expand_effect_exprs(mut ctx: InferCtx, decl_effects: List<EffectExpr>, mut expanding: Set<Str>) -> List<Effect> {
    let mut effects: List<Effect> = []
    for eff in decl_effects {
        match ctx.env.types.effect_aliases.get(eff.name) {
            some(alias_def) => {
                // Cycle detection
                if expanding.contains(eff.name) {
                    let _ = type_error(ctx.sink, E0406,
                        "Cyclic effect alias: '${eff.name}' references itself", eff.span,
                        DiagnosticContext::OtherContext { detail: some("cyclic effect alias") })
                } else {
                    expanding.insert(eff.name)

                    // Save any existing type_param_scope entries that alias type params might shadow
                    let mut saved_scope: List<(Str, Type?)> = []
                    let mut vi = 0
                    for tp_name in alias_def.type_params {
                        saved_scope.push((tp_name, ctx.type_param_scope.get(tp_name)))
                        // Install alias's fresh type vars into type_param_scope
                        match alias_def.type_param_vars.get(vi) {
                            some(var_id) => {
                                ctx.type_param_scope.insert(tp_name, Type::TypeVar { id: var_id, name: none })
                            },
                            none => {}
                        }
                        vi = vi + 1
                    }

                    // Recursively expand the alias body effects using the fresh type vars in scope
                    let expanded = expand_effect_exprs(ctx, alias_def.effects, expanding)

                    // Restore saved type_param_scope entries
                    for entry in saved_scope {
                        match entry {
                            (name, some(prev_type)) => { ctx.type_param_scope.insert(name, prev_type) },
                            (name, none) => { ctx.type_param_scope.remove(name) }
                        }
                    }

                    // Build substitution map: alias type_param_vars -> resolved call-site type args
                    let mut subst_map: Map<Int, Type> = map_new()
                    let mut si = 0
                    while si < alias_def.type_param_vars.len() && si < eff.type_args.len() {
                        match (alias_def.type_param_vars.get(si), eff.type_args.get(si)) {
                            (some(var_id), some(ta)) => {
                                subst_map.insert(var_id, resolve_type_expr(ctx, ta))
                            },
                            _ => {}
                        }
                        si = si + 1
                    }

                    // Apply type var substitution to each expanded effect
                    for e in expanded {
                        effects.push(apply_subst_effect_map(subst_map, e))
                    }

                    expanding.remove(eff.name)
                }
            },
            none => {
                effects.push(resolve_effect_expr(ctx, eff))
            }
        }
    }
    effects
}

pub fn resolve_declared_effects(mut ctx: InferCtx, decl_effects: List<EffectExpr>) -> EffectRow {
    let mut expanding: Set<Str> = set_new()
    let effects = expand_effect_exprs(ctx, decl_effects, expanding)
    // Deduplicate effects after alias expansion (e.g. {IO, io} -> [io, fail<Str>, io] -> [io, fail<Str>])
    let mut deduped: List<Effect> = []
    let mut seen: Set<Str> = set_new()
    for eff in effects {
        let key = effect_to_string(eff)
        if !seen.contains(key) {
            seen.insert(key)
            deduped.push(eff)
        }
    }
    EffectRow { effects: deduped, tail: none }
}

// ============================================================
// Function registration
// ============================================================

fn check_duplicate_def(ctx: InferCtx, name: Str, span: Span) {
    match ctx.env.lookup(name) {
        some(existing) => match existing.def_id {
            some(did) => match ctx.env.scope.def_spans.get(did) {
                some(_) => { let _ = type_error(ctx.sink, E0207,
                    "Duplicate definition: '${name}' is already defined", span,
                    DiagnosticContext::TypeMismatch { expected: "unique name", actual: name, expression: none }) },
                none => {}
            },
            none => {}
        },
        none => {}
    }
}

fn is_register_value_type(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::BoolType => true,
        Type::StrType => true,
        _ => false
    }
}

// Inject associated type variables into type_param_scope for type params with bounds.
// This makes T::Item references resolve during registration (Pass 1).
// Also resolves assoc_constraints (e.g., T: Trait<Item = Int>) by directly binding the
// associated type name to the concrete type.
pub fn inject_assoc_types_from_bounds(mut ctx: InferCtx, type_params: List<TypeParam>) {
    for tp in type_params {
        for b in tp.bounds {
            // First, handle explicit assoc constraints (Item = Int)
            for ac in b.assoc_constraints {
                let concrete_ty = resolve_type_expr(ctx, ac.ty)
                ctx.type_param_scope.insert(ac.name, concrete_ty)
                // Also insert into qualified_assoc_scope for disambiguation
                ctx.qualified_assoc_scope.insert("${tp.name}::${ac.name}", concrete_ty)
            }
            // Then, inject remaining associated types from trait definition
            match ctx.env.trait_reg.traits.get(b.trait_name) {
                some(tdef) => {
                    for atdef in tdef.assoc_types {
                        // Only inject if not already in scope (avoid overwriting constraints)
                        if !ctx.type_param_scope.contains_key(atdef.name) {
                            let at_var = ctx.env.fresh_var()
                            ctx.type_param_scope.insert(atdef.name, at_var)
                            ctx.qualified_assoc_scope.insert("${tp.name}::${atdef.name}", at_var)
                        } else {
                            // Already in scope (another type param's bound injected it).
                            // Still inject into qualified_assoc_scope with this type param's own fresh var.
                            let at_var = ctx.env.fresh_var()
                            ctx.qualified_assoc_scope.insert("${tp.name}::${atdef.name}", at_var)
                        }
                    }
                },
                none => {}
            }
        }
    }
}

// Shared helper for register_fn and register_extern_fn.
// - check_dup: call check_duplicate_def (true for fn, false for extern fn)
// - track_mut_params: track fn_mut_params (true for fn, false for extern fn)
// - track_fn_bounds: build fn_bounds_list and insert into scope (true for fn, false for extern fn)
fn register_fn_common(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    params: List<Param>, return_type: TypeExpr?, declared_effects: List<EffectExpr>?,
    span: Span, check_dup: Bool, track_mut_params: Bool, track_fn_bounds: Bool
) {
    if check_dup { check_duplicate_def(ctx, name, span) }

    let mut type_vars: List<Int> = []
    let saved = map_clone(ctx.type_param_scope)
    let saved_qualified = map_clone(ctx.qualified_assoc_scope)
    for tp in type_params {
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { type_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }

    // Inject associated types from type param bounds into type_param_scope
    // so that T::Item references in return types / param types resolve correctly.
    inject_assoc_types_from_bounds(ctx, type_params)

    let mut param_types: List<Type> = []
    if track_mut_params {
        let mut mut_flags: List<Bool> = []
        for p in params {
            let pt = match p.type_annotation {
                some(ta) => resolve_type_expr(ctx, ta),
                none => ctx.env.fresh_var()
            }
            param_types.push(pt)
            // Register fn_mut_params: only flag mut value-type params (not self)
            if p.name == "self" || !p.is_mutable {
                mut_flags.push(false)
            } else {
                mut_flags.push(is_register_value_type(pt))
            }
        }
        ctx.fn_mut_params.insert(name, mut_flags)
    } else {
        for p in params {
            match p.type_annotation {
                some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
                none => param_types.push(ctx.env.fresh_var())
            }
        }
    }
    let ret = match return_type { some(rt) => resolve_type_expr(ctx, rt), none => ctx.env.fresh_var() }

    let mut declared_names: Set<Str> = set_new()
    for tp in type_params { declared_names.insert(tp.name) }
    for entry in ctx.type_param_scope.entries() {
        let (tpname, tv) = entry
        if !saved.contains_key(tpname) && !declared_names.contains(tpname) {
            match tv { Type::TypeVar { id, .. } => { type_vars.push(id) }, _ => {} }
        }
    }

    let effects = match declared_effects {
        some(de) => resolve_declared_effects(ctx, de),
        none => EMPTY_ROW
    }
    let fn_type = Type::FnType { params: param_types, return_type: ret, effects: effects }

    let mut fn_bounds_list: List<FnBound> = []
    let mut scheme_bounds: List<SchemeBound> = []
    for tp in type_params {
        let tv = ctx.type_param_scope.get(tp.name)
        for b in tp.bounds {
            if !ctx.env.trait_reg.traits.contains_key(b.trait_name) {
                let _ = type_error(ctx.sink, E0501,
                    "Unknown trait: ${b.trait_name}", tp.span,
                    DiagnosticContext::TraitError { detail: "unknown trait '${b.trait_name}'" })
            }
            if track_fn_bounds {
                fn_bounds_list.push(FnBound { type_param: tp.name, trait_name: b.trait_name })
            }
            // Build associated type constraint entries from bound's assoc_constraints
            let mut assoc_entries: List<AssocConstraintEntry> = []
            for ac in b.assoc_constraints {
                let concrete_ty = resolve_type_expr(ctx, ac.ty)
                assoc_entries.push(AssocConstraintEntry { name: ac.name, ty: concrete_ty })
            }
            match tv {
                some(t) => match t { Type::TypeVar { id, .. } => {
                    scheme_bounds.push(SchemeBound { type_var: id, trait_name: b.trait_name, assoc_constraints: assoc_entries })
                }, _ => {} },
                none => {}
            }
            // Expand supertrait bounds: if T: Ord and Ord: Eq, add T: Eq too
            let supers = collect_all_supertraits(ctx, b.trait_name)
            for st_name in supers {
                if track_fn_bounds {
                    fn_bounds_list.push(FnBound { type_param: tp.name, trait_name: st_name })
                }
                match tv {
                    some(t) => match t { Type::TypeVar { id, .. } => {
                        scheme_bounds.push(SchemeBound { type_var: id, trait_name: st_name, assoc_constraints: [] })
                    }, _ => {} },
                    none => {}
                }
            }
        }
    }
    if track_fn_bounds && fn_bounds_list.len() > 0 {
        ctx.env.scope.fn_bounds.insert(name, fn_bounds_list)
    }

    ctx.type_param_scope = saved
    ctx.qualified_assoc_scope = saved_qualified

    if type_vars.len() > 0 {
        ctx.env.bind(name, TypeScheme { ty: fn_type, type_vars: type_vars, bounds: scheme_bounds, def_id: none })
    } else {
        ctx.env.bind_mono(name, fn_type)
    }
    match ctx.env.lookup(name) {
        some(s) => match s.def_id { some(did) => ctx.env.record_def_span(did, span), none => {} },
        none => {}
    }
}

fn register_fn(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, params: List<Param>, return_type: TypeExpr?, declared_effects: List<EffectExpr>?, span: Span) {
    register_fn_common(ctx, name, type_params, params, return_type, declared_effects, span, true, true, true)
}

fn register_extern_fn(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, params: List<Param>, return_type: TypeExpr?, declared_effects: List<EffectExpr>?, span: Span) {
    register_fn_common(ctx, name, type_params, params, return_type, declared_effects, span, false, false, false)
}

fn register_extern_type(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>) {
    let mut tp_names: List<Str> = []
    let saved = map_clone(ctx.type_param_scope)
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    ctx.type_param_scope = saved
    // is_extern: true marks this as an opaque FFI type so trait derivation skips
    // it (B-074). An opaque type has no fields to compare/clone/order/debug, and
    // a derived dict would reference a non-existent runtime constructor.
    ctx.env.types.structs.insert(name, StructDef { name: name, type_params: tp_names, type_param_vars: tp_vars, fields: [], is_extern: true })
}

fn register_type_alias(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, type_expr: TypeExpr) {
    let saved = map_clone(ctx.type_param_scope)
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let resolved = resolve_type_expr(ctx, type_expr)
    ctx.type_param_scope = saved
    let mut tp_names: List<Str> = []
    for tp in type_params { tp_names.push(tp.name) }
    ctx.env.types.type_aliases.insert(name, TypeAliasDef { type_params: tp_names, type_param_vars: tp_vars, ty: resolved })
}

fn register_const(mut ctx: InferCtx, name: Str, type_annotation: TypeExpr?, span: Span) {
    check_duplicate_def(ctx, name, span)
    match type_annotation {
        some(texpr) => {
            let ty = resolve_type_expr(ctx, texpr)
            ctx.env.bind_mono(name, ty)
        },
        none => {
            let tv = ctx.env.fresh_var()
            ctx.env.bind_mono(name, tv)
        }
    }
    match ctx.env.lookup(name) {
        some(s) => match s.def_id { some(did) => ctx.env.record_def_span(did, span), none => {} },
        none => {}
    }
}

fn register_sig(mut ctx: InferCtx, name: Str, members: List<SigMember>, is_pub: Bool) {
    let saved = map_clone(ctx.type_param_scope)
    let mut sig_members: Map<Str, TypeScheme> = map_new()
    for m in members {
        let mut type_vars: List<Int> = []
        let msaved = map_clone(ctx.type_param_scope)
        for tp in m.type_params {
            let tv = ctx.env.fresh_var()
            match tv { Type::TypeVar { id, .. } => { type_vars.push(id) }, _ => {} }
            ctx.type_param_scope.insert(tp.name, tv)
        }
        let mut param_types: List<Type> = []
        for p in m.params {
            match p.type_annotation {
                some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
                none => param_types.push(ctx.env.fresh_var())
            }
        }
        let ret = match m.return_type {
            some(rt) => resolve_type_expr(ctx, rt),
            none => ctx.env.fresh_var()
        }
        let fn_type = Type::FnType { params: param_types, return_type: ret, effects: EMPTY_ROW }
        sig_members.insert(m.name, TypeScheme { ty: fn_type, type_vars: type_vars, bounds: [], def_id: none })
        ctx.type_param_scope = msaved
    }
    ctx.type_param_scope = saved
    ctx.env.types.sigs.insert(name, SigDef { name: name, members: sig_members, is_pub: is_pub })
}

// ============================================================
// Effect alias registration
// ============================================================

fn register_effect_alias(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, effects: List<EffectExpr>, span: Span) {
    if ctx.env.types.effect_aliases.contains_key(name) {
        let _ = type_error(ctx.sink, E0207,
            "Duplicate definition: effect alias '${name}' is already defined", span,
            DiagnosticContext::OtherContext { detail: some("duplicate effect alias") })
    } else {
        let mut tp_names: List<Str> = []
        let mut tp_vars: List<Int> = []
        for tp in type_params {
            tp_names.push(tp.name)
            let tv = ctx.env.fresh_var()
            match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        }
        ctx.env.types.effect_aliases.insert(name, EffectAliasDef {
            name: name,
            type_params: tp_names,
            type_param_vars: tp_vars,
            effects: effects,
            span: span
        })
    }
}

// ============================================================
// Dispatch: register individual declaration
// ============================================================

fn register_decl(mut ctx: InferCtx, decl: Decl) {
    match decl {
        Decl::Struct { name, type_params, fields, span, .. } => {
            preregister_struct(ctx, name, type_params)
            complete_struct_fields(ctx, name, fields)
        },
        Decl::Enum { name, type_params, variants, span, .. } => {
            preregister_enum(ctx, name, type_params)
            complete_enum_variants(ctx, name, type_params, variants)
        },
        Decl::Effect { name, type_params, ops, .. } =>
            register_effect(ctx, name, type_params, ops),
        Decl::Impl { target_type, type_params, trait_name, methods, span } =>
            register_impl(ctx, target_type, type_params, trait_name, methods, span),
        Decl::Fn { name, type_params, params, return_type, declared_effects, span, .. } =>
            register_fn(ctx, name, type_params, params, return_type, declared_effects, span),
        Decl::Test { .. } => {},
        Decl::Trait { name, type_params, supertraits, methods, span, .. } =>
            register_trait(ctx, name, type_params, supertraits, methods, span),
        Decl::ExternFn { name, type_params, params, return_type, declared_effects, span, .. } =>
            register_extern_fn(ctx, name, type_params, params, return_type, declared_effects, span),
        Decl::ExternType { name, type_params, .. } =>
            register_extern_type(ctx, name, type_params),
        Decl::TypeAlias { name, type_params, type_expr, .. } =>
            register_type_alias(ctx, name, type_params, type_expr),
        Decl::Const { name, type_annotation, span, .. } =>
            register_const(ctx, name, type_annotation, span),
        Decl::Sig { name, members, is_pub, .. } =>
            register_sig(ctx, name, members, is_pub),
        Decl::EffectAlias { name, type_params, effects, span, .. } =>
            register_effect_alias(ctx, name, type_params, effects, span),
        Decl::Delegate { .. } => {},  // Only valid inside impl blocks, handled by register_impl
        Decl::AssocType { .. } => {},  // Only valid inside trait/impl blocks
        Decl::ModBlock { name: mod_name, decls: mod_decls, .. } => {
            register_mod_block_items(ctx, mod_name, mod_decls, none, none)
        }
    }
}
