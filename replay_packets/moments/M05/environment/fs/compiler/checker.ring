use types::{Type, UNIT}
use ast::{Program, Decl, UseDecl, UseImport, NamedImport, Span, TypeParam}
use hir::{HDecl, HProgram}
use diagnostics::{Severity, DiagnosticContext, CollectingSink, Diagnostic, new_collecting_sink, make_diag}
use env::{TypeEnv, TypeScheme, StructDef, EnumDef, EffectDef, TraitDef, ImplEntry, new_type_env, add_impl}
use builtins::{register_builtins, register_hof_intrinsics}
use infer_decl::{check as infer_check, check_prelude_decl}
use infer_ctx::{InferCtx}
use infer_register::{register_decl_public}
use exports::{ModuleExports, TypeDef}
use codes::{E0702, E0703, E0705}
use parser::{parse}
use union_find::{UnionFind}
use unify::{empty_subst}

pub struct CheckResult {
    pub program: HProgram,
    pub env: TypeEnv,
    pub fn_mut_params: Map<Str, List<Bool>>
}

const STD_FILES: List<Str> =
    ["io.ring", "iterator.ring", "list.ring", "map.ring", "set.ring", "str.ring", "num.ring", "result.ring", "fs.ring", "path.ring", "process.ring"]

fn find_std_dir() -> Str? {
    let candidates = [
        path_resolve(path_join(path_dirname(path_resolve(".")), "std")),
        path_resolve("std")
    ]
    for dir in candidates {
        if file_exists(dir) { return some(dir) }
    }
    none
}

