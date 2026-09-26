use types::{Type, Effect, EffectRow}
use ast::{TypeParam}
use hir::{HExpr, HStmt, HDecl, HParam, HStructField, HEnumVariant,
    HEffectOp, HTraitMethod, TraitBound,
    trait_dict_name, evidence_param_name, default_evidence_name,
    trait_bound_param_name,
    default_method_self_name, ENUM_TAG_FIELD,
    hexpr_effects}
use codegen_ctx::{CodegenCtx, HTraitDeclInfo, emit, emit_raw, push_indent, pop_indent,
    qualify, safe_ident, extract_effect_names, get_evidence_params}
use codegen_stmt::{emit_block_body}
use codegen_expr::{gen_expr}

// ============================================================
// Top-level dispatch
// ============================================================

pub fn emit_decl(mut ctx: CodegenCtx, decl: HDecl) {
    match decl {
        HDecl::Fn { name, params, effects, body, trait_bounds, .. } =>
            emit_fn_decl(ctx, name, params, effects, body, trait_bounds, none),
        HDecl::Struct { name, fields, .. } =>
            emit_struct_decl(ctx, name, fields),
        HDecl::Enum { name, variants, .. } =>
            emit_enum_decl(ctx, name, variants),
        HDecl::Impl { target_type, trait_name, methods, assoc_types, .. } =>
            emit_impl_decl(ctx, target_type, trait_name, methods),
        HDecl::Effect { name, ops, .. } => emit_effect_decl(ctx, name, ops),
        HDecl::Test { description, body, .. } =>
            emit_test_decl(ctx, description, body),
        HDecl::Trait { name, methods, supertraits, assoc_types, .. } =>
            emit_trait_decl(ctx, name, methods, supertraits),
        HDecl::ExternFn { name, .. } =>
            emit_extern_fn_decl(ctx, name),
        HDecl::ExternType { name, is_pub, .. } => {
            if is_pub {
                let sn = safe_ident(name)
                let qn = qualify(ctx, name)
                emit(ctx, "const ${qn} = \"${sn}\";")
            }
        },
        HDecl::TypeAlias { .. } => {},
        HDecl::Const { name, init, .. } => emit_const_decl(ctx, name, init),
        HDecl::ModBlock { decls: mod_decls, .. } => {
            for subdecl in mod_decls {
                emit_decl(ctx, subdecl)
            }
        },
        HDecl::Sig { .. } => {},
    }
}

// ============================================================
// Function declarations
// ============================================================

pub fn emit_fn_decl(mut ctx: CodegenCtx, name: Str, params: List<HParam>, effects: EffectRow, body: HExpr, trait_bounds: List<TraitBound>, prefix: Str?) {
    let fn_name = match prefix {
        some(p) => {
            let sn = safe_ident(name)
            "${p}_${sn}"
        },
        none => qualify(ctx, name),
    }
    let mut param_names: List<Str> = []
    for p in params { param_names.push(safe_ident(p.name)) }
    let mut dict_params: List<Str> = []
    for b in trait_bounds {
        dict_params.push(trait_bound_param_name(b.type_param, b.trait_name))
    }
    let effective_effects = match ctx.local_fn_effects.get(name) {
        some(eff) => eff,
        none => effects,
    }
    let ev_params = get_evidence_params(effective_effects)
    let mut all: List<Str> = []
    all.extend(param_names)
    all.extend(dict_params)
    all.extend(ev_params)
    let all_str = all.join(", ")
    emit(ctx, "function ${fn_name}(${all_str}) {")
    push_indent(ctx)
    let saved_fn_effects = ctx.current_fn_effects
    ctx.current_fn_effects = some(effective_effects)
    emit_block_body(ctx, body)
    ctx.current_fn_effects = saved_fn_effects
    pop_indent(ctx)
    emit(ctx, "}")
}

// ============================================================
// Extern fn declarations
// ============================================================

fn emit_extern_fn_decl(mut ctx: CodegenCtx, name: Str) {
    match ctx.module_prefix {
        some(prefix) => {
            let qualified = "${prefix}$${safe_ident(name)}"
            let sn = safe_ident(name)
            emit(ctx, "const ${qualified} = ${sn};")
        },
        none => {},
    }
}

