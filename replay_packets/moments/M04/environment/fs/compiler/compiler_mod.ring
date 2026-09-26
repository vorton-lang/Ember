use types::{Type}
use ast::{Program, Decl, UseDecl, UseImport, NamedImport}
use infer_register::{prefix_decl_name}
use hir::{HProgram, HDecl, trait_dict_name}
use diagnostics::{CollectingSink, Diagnostic, new_collecting_sink}
use formatter::{format_human}
use env::{TypeEnv, add_impl}
use checker::{CheckResult, check as check_single, check_module}
use codegen::{generate}
use codegen_llvm::{generate_llvm, generate_llvm_project}
use codegen_ctx::{safe_ident}
use runtime::{RUNTIME_CODE, RUNTIME_EXPORT_NAMES, runtime_esm_code}
use resolver::{ModuleGraph, ModuleId, module_key, module_prefix,
    build_module_graph}
use exports::{ModuleExports, TypeDef, extract_exports}
use perceus::{perceus_transform, perceus_transform_mutated}
use verify_rc::{RcFinding, verify_rc_program, rc_fatal_count, format_rc_findings}

pub struct CompileProjectResult {
    pub js: Str,
    pub success: Bool
}

pub struct EsmCompileResult {
    pub success: Bool,
    pub entry_js_path: Str
}

// ============================================================
// Shared resolve → parse → check pipeline
// ============================================================

struct CompilePhaseResult {
    graph: ModuleGraph,
    module_asts: Map<Str, Program>,
    module_hirs: Map<Str, HProgram>,
    module_exports_map: Map<Str, ModuleExports>
}

fn compile_phases(entry_file: Str) -> CompilePhaseResult? {
    match build_module_graph(entry_file) {
        none => none,
        some(graph) => {
            let mut module_asts: Map<Str, Program> = map_new()
            let mut module_hirs: Map<Str, HProgram> = map_new()
            let mut module_exports_map: Map<Str, ModuleExports> = map_new()

            // Use cached ASTs from resolver (already parsed during graph construction)
            for key in graph.topo_order {
                match graph.asts.get(key) {
                    some(ast) => { module_asts.insert(key, ast) },
                    none => {},
                }
            }

            // Check all modules in topological order
            let mut check_ok = true
            for key in graph.topo_order {
                if check_ok {
                    match module_asts.get(key) {
                        some(ast) => {
                            let sink = new_collecting_sink()
                            let deps = match graph.dependencies.get(key) {
                                some(dk) => dk,
                                none => empty_str_list(),
                            }
                            let mut dep_exports: List<ModuleExports> = empty_module_exports_list()
                            for dk in deps {
                                match module_exports_map.get(dk) {
                                    some(e) => dep_exports.push(e),
                                    none => {},
                                }
                            }
                            let result = check_module(ast, dep_exports, sink)
                            if sink.has_errors() {
                                let src = read_file(match graph.modules.get(key) { some(m) => m.file_path, none => "" })
                                eprintln(format_human(sink.diagnostics(), src))
                                check_ok = false
                            } else {
                                // Surface check warnings (non-error diagnostics) without failing the build
                                if sink.items.len() > 0 {
                                    let src = read_file(match graph.modules.get(key) { some(m) => m.file_path, none => "" })
                                    eprintln(format_human(sink.diagnostics(), src))
                                }
                                module_hirs.insert(key, result.program)
                                match graph.modules.get(key) {
                                    some(mod_) => {
                                        let prefix = module_prefix(mod_.path_segments)
                                        let exp = extract_exports(key, prefix, ast, result.program, result.env, result.fn_mut_params)
                                        module_exports_map.insert(key, exp)
                                    },
                                    none => {},
                                }
                            }
                        },
                        none => { check_ok = false },
                    }
                }
            }
            if check_ok == false { return none }

            some(CompilePhaseResult {
                graph: graph,
                module_asts: module_asts,
                module_hirs: module_hirs,
                module_exports_map: module_exports_map
            })
        },
    }
}