fn load_prelude(mut ctx: InferCtx) -> List<HDecl> {
    let mut prelude_hdecls: List<HDecl> = []
    match find_std_dir() {
        some(std_dir) => {
            // Phase 1: collect and register all prelude declarations
            let mut all_prelude_decls: List<Decl> = []
            for file in (STD_FILES) {
                let file_path = path_join(std_dir, file)
                if file_exists(file_path) {
                    let source = read_file(file_path)
                    let prelude_sink = new_collecting_sink()
                    let ast = parse(source, file_path, prelude_sink)
                    for decl in ast.decls {
                        register_decl_public(ctx, decl)
                        all_prelude_decls.push(decl)
                    }
                }
            }
            // Phase 2: compile struct/enum/trait declarations, non-extern impl methods, and top-level functions
            for decl in all_prelude_decls {
                match decl {
                    Decl::Struct { .. } => {
                        let result = some(check_prelude_decl(ctx, decl)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::Enum { .. } => {
                        let result = some(check_prelude_decl(ctx, decl)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::Trait { .. } => {
                        let result = some(check_prelude_decl(ctx, decl)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    Decl::Impl { target_type, type_params, trait_name, methods, span } => {
                        // Filter to only Fn methods — ExternFn methods are already handled
                        // by the runtime and cannot be looked up via check_extern_fn_decl
                        // because they're registered in impl_methods_map, not the main scope.
                        let mut fn_methods: List<Decl> = []
                        for m in methods {
                            match m { Decl::Fn { .. } => { fn_methods.push(m) }, _ => {} }
                        }
                        if fn_methods.len() > 0 {
                            let filtered_decl = Decl::Impl {
                                target_type: target_type,
                                type_params: type_params,
                                trait_name: trait_name,
                                methods: fn_methods,
                                span: span
                            }
                            let result = some(check_prelude_decl(ctx, filtered_decl)) catch { _ => none }
                            match result {
                                some(hd) => { prelude_hdecls.push(hd) },
                                none => {}
                            }
                        }
                    },
                    Decl::Fn { .. } => {
                        let result = some(check_prelude_decl(ctx, decl)) catch { _ => none }
                        match result {
                            some(hd) => { prelude_hdecls.push(hd) },
                            none => {}
                        }
                    },
                    _ => {}
                }
            }
        },
        none => {},
    }
    prelude_hdecls
}

fn new_infer_ctx(sink: CollectingSink) -> InferCtx {
    let mut env = new_type_env()
    register_builtins(env)
    register_hof_intrinsics(env)

    InferCtx {
        env: env,
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

pub fn check(program: Program, sink: CollectingSink) -> CheckResult {
    let mut ctx = new_infer_ctx(sink)
    let prelude_hdecls = load_prelude(ctx)
    let hprogram = infer_check(ctx, program)
    // Prepend prelude hdecls to the program's decls
    let mut all_decls = list_clone(prelude_hdecls)
    for d in hprogram.decls { all_decls.push(d) }
    CheckResult {
        program: HProgram { decls: all_decls, derived_impls: hprogram.derived_impls, boxed_vars: hprogram.boxed_vars },
        env: ctx.env,
        fn_mut_params: ctx.fn_mut_params
    }
}

pub fn check_module(program: Program, module_exports: List<ModuleExports>, sink: CollectingSink) -> CheckResult {
    let mut ctx = new_infer_ctx(sink)
    let prelude_hdecls = load_prelude(ctx)
    inject_module_exports(ctx, module_exports)
    resolve_uses(ctx, program.uses, module_exports)
    let hprogram = infer_check(ctx, program)
    // Prepend prelude hdecls to the program's decls
    let mut all_decls = list_clone(prelude_hdecls)
    for d in hprogram.decls { all_decls.push(d) }
    CheckResult {
        program: HProgram { decls: all_decls, derived_impls: hprogram.derived_impls, boxed_vars: hprogram.boxed_vars },
        env: ctx.env,
        fn_mut_params: ctx.fn_mut_params
    }
}

fn inject_module_exports(mut ctx: InferCtx, exports: List<ModuleExports>) {
    for mod_ in exports {
        for entry in mod_.types.entries() {
            let (name, def) = entry
            match def {
                TypeDef::StructDef_(sdef) => {
                    ctx.env.types.structs.insert(name, sdef)
                },
                TypeDef::EnumDef_(edef) => {
                    ctx.env.types.enums.insert(name, edef)
                    for v in edef.variants {
                        ctx.env.types.variant_to_enum.insert(v.name, name)
                    }
                },
            }
        }
        for entry in mod_.effects.entries() {
            let (name, effdef) = entry
            ctx.env.types.effects.insert(name, effdef)
        }
        for entry in mod_.effect_aliases.entries() {
            let (name, adef) = entry
            ctx.env.types.effect_aliases.insert(name, adef)
        }
        for entry in mod_.traits.entries() {
            let (name, tdef) = entry
            ctx.env.trait_reg.traits.insert(name, tdef)
        }
        for impl_ in mod_.trait_impls {
            add_impl(ctx.env.trait_reg, impl_)
        }
        for entry in mod_.impl_methods.entries() {
            let (type_name, methods) = entry
            match ctx.env.trait_reg.impl_methods.get(type_name) {
                some(existing) => {
                    for mentry in methods.entries() {
                        let (method_name, scheme) = mentry
                        existing.insert(method_name, scheme)
                    }
                },
                none => {
                    ctx.env.trait_reg.impl_methods.insert(type_name, map_clone(methods))
                },
            }
        }
        // Inject mut_methods
        for entry in mod_.mut_methods.entries() {
            let (type_name, method_set) = entry
            match ctx.env.trait_reg.mut_methods.get(type_name) {
                some(existing) => {
                    for m in method_set.to_list() {
                        existing.insert(m)
                    }
                },
                none => {
                    let mut new_set: Set<Str> = set_new()
                    for m in method_set.to_list() {
                        new_set.insert(m)
                    }
                    ctx.env.trait_reg.mut_methods.insert(type_name, new_set)
                },
            }
        }
        // Inject fn_mut_params
        for entry in mod_.fn_mut_params.entries() {
            let (fn_name, flags) = entry
            ctx.fn_mut_params.insert(fn_name, flags)
        }
    }
}

fn resolve_uses(mut ctx: InferCtx, uses: List<UseDecl>, available_modules: List<ModuleExports>) {
    let mut module_map: Map<Str, ModuleExports> = map_new()
    for mod_ in available_modules {
        module_map.insert(mod_.module_key, mod_)
    }

    for use_decl in uses {
        // Reject relative paths (self::/super::) at file level
        let first_seg = use_decl.path.segments.get(0).unwrap_or("")
        if first_seg == "self" || first_seg == "super" {
            let d = make_diag(
                E0705, Severity::SevError,
                "Cannot use '${first_seg}::' at file level — relative paths are only supported inside mod blocks",
                use_decl.path.span,
                DiagnosticContext::OtherContext { detail: some("relative path out of scope") }
            )
            ctx.sink.report(d)
            continue
        }

        let mod_key = use_decl.path.segments.join("::")
        match module_map.get(mod_key) {
            none => {
                let d = make_diag(
                    E0702, Severity::SevError,
                    "Module '${mod_key}' not found",
                    use_decl.path.span,
                    DiagnosticContext::OtherContext { detail: some("module not found") }
                )
                ctx.sink.report(d)
            },
            some(mod_) => {
                match use_decl.imports {
                    UseImport::NamedItems { names } => {
                        for item in names {
                            let local_name = match item.alias {
                                some(a) => a,
                                none => item.name,
                            }
                            let mut found = false

                            match mod_.values.get(item.name) {
                                some(scheme) => {
                                    ctx.env.bind(local_name, scheme)
                                    found = true
                                },
                                none => {},
                            }

                            match mod_.types.get(item.name) {
                                some(tdef) => {
                                    found = true
                                    match tdef {
                                        TypeDef::EnumDef_(edef) => {
                                            for v in edef.variants {
                                                match mod_.values.get(v.name) {
                                                    some(vscheme) => { ctx.env.bind(v.name, vscheme) },
                                                    none => {},
                                                }
                                            }
                                        },
                                        _ => {},
                                    }
                                },
                                none => {},
                            }

                            if mod_.effects.contains_key(item.name) { found = true }
                            if mod_.effect_aliases.contains_key(item.name) { found = true }
                            if mod_.traits.contains_key(item.name) { found = true }

                            if found == false {
                                let d = make_diag(
                                    E0703, Severity::SevError,
                                    "Symbol '${item.name}' not found in module '${mod_key}'",
                                    item.span,
                                    DiagnosticContext::OtherContext { detail: some("symbol not found") }
                                )
                                ctx.sink.report(d)
                            }
                        }
                    },
                    UseImport::Module => {
                        for entry in mod_.values.entries() {
                            let (name, scheme) = entry
                            ctx.env.bind(name, scheme)
                        }
                        for entry in mod_.types.entries() {
                            let (_, tdef) = entry
                            match tdef {
                                TypeDef::EnumDef_(edef) => {
                                    for v in edef.variants {
                                        match mod_.values.get(v.name) {
                                            some(vscheme) => { ctx.env.bind(v.name, vscheme) },
                                            none => {},
                                        }
                                    }
                                },
                                _ => {},
                            }
                        }
                    },
                }
            },
        }
    }
}