// ============================================================
// Const declarations
// ============================================================

fn emit_const_decl(mut ctx: CodegenCtx, name: Str, init: HExpr) {
    let sn = qualify(ctx, name)
    let init_js = gen_expr(ctx, init)
    emit(ctx, "const ${sn} = ${init_js};")
}

// ============================================================
// Struct declarations
// ============================================================

fn emit_struct_decl(mut ctx: CodegenCtx, name: Str, fields: List<HStructField>) {
    let mut raw_fields: List<Str> = []
    let mut safe_fields: List<Str> = []
    for f in fields {
        raw_fields.push(f.name)
        safe_fields.push(safe_ident(f.name))
    }
    let qname = qualify(ctx, name)
    let params = safe_fields.join(", ")
    emit(ctx, "class ${qname} {")
    push_indent(ctx)
    emit(ctx, "constructor(${params}) {")
    push_indent(ctx)
    for i in 0..raw_fields.len() {
        match (raw_fields.get(i), safe_fields.get(i)) {
            (some(raw), some(safe)) => emit(ctx, "this.${raw} = ${safe};"),
            _ => {},
        }
    }
    pop_indent(ctx)
    emit(ctx, "}")
    pop_indent(ctx)
    emit(ctx, "}")
}

// ============================================================
// Enum declarations
// ============================================================

fn emit_enum_decl(mut ctx: CodegenCtx, name: Str, variants: List<HEnumVariant>) {
    let tag = ENUM_TAG_FIELD
    for v in variants {
        let js_name = "${qualify(ctx, name)}_${v.name}"
        if v.fields.len() == 0 {
            emit(ctx, "const ${js_name} = Object.freeze({ ${tag}: \"${v.name}\" });")
        } else {
            match v.field_names {
                some(fnames) => {
                    let mut sparams: List<Str> = []
                    for n in fnames { sparams.push(safe_ident(n)) }
                    let params_str = sparams.join(", ")
                    emit(ctx, "function ${js_name}(${params_str}) {")
                    push_indent(ctx)
                    emit(ctx, "return { ${tag}: \"${v.name}\", ${params_str} };")
                    pop_indent(ctx)
                    emit(ctx, "}")
                },
                none => {
                    let mut sparams: List<Str> = []
                    for i in 0..v.fields.len() { sparams.push("_${i}") }
                    let params_str = sparams.join(", ")
                    emit(ctx, "function ${js_name}(${params_str}) {")
                    push_indent(ctx)
                    emit(ctx, "return { ${tag}: \"${v.name}\", ${params_str} };")
                    pop_indent(ctx)
                    emit(ctx, "}")
                },
            }
        }
    }
}

// ============================================================
// Impl declarations
// ============================================================

fn emit_impl_decl(mut ctx: CodegenCtx, target_type: Str, trait_name: Str?, methods: List<HDecl>) {
    let prefix = match trait_name {
        some(tn) => trait_dict_name(qualify(ctx, target_type), safe_ident(tn)),
        none => qualify(ctx, target_type),
    }
    for method in methods {
        match method {
            HDecl::ExternFn { .. } => {},
            HDecl::Fn { name, params, effects, body, trait_bounds, .. } =>
                emit_fn_decl(ctx, name, params, effects, body, trait_bounds, some(prefix)),
            _ => {},
        }
    }
    match trait_name {
        some(tn) => emit_trait_dictionary(ctx, target_type, tn, methods),
        none => {},
    }
}