// ============================================================
// Bundle mode
// ============================================================

pub fn compile_project(entry_file: Str) -> CompileProjectResult {
    match compile_phases(entry_file) {
        none => CompileProjectResult { js: "", success: false },
        some(phases) => {
            let entry_key = module_key(phases.graph.entry.path_segments)
            let mut js_parts: List<Str> = []
            let mut is_first = true

            for key in phases.graph.topo_order {
                match (phases.graph.modules.get(key), phases.module_hirs.get(key)) {
                    (some(mod_), some(hir)) => {
                        let prefix = module_prefix(mod_.path_segments)
                        let mut imports_map = build_imports_map(phases.graph, phases.module_exports_map, key)
                        let esf = build_external_struct_fields(phases.graph, phases.module_exports_map, key)
                        let eim = build_external_impl_methods(phases.graph, phases.module_exports_map, key)
                        let efmp = build_external_fn_mut_params(phases.graph, phases.module_exports_map, key)
                        let skip_preamble = is_first == false
                        let skip_main = key != entry_key
                        let module_js = generate(hir, skip_preamble, skip_main,
                            some(prefix), some(imports_map), some(esf), some(eim), none, none, some(efmp))
                        js_parts.push("// === module: ${key} ===")
                        js_parts.push(module_js)
                        js_parts.push("")
                        is_first = false
                    },
                    _ => {},
                }
            }

            CompileProjectResult {
                js: js_parts.join("\n"),
                success: true
            }
        },
    }
}

// ============================================================
// LLVM multi-file compilation mode
// All modules compiled into a single LLVM Module → single .o file
// ============================================================

pub struct LlvmCompileResult {
    pub success: Bool
}

pub fn compile_project_llvm(entry_file: Str, output_path: Str) -> LlvmCompileResult {
    match compile_phases(entry_file) {
        none => LlvmCompileResult { success: false },
        some(phases) => {
            let entry_key = module_key(phases.graph.entry.path_segments)

            // Build list of (module_prefix, HProgram, uses) in topo order
            let mut modules: List<(Str, HProgram, List<UseDecl>)> = []
            let mut entry_prefix = ""

            for key in phases.graph.topo_order {
                match (phases.graph.modules.get(key), phases.module_hirs.get(key), phases.module_asts.get(key)) {
                    (some(mod_), some(hir), some(ast)) => {
                        let prefix = module_prefix(mod_.path_segments)
                        let rc_hir = perceus_transform(hir)
                        modules.push((prefix, rc_hir, ast.uses))
                        if key == entry_key {
                            entry_prefix = prefix
                        }
                    },
                    (some(mod_), some(hir), none) => {
                        let prefix = module_prefix(mod_.path_segments)
                        let rc_hir = perceus_transform(hir)
                        modules.push((prefix, rc_hir, []))
                        if key == entry_key {
                            entry_prefix = prefix
                        }
                    },
                    _ => {},
                }
            }

            generate_llvm_project(modules, entry_prefix, output_path)
            LlvmCompileResult { success: true }
        },
    }
}

// ============================================================
// B-104 D2: multi-file static RC verification
// Runs the same per-module perceus_transform as compile_project_llvm, then
// the verify_rc linear check on each module's post-RC HIR.
// ============================================================

pub struct RcProjectVerifyResult {
    pub success: Bool,
    pub fatal: Int,
    pub exempt: Int,
    pub report: Str
}

pub fn verify_project_rc(entry_file: Str, mutate: Str, strict: Bool) -> RcProjectVerifyResult {
    match compile_phases(entry_file) {
        none => RcProjectVerifyResult { success: false, fatal: 0, exempt: 0, report: "" },
        some(phases) => {
            let mut all: List<RcFinding> = []
            for key in phases.graph.topo_order {
                match phases.module_hirs.get(key) {
                    some(hir) => {
                        let rc_hir = perceus_transform_mutated(hir, mutate)
                        for f in verify_rc_program(rc_hir) { all.push(f) }
                    },
                    none => {},
                }
            }
            let fatal = rc_fatal_count(all)
            RcProjectVerifyResult {
                success: true,
                fatal: fatal,
                exempt: all.len() - fatal,
                report: format_rc_findings(all, strict)
            }
        },
    }
}