fn emit_trait_dictionary(mut ctx: CodegenCtx, target_type: Str, trait_name: Str, methods: List<HDecl>) {
    let qt = qualify(ctx, target_type)
    let dict_name = trait_dict_name(qt, trait_name)
    let mut impl_method_names = set_new()
    for m in methods {
        match m {
            HDecl::Fn { name, .. } => { impl_method_names.insert(name) },
            _ => {},
        }
    }

    let mut entries: List<Str> = []
    for m in methods {
        match m {
            HDecl::Fn { name, .. } => {
                let smn = safe_ident(name)
                let fn_name = "${dict_name}_${smn}"
                entries.push("${smn}: ${fn_name}")
            },
            _ => {},
        }
    }

    match ctx.trait_decls.get(trait_name) {
        some(trait_decl) => {
            // Collect all transitive supertraits for passing dicts to default methods
            let all_supers = collect_all_supertraits_codegen(ctx, trait_name)

            for tm in trait_decl.methods {
                if tm.has_default {
                    if impl_method_names.contains(tm.name) == false {
                        let stn = safe_ident(trait_name)
                        let smn = safe_ident(tm.name)
                        let default_fn = "__${stn}_${smn}"
                        let mut param_names: List<Str> = []
                        for p in tm.params { param_names.push(safe_ident(p.name)) }
                        let params_str = param_names.join(", ")
                        let mut call_args: List<Str> = []
                        call_args.push(dict_name)
                        // Pass supertrait dicts for the concrete type
                        for st in all_supers {
                            call_args.push(trait_dict_name(qt, safe_ident(st)))
                        }
                        call_args.extend(param_names)
                        let call_str = call_args.join(", ")
                        entries.push("${smn}: function(${params_str}) { return ${default_fn}(${call_str}); }")
                    }
                }
            }
        },
        none => {},
    }

    let entries_str = entries.join(", ")
    emit(ctx, "const ${dict_name} = { ${entries_str} };")
}

// ============================================================
// Trait declarations
// ============================================================

// Collect all transitive supertraits from ctx.trait_decls.
// For example, if Top: Mid and Mid: Base, returns ["Mid", "Base"] for "Top".
fn collect_all_supertraits_codegen(ctx: CodegenCtx, trait_name: Str) -> List<Str> {
    let mut result: List<Str> = []
    let mut visited: Set<Str> = set_new()
    let mut stack: List<Str> = []
    match ctx.trait_decls.get(trait_name) {
        some(tinfo) => {
            for st in tinfo.supertraits { stack.push(st) }
        },
        none => {}
    }
    while stack.len() > 0 {
        let current = stack.pop().unwrap()
        if visited.contains(current) { continue }
        visited.insert(current)
        result.push(current)
        match ctx.trait_decls.get(current) {
            some(parent_info) => {
                for parent_st in parent_info.supertraits {
                    stack.push(parent_st)
                }
            },
            none => {}
        }
    }
    result
}

fn emit_trait_decl(mut ctx: CodegenCtx, name: Str, methods: List<HTraitMethod>, supertraits: List<Str>) {
    // Collect all transitive supertraits for default method parameters
    let all_supers = collect_all_supertraits_codegen(ctx, name)

    for method in methods {
        match method.body {
            some(body) => {
                if method.has_default {
                    let sn = safe_ident(name)
                    let smn = safe_ident(method.name)
                    let fn_name = "__${sn}_${smn}"
                    let mut param_names: List<Str> = []
                    for p in method.params { param_names.push(safe_ident(p.name)) }
                    let self_name = default_method_self_name(safe_ident(name))
                    let mut all: List<Str> = []
                    all.push(self_name)
                    // Add supertrait dict params so body can reference them
                    for st in all_supers {
                        all.push(default_method_self_name(safe_ident(st)))
                    }
                    all.extend(param_names)
                    let all_str = all.join(", ")
                    emit(ctx, "function ${fn_name}(${all_str}) {")
                    push_indent(ctx)
                    emit_block_body(ctx, body)
                    pop_indent(ctx)
                    emit(ctx, "}")
                }
            },
            none => {},
        }
    }
}

// ============================================================
// Test declarations
// ============================================================

fn emit_test_decl(mut ctx: CodegenCtx, description: Str, body: HExpr) {
    emit(ctx, "// test: ${description}")
    emit(ctx, "(function() {")
    push_indent(ctx)
    emit_block_body(ctx, body)
    pop_indent(ctx)
    emit(ctx, "})();")
}

// ============================================================
// Effect declaration codegen (default evidence)
// ============================================================

fn emit_effect_decl(mut ctx: CodegenCtx, name: Str, ops: List<HEffectOp>) {
    // Always register effect ops so gen_handle can merge default bodies
    ctx.effect_ops.insert(name, ops)

    // Only emit a default evidence constant if all ops have default bodies
    let mut all_have_defaults = true
    for op in ops {
        if !op.has_default { all_have_defaults = false }
    }
    if !all_have_defaults { return }
    if ops.len() == 0 { return }

    // Collect effects used by default bodies (excluding io which is always global)
    let mut body_effect_names: List<Str> = []
    let mut body_effect_set: Set<Str> = set_new()
    for op in ops {
        match op.default_body {
            some(body) => {
                let body_effs = hexpr_effects(body)
                let eff_names = extract_effect_names(body_effs)
                for en in eff_names {
                    if en != "io" && en != name && !body_effect_set.contains(en) {
                        body_effect_set.insert(en)
                        body_effect_names.push(en)
                    }
                }
            },
            none => {},
        }
    }
    body_effect_names.sort()
    let body_ev_params = body_effect_names.map(fn(n) { evidence_param_name(n) })

    let def_ev_name = default_evidence_name(name)
    if body_ev_params.len() > 0 {
        // Factory function: accepts evidence params, returns evidence object (#89)
        // Uses sequential assignment inside factory to avoid TDZ (#80)
        let ev_params_str = body_ev_params.join(", ")
        emit(ctx, "function ${def_ev_name}(${ev_params_str}) {")
        push_indent(ctx)
        emit(ctx, "let __ev = {};")
        for op in ops {
            match op.default_body {
                some(body) => {
                    let mut params: List<Str> = []
                    for p in op.params { params.push(safe_ident(p.name)) }
                    let params_str = params.join(", ")
                    let b = gen_expr(ctx, body)
                    emit(ctx, "__ev.${safe_ident(op.name)} = (${params_str}) => (${b});")
                },
                none => {}
            }
        }
        emit(ctx, "return __ev;")
        pop_indent(ctx)
        emit(ctx, "}")
        ctx.default_evidence_params.insert(name, body_ev_params)
    } else {
        // No non-io effects: sequential assignment at module level (#80)
        emit(ctx, "let ${def_ev_name} = {};")
        for op in ops {
            match op.default_body {
                some(body) => {
                    let mut params: List<Str> = []
                    for p in op.params { params.push(safe_ident(p.name)) }
                    let params_str = params.join(", ")
                    let b = gen_expr(ctx, body)
                    emit(ctx, "${def_ev_name}.${safe_ident(op.name)} = (${params_str}) => (${b});")
                },
                none => {}
            }
        }
    }
    ctx.default_evidence_effects.insert(name)
}

// ============================================================
// Top-level evidence emission (for main() auto-call)
// ============================================================

pub fn emit_toplevel_evidence(mut ctx: CodegenCtx, effects: EffectRow) {
    let effect_names = extract_effect_names(effects)

    // Pass 1: emit evidence for non-default effects (io/fail/empty)
    let mut emitted: Set<Str> = set_new()
    let mut deferred_defaults: List<Str> = []
    for name in effect_names {
        let ev_name = evidence_param_name(name)
        if name == "io" {
            emitted.insert(name)
        } else {
            if name == "fail" {
                emit(ctx, "const ${ev_name} = { raise: (error) => { throw error; } };")
                emitted.insert(name)
            } else {
                if ctx.default_evidence_effects.contains(name) {
                    deferred_defaults.push(name)
                } else {
                    emit(ctx, "const ${ev_name} = {};")
                    emitted.insert(name)
                }
            }
        }
    }

    // Pass 2: topologically sort deferred_defaults so dependencies are emitted first.
    // Build dependency graph from default_evidence_params: if effect A's factory
    // takes __ring_ev_B, then A depends on B (B must be emitted before A).
    let sorted_defaults = topo_sort_defaults(ctx, deferred_defaults)

    // Pass 3: emit evidence for default-evidence effects in topological order
    for name in sorted_defaults {
        let ev_name = evidence_param_name(name)
        let def_ev = default_evidence_name(name)
        match ctx.default_evidence_params.get(name) {
            some(factory_params) => {
                // Emit any dependencies that haven't been emitted yet.
                // Dependencies may themselves be default-evidence effects (needs recursive resolution).
                for dp in factory_params {
                    let dep_name = dp.slice(10, dp.len())
                    if !emitted.contains(dep_name) {
                        emit_single_evidence(ctx, dep_name, emitted)
                    }
                }
                let args = factory_params.join(", ")
                emit(ctx, "const ${ev_name} = ${def_ev}(${args});")
            },
            none => {
                emit(ctx, "const ${ev_name} = ${def_ev};")
            },
        }
        emitted.insert(name)
    }
}