// ============================================================
// ESM multi-file output mode
// ============================================================

pub fn compile_project_esm(entry_file: Str, out_dir: Str) -> EsmCompileResult {
    match compile_phases(entry_file) {
        none => EsmCompileResult { success: false, entry_js_path: "" },
        some(phases) => {
            let entry_key = module_key(phases.graph.entry.path_segments)
            // Write runtime
            let runtime_path = path_join(out_dir, "__ring_runtime.js")
            write_file(runtime_path, runtime_esm_code())

            let mut entry_js_path = ""

            for key in phases.graph.topo_order {
                match (phases.graph.modules.get(key), phases.module_hirs.get(key), phases.module_asts.get(key)) {
                    (some(mod_), some(hir), some(ast)) => {
                        let mod_relative = mod_.file_path.replace(".ring", ".js")
                        let mod_out_path = path_join(out_dir, path_basename(mod_relative))

                        // Build cross-module metadata
                        let mut imports_map = build_imports_map(phases.graph, phases.module_exports_map, key)
                        let esf = build_external_struct_fields(phases.graph, phases.module_exports_map, key)
                        let eim = build_external_impl_methods(phases.graph, phases.module_exports_map, key)
                        let efmp = build_external_fn_mut_params(phases.graph, phases.module_exports_map, key)

                        // Build import lines (runtime + cross-module)
                        let mut import_lines = build_esm_import_lines(phases.graph, phases.module_exports_map, key)

                        // Register use-alias entries into imports_map
                        register_use_aliases(ast, imports_map)

                        // Resolve cross-module extern fn imports
                        resolve_extern_fn_imports(ast, key, phases.graph, phases.module_exports_map, imports_map, import_lines)

                        // Build export names
                        let mut export_names = build_esm_export_names(ast, hir)

                        // Build pub use re-export aliases
                        let reexport_aliases = build_pub_use_reexports(ast, phases.module_exports_map, export_names)
                        for ra in reexport_aliases {
                            import_lines.push(ra)
                        }

                        let skip_main = key != entry_key
                        let module_js = generate(hir, true, skip_main,
                            none, some(imports_map), some(esf), some(eim),
                            some(import_lines), some(export_names), some(efmp))
                        write_file(mod_out_path, module_js)

                        if key == entry_key { entry_js_path = mod_out_path }
                    },
                    _ => {},
                }
            }

            EsmCompileResult {
                success: true,
                entry_js_path: entry_js_path
            }
        },
    }
}

// ============================================================
// ESM helper: build import lines (runtime + cross-module)
// ============================================================

fn build_esm_import_lines(graph: ModuleGraph, exports_map: Map<Str, ModuleExports>, key: Str) -> List<Str> {
    let mut import_lines: List<Str> = []

    // Runtime import
    let runtime_names = RUNTIME_EXPORT_NAMES
    let rnames_joined = runtime_names.join(", ")
    import_lines.push("import { ${rnames_joined} } from \"./__ring_runtime.js\";")

    // Cross-module import lines
    let deps = match graph.dependencies.get(key) { some(d) => d, none => empty_str_list() }
    for dk in deps {
        match (exports_map.get(dk), graph.modules.get(dk)) {
            (some(dep_exports), some(dep_mod)) => {
                let dep_prefix = dep_exports.module_prefix
                let dep_js = path_basename(dep_mod.file_path.replace(".ring", ".js"))
                let import_pairs = build_dep_import_pairs(dep_exports, dep_prefix)

                if import_pairs.len() > 0 {
                    let joined = import_pairs.join(", ")
                    import_lines.push("import { ${joined} } from \"./${dep_js}\";")
                }
            },
            _ => {},
        }
    }

    import_lines
}

// Build import pairs for a single dependency module
fn build_dep_import_pairs(dep_exports: ModuleExports, dep_prefix: Str) -> List<Str> {
    let mut import_pairs: List<Str> = []

    // Collect bare variant names (no JS declaration)
    let mut bare_variants: Set<Str> = set_new()
    for tentry in dep_exports.types.entries() {
        let (_, tdef) = tentry
        match tdef {
            TypeDef::EnumDef_(edef) => {
                for v in edef.variants { bare_variants.insert(v.name) }
            },
            _ => {},
        }
    }

    // Import values
    for ventry in dep_exports.values.entries() {
        let (name, _) = ventry
        if !dep_exports.extern_values.contains(name) && !bare_variants.contains(name) {
            let si = safe_ident(name)
            let alias = "${dep_prefix}$${si}"
            import_pairs.push("${si} as ${alias}")
        }
    }

    // Import types (struct constructors, enum variant constructors)
    for tentry in dep_exports.types.entries() {
        let (name, tdef) = tentry
        let si = safe_ident(name)
        match tdef {
            TypeDef::EnumDef_(edef) => {
                for v in edef.variants {
                    let valias = "${dep_prefix}$${si}_${v.name}"
                    import_pairs.push("${si}_${v.name} as ${valias}")
                }
            },
            TypeDef::StructDef_(_) => {
                let alias = "${dep_prefix}$${si}"
                import_pairs.push("${si} as ${alias}")
            },
        }
    }

    // Import trait dict names
    for impl_ in dep_exports.trait_impls {
        let dict_js = trait_dict_name(safe_ident(impl_.target_type_name), safe_ident(impl_.trait_name))
        let alias = "${dep_prefix}$${dict_js}"
        import_pairs.push("${dict_js} as ${alias}")
    }

    // Import inherent method names
    for ientry in dep_exports.inherent_methods.entries() {
        let (type_name, method_names) = ientry
        for mname in method_names {
            let method_js = "${safe_ident(type_name)}_${mname}"
            let alias = "${dep_prefix}$${method_js}"
            import_pairs.push("${method_js} as ${alias}")
        }
    }

    import_pairs
}

// ============================================================
// ESM helper: register use-alias entries into imports_map
// ============================================================

fn register_use_aliases(ast: Program, mut imports_map: Map<Str, Str>) {
    for use_decl in ast.uses {
        match use_decl.imports {
            UseImport::NamedItems { names } => {
                for item in names {
                    match item.alias {
                        some(alias) => {
                            match imports_map.get(item.name) {
                                some(existing) => { imports_map.insert(alias, existing) },
                                none => {},
                            }
                        },
                        none => {},
                    }
                }
            },
            _ => {},
        }
    }
}

// ============================================================
// ESM helper: resolve cross-module extern fn imports
// ============================================================

fn resolve_extern_fn_imports(ast: Program, key: Str, graph: ModuleGraph,
    exports_map: Map<Str, ModuleExports>, mut imports_map: Map<Str, Str>,
    mut import_lines: List<Str>) {
    for decl in ast.decls {
        match decl {
            Decl::ExternFn { name, .. } => {
                if !imports_map.contains_key(name) {
                    for eentry in exports_map.entries() {
                        let (other_key, other_exports) = eentry
                        if other_key != key && other_exports.values.contains_key(name) && !other_exports.extern_values.contains(name) {
                            match graph.modules.get(other_key) {
                                some(other_mod) => {
                                    let other_js = path_basename(other_mod.file_path.replace(".ring", ".js"))
                                    let other_prefix = other_exports.module_prefix
                                    let si = safe_ident(name)
                                    let alias = "${other_prefix}$${si}"
                                    imports_map.insert(name, alias)
                                    import_lines.push("import { ${si} as ${alias} } from \"./${other_js}\";")
                                },
                                none => {},
                            }
                        }
                    }
                }
            },
            _ => {},
        }
    }
}

// ============================================================
// ESM helper: build export names from declarations
// ============================================================