// Emit evidence for a single effect, recursively resolving default-evidence dependencies.
fn emit_single_evidence(mut ctx: CodegenCtx, name: Str, mut emitted: Set<Str>) {
    if emitted.contains(name) { return }
    let ev_name = evidence_param_name(name)
    if name == "io" {
        // io evidence is a global ambient — no const needed
        emitted.insert(name)
        return
    }
    if name == "fail" {
        emit(ctx, "const ${ev_name} = { raise: (error) => { throw error; } };")
        emitted.insert(name)
        return
    }
    if ctx.default_evidence_effects.contains(name) {
        let def_ev = default_evidence_name(name)
        match ctx.default_evidence_params.get(name) {
            some(factory_params) => {
                // This default effect has dependencies — recursively emit them first
                for dp in factory_params {
                    let dep_name = dp.slice(10, dp.len())
                    if !emitted.contains(dep_name) {
                        emit_single_evidence(ctx, dep_name, emitted)
                    }
                }
                let args = factory_params.join(", ")
                emit(ctx, "const ${ev_name} = ${def_ev}(${args});")
            },
            none => {
                emit(ctx, "const ${ev_name} = ${def_ev};")
            }
        }
    } else {
        emit(ctx, "const ${ev_name} = {};")
    }
    emitted.insert(name)
}

// Topological sort for default evidence emission order.
// Ensures that if effect A depends on effect B (both with all-default handlers),
// B is emitted before A so that B's evidence is available when A's factory is called.
fn topo_sort_defaults(ctx: CodegenCtx, defaults: List<Str>) -> List<Str> {
    let mut default_set: Set<Str> = set_new()
    for d in defaults { default_set.insert(d) }

    // Build adjacency: deps[A] = [B, C] means A depends on B and C
    let mut deps: Map<Str, List<Str>> = map_new()
    for name in defaults {
        let mut my_deps: List<Str> = []
        match ctx.default_evidence_params.get(name) {
            some(factory_params) => {
                for dp in factory_params {
                    let dep_name = dp.slice(10, dp.len())
                    if default_set.contains(dep_name) {
                        my_deps.push(dep_name)
                    }
                }
            },
            none => {}
        }
        deps.insert(name, my_deps)
    }

    // Kahn's algorithm: build reverse edges and in-degree map.
    // rev_deps[B] = [A, C] means A and C depend on B.
    // in_deg[A] = number of dependencies A has (must be emitted before A).
    let mut rev_deps: Map<Str, List<Str>> = map_new()
    let mut in_deg: Map<Str, Int> = map_new()
    for name in defaults {
        in_deg.insert(name, 0)
        rev_deps.insert(name, { let mut l: List<Str> = []; l })
    }
    for entry in deps.entries() {
        let (name, dep_list) = entry
        in_deg.insert(name, dep_list.len())
        for dep in dep_list {
            match rev_deps.get(dep) {
                some(rev_list) => { rev_list.push(name) },
                none => {
                    let mut new_list: List<Str> = []
                    new_list.push(name)
                    rev_deps.insert(dep, new_list)
                }
            }
        }
    }

    // Start with effects that have no dependencies (in_deg == 0)
    let mut queue: List<Str> = []
    for entry in in_deg.entries() {
        let (name, deg) = entry
        if deg == 0 { queue.push(name) }
    }
    queue.sort()  // deterministic order

    let mut sorted: List<Str> = []
    while queue.len() > 0 {
        let cur = queue.shift().unwrap()
        sorted.push(cur)
        match rev_deps.get(cur) {
            some(dependents) => {
                for dependent in dependents {
                    let old_deg = match in_deg.get(dependent) { some(v) => v, none => 0 }
                    in_deg.insert(dependent, old_deg - 1)
                    if old_deg - 1 == 0 {
                        queue.push(dependent)
                        queue.sort()  // maintain deterministic order
                    }
                }
            },
            none => {}
        }
    }

    // If sorted.len() < defaults.len(), there's a cycle (already caught by checker).
    // Append remaining in original order as fallback.
    if sorted.len() < defaults.len() {
        for name in defaults {
            if !sorted.contains(name) {
                sorted.push(name)
            }
        }
    }

    sorted
}