fn build_esm_export_names(ast: Program, hir: HProgram) -> List<Str> {
    let mut export_names: List<Str> = []

    // Pass 1: pub fn/struct/enum/const declarations
    for decl in ast.decls {
        collect_pub_decl_exports(decl, export_names)
    }

    // Pass 2: impl-related exports for pub types
    for decl in ast.decls {
        collect_impl_exports(decl, ast.decls, export_names)
    }

    // Pass 3: auto-derive dict exports
    for di in hir.derived_impls {
        if is_pub_type_in_decls(di.type_name, ast.decls) {
            export_names.push(trait_dict_name(safe_ident(di.type_name), safe_ident(di.trait_name)))
        }
    }

    export_names
}

// Check whether a type name is declared as pub in the given decl list
fn is_pub_type_in_decls(type_name: Str, decls: List<Decl>) -> Bool {
    let mut result = false
    for d in decls {
        match d {
            Decl::Struct { name: dn, is_pub: dp, .. } => { if dn == type_name && dp { result = true } },
            Decl::Enum { name: dn, is_pub: dp, .. } => { if dn == type_name && dp { result = true } },
            Decl::ModBlock { name: mod_name, decls: mod_decls, is_pub: mpub, .. } => {
                if mpub {
                    for sd in mod_decls {
                        let prefixed = prefix_decl_name(mod_name, sd)
                        match prefixed {
                            Decl::Struct { name: sn, is_pub: sp, .. } => { if sn == type_name && sp { result = true } },
                            Decl::Enum { name: en, is_pub: ep, .. } => { if en == type_name && ep { result = true } },
                            _ => {},
                        }
                    }
                }
            },
            _ => {},
        }
    }
    result
}

// Collect export names from a single pub declaration (including nested mod blocks)
fn collect_pub_decl_exports(decl: Decl, mut export_names: List<Str>) {
    match decl {
        Decl::Fn { name, is_pub, .. } => { if is_pub { export_names.push(safe_ident(name)) } },
        Decl::Struct { name, is_pub, .. } => { if is_pub { export_names.push(safe_ident(name)) } },
        Decl::Enum { name, is_pub, variants, .. } => {
            if is_pub {
                for v in variants {
                    let sn = safe_ident(name)
                    export_names.push("${sn}_${v.name}")
                }
            }
        },
        Decl::Const { name, is_pub, .. } => { if is_pub { export_names.push(safe_ident(name)) } },
        Decl::ExternType { name, is_pub, .. } => { if is_pub { export_names.push(safe_ident(name)) } },
        Decl::ModBlock { name: mod_name, decls: mod_decls, is_pub: mpub, .. } => {
            if mpub {
                for subdecl in mod_decls {
                    let prefixed = prefix_decl_name(mod_name, subdecl)
                    collect_pub_decl_exports(prefixed, export_names)
                }
            }
        },
        _ => {},
    }
}

// Collect export names for impl declarations (including inside mod blocks)
fn collect_impl_exports(decl: Decl, all_decls: List<Decl>, mut export_names: List<Str>) {
    match decl {
        Decl::Impl { target_type, trait_name: impl_trait, methods, .. } => {
            if is_pub_type_in_decls(target_type, all_decls) {
                match impl_trait {
                    some(tn) => {
                        export_names.push(trait_dict_name(safe_ident(target_type), safe_ident(tn)))
                    },
                    none => {
                        for m in methods {
                            match m {
                                Decl::Fn { name: mn, .. } => export_names.push("${safe_ident(target_type)}_${mn}"),
                                _ => {},
                            }
                        }
                    },
                }
            }
        },
        Decl::ModBlock { name: mod_name, decls: mod_decls, is_pub: mpub, .. } => {
            if mpub {
                for subdecl in mod_decls {
                    let prefixed = prefix_decl_name(mod_name, subdecl)
                    collect_impl_exports(prefixed, all_decls, export_names)
                }
            }
        },
        _ => {},
    }
}

// ============================================================
// ESM helper: build pub use re-export aliases
// ============================================================

fn build_pub_use_reexports(ast: Program, exports_map: Map<Str, ModuleExports>,
    mut export_names: List<Str>) -> List<Str> {
    let mut reexport_aliases: List<Str> = []
    for use_decl in ast.uses {
        if use_decl.is_pub {
            let src_key = use_decl.path.segments.join("::")
            match exports_map.get(src_key) {
                some(src_exports) => {
                    let src_prefix = src_exports.module_prefix
                    match use_decl.imports {
                        UseImport::NamedItems { names } => {
                            collect_named_reexports(names, src_exports, src_prefix, export_names, reexport_aliases)
                        },
                        UseImport::Module => {
                            collect_module_reexports(src_exports, src_prefix, export_names, reexport_aliases)
                        },
                    }
                },
                none => {},
            }
        }
    }
    reexport_aliases
}

fn collect_named_reexports(names: List<NamedImport>, src_exports: ModuleExports,
    src_prefix: Str, mut export_names: List<Str>, mut reexport_aliases: List<Str>) {
    for item in names {
        let local_name = match item.alias { some(a) => a, none => item.name }
        let src_js = if src_exports.extern_values.contains(item.name) { safe_ident(item.name) } else { "${src_prefix}$${safe_ident(item.name)}" }
        let local_js = safe_ident(local_name)
        if local_js != src_js {
            reexport_aliases.push("const ${local_js} = ${src_js};")
        }
        export_names.push(local_js)
        match src_exports.types.get(item.name) {
            some(tdef) => match tdef {
                TypeDef::EnumDef_(edef) => {
                    for v in edef.variants {
                        let src_v = "${src_prefix}$${safe_ident(item.name)}_${v.name}"
                        let local_v = "${safe_ident(local_name)}_${v.name}"
                        if local_v != src_v {
                            reexport_aliases.push("const ${local_v} = ${src_v};")
                        }
                        export_names.push(local_v)
                    }
                },
                _ => {},
            },
            none => {},
        }
    }
}

fn collect_module_reexports(src_exports: ModuleExports, src_prefix: Str,
    mut export_names: List<Str>, mut reexport_aliases: List<Str>) {
    for ventry in src_exports.values.entries() {
        let (vname, _) = ventry
        if !src_exports.extern_values.contains(vname) {
            let src_js = "${src_prefix}$${safe_ident(vname)}"
            let local_js = safe_ident(vname)
            if local_js != src_js {
                reexport_aliases.push("const ${local_js} = ${src_js};")
            }
            export_names.push(local_js)
        }
    }
    for tentry in src_exports.types.entries() {
        let (tname, tdef) = tentry
        let src_js = "${src_prefix}$${safe_ident(tname)}"
        let local_js = safe_ident(tname)
        if local_js != src_js {
            reexport_aliases.push("const ${local_js} = ${src_js};")
        }
        export_names.push(local_js)
        match tdef {
            TypeDef::EnumDef_(edef) => {
                for v in edef.variants {
                    let src_v = "${src_prefix}$${safe_ident(tname)}_${v.name}"
                    let local_v = "${safe_ident(tname)}_${v.name}"
                    if local_v != src_v {
                        reexport_aliases.push("const ${local_v} = ${src_v};")
                    }
                    export_names.push(local_v)
                }
            },
            _ => {},
        }
    }
}

// ============================================================
// Helper functions for cross-module metadata
// ============================================================

fn build_imports_map(graph: ModuleGraph, exports_map: Map<Str, ModuleExports>, key: Str) -> Map<Str, Str> {
    let mut imports_map: Map<Str, Str> = map_new()
    match graph.dependencies.get(key) {
        some(deps) => {
            for dk in deps {
                match exports_map.get(dk) {
                    some(dep_exports) => {
                        let dep_prefix = dep_exports.module_prefix

                        // Collect bare variant names (no JS declaration)
                        let mut bare_variants: Set<Str> = set_new()
                        for tentry in dep_exports.types.entries() {
                            let (_, tdef) = tentry
                            match tdef {
                                TypeDef::EnumDef_(edef) => {
                                    for v in edef.variants { bare_variants.insert(v.name) }
                                },
                                _ => {},
                            }
                        }

                        for entry in dep_exports.values.entries() {
                            let (name, _) = entry
                            if dep_exports.extern_values.contains(name) {
                                imports_map.insert(name, safe_ident(name))
                            } else if bare_variants.contains(name) {
                                if !imports_map.contains_key(name) {
                                    let si = safe_ident(name)
                                    imports_map.insert(name, "${dep_prefix}$${si}")
                                }
                            } else {
                                let si = safe_ident(name)
                                imports_map.insert(name, "${dep_prefix}$${si}")
                            }
                        }
                        for entry in dep_exports.types.entries() {
                            let (name, type_def) = entry
                            let si = safe_ident(name)
                            imports_map.insert(name, "${dep_prefix}$${si}")
                            match type_def {
                                TypeDef::EnumDef_(edef) => {
                                    for v in edef.variants {
                                        let variant_js = "${dep_prefix}$${si}_${v.name}"
                                        imports_map.insert("${name}_${v.name}", variant_js)
                                    }
                                },
                                _ => {},
                            }
                        }
                        // Import trait dict names
                        for impl_ in dep_exports.trait_impls {
                            let dict_js = trait_dict_name(safe_ident(impl_.target_type_name), safe_ident(impl_.trait_name))
                            imports_map.insert(dict_js, "${dep_prefix}$${dict_js}")
                        }
                    },
                    none => {},
                }
            }
        },
        none => {},
    }
    imports_map
}

fn build_external_struct_fields(graph: ModuleGraph, exports_map: Map<Str, ModuleExports>, key: Str) -> Map<Str, List<Str>> {
    let mut result: Map<Str, List<Str>> = map_new()
    match graph.dependencies.get(key) {
        some(deps) => {
            for dk in deps {
                match exports_map.get(dk) {
                    some(dep_exports) => {
                        let dep_prefix = dep_exports.module_prefix
                        for entry in dep_exports.struct_field_orders.entries() {
                            let (name, fields) = entry
                            let si = safe_ident(name)
                            result.insert("${dep_prefix}$${si}", fields)
                        }
                    },
                    none => {},
                }
            }
        },
        none => {},
    }
    result
}

fn empty_module_exports_list() -> List<ModuleExports> {
    let mut x: List<ModuleExports> = []
    x
}

fn empty_str_list() -> List<Str> {
    let mut x: List<Str> = []
    x
}

fn build_external_impl_methods(graph: ModuleGraph, exports_map: Map<Str, ModuleExports>, key: Str) -> Map<Str, Str?> {
    let mut result: Map<Str, Str?> = map_new()
    match graph.dependencies.get(key) {
        some(deps) => {
            for dk in deps {
                match exports_map.get(dk) {
                    some(dep_exports) => {
                        let dep_prefix = dep_exports.module_prefix
                        for entry in dep_exports.impl_methods.entries() {
                            let (type_name, methods) = entry
                            let si = safe_ident(type_name)
                            for mentry in methods.entries() {
                                let (mname, _) = mentry
                                result.insert("${dep_prefix}$${si}.${mname}", none)
                            }
                        }
                    },
                    none => {},
                }
            }
        },
        none => {},
    }
    result
}

fn build_external_fn_mut_params(graph: ModuleGraph, exports_map: Map<Str, ModuleExports>, key: Str) -> Map<Str, List<Bool>> {
    let mut result: Map<Str, List<Bool>> = map_new()
    match graph.dependencies.get(key) {
        some(deps) => {
            for dk in deps {
                match exports_map.get(dk) {
                    some(dep_exports) => {
                        let dep_prefix = dep_exports.module_prefix
                        for entry in dep_exports.fn_mut_params.entries() {
                            let (fn_name, flags) = entry
                            // Register under both the raw name and the qualified name
                            result.insert(fn_name, flags)
                            let si = safe_ident(fn_name)
                            let qualified = "${dep_prefix}$${si}"
                            result.insert(qualified, flags)
                        }
                    },
                    none => {},
                }
            }
        },
        none => {},
    }
    result
}
