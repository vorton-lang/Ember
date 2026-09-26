use types::{Type}
use ast::{Program, Decl, UseImport, NamedImport}
use hir::{HProgram, HDecl}
use env::{TypeEnv, TypeScheme, StructDef, EnumDef, EffectDef, TraitDef, ImplEntry, EffectAliasDef}
use infer_register::{prefix_decl_name}

// ============================================================
// ModuleExports — the public interface of a compiled module
// ============================================================

pub struct ModuleExports {
    pub module_key: Str,
    pub module_prefix: Str,
    pub values: Map<Str, TypeScheme>,
    pub types: Map<Str, TypeDef>,
    pub effects: Map<Str, EffectDef>,
    pub effect_aliases: Map<Str, EffectAliasDef>,
    pub traits: Map<Str, TraitDef>,
    pub trait_impls: List<ImplEntry>,
    pub impl_methods: Map<Str, Map<Str, TypeScheme>>,
    pub inherent_methods: Map<Str, List<Str>>,
    pub struct_field_orders: Map<Str, List<Str>>,
    pub extern_values: Set<Str>,
    pub mut_methods: Map<Str, Set<Str>>,
    pub fn_mut_params: Map<Str, List<Bool>>
}

pub enum TypeDef {
    StructDef_(StructDef),
    EnumDef_(EnumDef)
}

// ============================================================
// extract_exports
// ============================================================

pub fn extract_exports(
    module_key: Str,
    module_prefix: Str,
    program: Program,
    hprogram: HProgram,
    env: TypeEnv,
    fn_mut_params_map: Map<Str, List<Bool>>
) -> ModuleExports {
    let mut values: Map<Str, TypeScheme> = map_new()
    let mut types: Map<Str, TypeDef> = map_new()
    let mut effects: Map<Str, EffectDef> = map_new()
    let mut effect_aliases: Map<Str, EffectAliasDef> = map_new()
    let mut traits: Map<Str, TraitDef> = map_new()
    let mut impl_methods: Map<Str, Map<Str, TypeScheme>> = map_new()
    let mut inherent_methods: Map<Str, List<Str>> = map_new()
    let mut struct_field_orders: Map<Str, List<Str>> = map_new()
    let mut extern_values: Set<Str> = set_new()
    let mut mut_methods: Map<Str, Set<Str>> = map_new()
    let mut fn_mut_params: Map<Str, List<Bool>> = map_new()
    for decl in program.decls {
        match decl {
            Decl::Fn { name, is_pub, .. } => {
                if is_pub {
                    match env.lookup(name) {
                        some(scheme) => { values.insert(name, scheme) },
                        none => {},
                    }
                    match fn_mut_params_map.get(name) {
                        some(flags) => { fn_mut_params.insert(name, flags) },
                        none => {},
                    }
                }
            },
            Decl::Struct { name, is_pub, .. } => {
                if is_pub {
                    match env.types.structs.get(name) {
                        some(sdef) => {
                            types.insert(name, TypeDef::StructDef_(sdef))
                            let mut field_names: List<Str> = []
                            for f in sdef.fields { field_names.push(f.name) }
                            struct_field_orders.insert(name, field_names)
                        },
                        none => {},
                    }
                }
            },
            Decl::Enum { name, is_pub, .. } => {
                if is_pub {
                    match env.types.enums.get(name) {
                        some(edef) => {
                            types.insert(name, TypeDef::EnumDef_(edef))
                            for v in edef.variants {
                                match env.lookup(v.name) {
                                    some(vscheme) => { values.insert(v.name, vscheme) },
                                    none => {},
                                }
                            }
                        },
                        none => {},
                    }
                }
            },
            Decl::Effect { name, is_pub, .. } => {
                if is_pub {
                    match env.types.effects.get(name) {
                        some(effdef) => { effects.insert(name, effdef) },
                        none => {},
                    }
                }
            },
            Decl::EffectAlias { name, is_pub, .. } => {
                if is_pub {
                    match env.types.effect_aliases.get(name) {
                        some(adef) => { effect_aliases.insert(name, adef) },
                        none => {},
                    }
                }
            },
            Decl::Trait { name, is_pub, .. } => {
                if is_pub {
                    match env.trait_reg.traits.get(name) {
                        some(tdef) => { traits.insert(name, tdef) },
                        none => {},
                    }
                }
            },
            Decl::Impl { target_type, trait_name, methods, .. } => {
                match env.trait_reg.impl_methods.get(target_type) {
                    some(methods_map) => {
                        impl_methods.insert(target_type, map_clone(methods_map))
                    },
                    none => {},
                }
                // Export mut_methods for this type
                match env.trait_reg.mut_methods.get(target_type) {
                    some(ms) => { mut_methods.insert(target_type, ms) },
                    none => {},
                }
                // Export fn_mut_params for impl methods
                for m in methods {
                    match m {
                        Decl::Fn { name: mname, .. } => {
                            let full_name = "${target_type}_${mname}"
                            match fn_mut_params_map.get(full_name) {
                                some(flags) => { fn_mut_params.insert(full_name, flags) },
                                none => {},
                            }
                        },
                        _ => {},
                    }
                }
                match trait_name {
                    none => {
                        // Inherent methods
                        let mut is_pub_type = false
                        for d in program.decls {
                            match d {
                                Decl::Struct { name, is_pub, .. } => {
                                    if name == target_type && is_pub { is_pub_type = true }
                                },
                                Decl::Enum { name, is_pub, .. } => {
                                    if name == target_type && is_pub { is_pub_type = true }
                                },
                                _ => {},
                            }
                        }
                        if is_pub_type {
                            let mut method_names: List<Str> = []
                            for m in methods {
                                match m {
                                    Decl::Fn { name, .. } => method_names.push(name),
                                    _ => {},
                                }
                            }
                            match inherent_methods.get(target_type) {
                                some(existing) => existing.extend(method_names),
                                none => { inherent_methods.insert(target_type, method_names) },
                            }
                        }
                    },
                    some(_) => {},
                }
            },
            Decl::ExternFn { name, is_pub, .. } => {
                if is_pub {
                    extern_values.insert(name)
                    match env.lookup(name) {
                        some(scheme) => { values.insert(name, scheme) },
                        none => {},
                    }
                }
            },
            Decl::ExternType { name, is_pub, .. } => {
                if is_pub {
                    match env.types.structs.get(name) {
                        some(sdef) => { types.insert(name, TypeDef::StructDef_(sdef)) },
                        none => {},
                    }
                }
            },
            Decl::Const { name, is_pub, .. } => {
                if is_pub {
                    match env.lookup(name) {
                        some(scheme) => { values.insert(name, scheme) },
                        none => {},
                    }
                }
            },
            Decl::ModBlock { name: mod_name, decls: mod_decls, is_pub: mpub, .. } => {
                if mpub {
                    for subdecl in mod_decls {
                        let prefixed = prefix_decl_name(mod_name, subdecl)
                        match prefixed {
                            Decl::Fn { name: fname, is_pub: fpub, .. } => {
                                if fpub {
                                    match env.lookup(fname) {
                                        some(scheme) => { values.insert(fname, scheme) },
                                        none => {},
                                    }
                                    match fn_mut_params_map.get(fname) {
                                        some(flags) => { fn_mut_params.insert(fname, flags) },
                                        none => {},
                                    }
                                }
                            },
                            Decl::Struct { name: sname, is_pub: spub, .. } => {
                                if spub {
                                    match env.types.structs.get(sname) {
                                        some(sdef) => {
                                            types.insert(sname, TypeDef::StructDef_(sdef))
                                            let mut field_names: List<Str> = []
                                            for f in sdef.fields { field_names.push(f.name) }
                                            struct_field_orders.insert(sname, field_names)
                                        },
                                        none => {},
                                    }
                                }
                            },
                            Decl::Enum { name: ename, is_pub: epub, .. } => {
                                if epub {
                                    match env.types.enums.get(ename) {
                                        some(edef) => {
                                            types.insert(ename, TypeDef::EnumDef_(edef))
                                            for v in edef.variants {
                                                match env.lookup(v.name) {
                                                    some(vscheme) => { values.insert(v.name, vscheme) },
                                                    none => {},
                                                }
                                            }
                                        },
                                        none => {},
                                    }
                                }
                            },
                            Decl::Const { name: cname, is_pub: cpub, .. } => {
                                if cpub {
                                    match env.lookup(cname) {
                                        some(scheme) => { values.insert(cname, scheme) },
                                        none => {},
                                    }
                                }
                            },
                            Decl::Effect { name: eff_name, is_pub: eff_pub, .. } => {
                                if eff_pub {
                                    match env.types.effects.get(eff_name) {
                                        some(effdef) => { effects.insert(eff_name, effdef) },
                                        none => {},
                                    }
                                }
                            },
                            Decl::EffectAlias { name: ea_name, is_pub: ea_pub, .. } => {
                                if ea_pub {
                                    match env.types.effect_aliases.get(ea_name) {
                                        some(adef) => { effect_aliases.insert(ea_name, adef) },
                                        none => {},
                                    }
                                }
                            },
                            Decl::Trait { name: t_name, is_pub: t_pub, .. } => {
                                if t_pub {
                                    match env.trait_reg.traits.get(t_name) {
                                        some(tdef) => { traits.insert(t_name, tdef) },
                                        none => {},
                                    }
                                }
                            },
                            Decl::Impl { target_type: tt, trait_name: tn, methods: ms, .. } => {
                                match env.trait_reg.impl_methods.get(tt) {
                                    some(methods_map) => {
                                        impl_methods.insert(tt, map_clone(methods_map))
                                    },
                                    none => {},
                                }
                                match env.trait_reg.mut_methods.get(tt) {
                                    some(ms2) => { mut_methods.insert(tt, ms2) },
                                    none => {},
                                }
                                for m in ms {
                                    match m {
                                        Decl::Fn { name: mn, .. } => {
                                            let full = "${tt}_${mn}"
                                            match fn_mut_params_map.get(full) {
                                                some(flags) => { fn_mut_params.insert(full, flags) },
                                                none => {},
                                            }
                                        },
                                        _ => {},
                                    }
                                }
                            },
                            Decl::ModBlock { name: sub_mod_name, decls: sub_mod_decls, is_pub: sub_mpub, .. } => {
                                if sub_mpub {
                                    for sub_subdecl in sub_mod_decls {
                                        let sub_prefixed = prefix_decl_name(sub_mod_name, sub_subdecl)
                                        match sub_prefixed {
                                            Decl::Fn { name: fname2, is_pub: fpub2, .. } => {
                                                if fpub2 {
                                                    match env.lookup(fname2) {
                                                        some(scheme) => { values.insert(fname2, scheme) },
                                                        none => {},
                                                    }
                                                    match fn_mut_params_map.get(fname2) {
                                                        some(flags) => { fn_mut_params.insert(fname2, flags) },
                                                        none => {},
                                                    }
                                                }
                                            },
                                            Decl::Struct { name: sname2, is_pub: spub2, .. } => {
                                                if spub2 {
                                                    match env.types.structs.get(sname2) {
                                                        some(sdef) => {
                                                            types.insert(sname2, TypeDef::StructDef_(sdef))
                                                            let mut fns2: List<Str> = []
                                                            for f in sdef.fields { fns2.push(f.name) }
                                                            struct_field_orders.insert(sname2, fns2)
                                                        },
                                                        none => {},
                                                    }
                                                }
                                            },
                                            Decl::Enum { name: ename2, is_pub: epub2, .. } => {
                                                if epub2 {
                                                    match env.types.enums.get(ename2) {
                                                        some(edef) => {
                                                            types.insert(ename2, TypeDef::EnumDef_(edef))
                                                            for v in edef.variants {
                                                                match env.lookup(v.name) {
                                                                    some(vscheme) => { values.insert(v.name, vscheme) },
                                                                    none => {},
                                                                }
                                                            }
                                                        },
                                                        none => {},
                                                    }
                                                }
                                            },
                                            Decl::Const { name: cname2, is_pub: cpub2, .. } => {
                                                if cpub2 {
                                                    match env.lookup(cname2) {
                                                        some(scheme) => { values.insert(cname2, scheme) },
                                                        none => {},
                                                    }
                                                }
                                            },
                                            Decl::Effect { name: eff_name2, is_pub: eff_pub2, .. } => {
                                                if eff_pub2 {
                                                    match env.types.effects.get(eff_name2) {
                                                        some(effdef) => { effects.insert(eff_name2, effdef) },
                                                        none => {},
                                                    }
                                                }
                                            },
                                            Decl::EffectAlias { name: ea_name2, is_pub: ea_pub2, .. } => {
                                                if ea_pub2 {
                                                    match env.types.effect_aliases.get(ea_name2) {
                                                        some(adef) => { effect_aliases.insert(ea_name2, adef) },
                                                        none => {},
                                                    }
                                                }
                                            },
                                            Decl::Trait { name: t_name2, is_pub: t_pub2, .. } => {
                                                if t_pub2 {
                                                    match env.trait_reg.traits.get(t_name2) {
                                                        some(tdef) => { traits.insert(t_name2, tdef) },
                                                        none => {},
                                                    }
                                                }
                                            },
                                            Decl::Impl { target_type: tt2, trait_name: tn2, methods: ms2, .. } => {
                                                match env.trait_reg.impl_methods.get(tt2) {
                                                    some(methods_map) => {
                                                        impl_methods.insert(tt2, map_clone(methods_map))
                                                    },
                                                    none => {},
                                                }
                                                match env.trait_reg.mut_methods.get(tt2) {
                                                    some(ms3) => { mut_methods.insert(tt2, ms3) },
                                                    none => {},
                                                }
                                                for m in ms2 {
                                                    match m {
                                                        Decl::Fn { name: mn2, .. } => {
                                                            let full2 = "${tt2}_${mn2}"
                                                            match fn_mut_params_map.get(full2) {
                                                                some(flags) => { fn_mut_params.insert(full2, flags) },
                                                                none => {},
                                                            }
                                                        },
                                                        _ => {},
                                                    }
                                                }
                                            },
                                            _ => {},
                                        }
                                    }
                                }
                            },
                            _ => {},
                        }
                    }
                }
            },
            _ => {},
        }
    }

    // Filter trait impls
    let mut trait_impls: List<ImplEntry> = []
    for map_entry in env.trait_reg.trait_impls.entries() {
        let (_, impl_list) = map_entry
        for impl_ in impl_list {
            if types.contains_key(impl_.target_type_name) || traits.contains_key(impl_.trait_name) {
                trait_impls.push(impl_)
            }
        }
    }

    // Handle pub use re-exports
    for use_decl in program.uses {
        if use_decl.is_pub {
            match use_decl.imports {
                UseImport::NamedItems { names } => {
                    for item in names {
                        let local_name = match item.alias {
                            some(a) => a,
                            none => item.name,
                        }
                        match env.lookup(local_name) {
                            some(scheme) => { values.insert(local_name, scheme) },
                            none => {},
                        }
                        match env.types.structs.get(local_name) {
                            some(sdef) => {
                                types.insert(local_name, TypeDef::StructDef_(sdef))
                                let mut fnames: List<Str> = []
                                for f in sdef.fields { fnames.push(f.name) }
                                struct_field_orders.insert(local_name, fnames)
                            },
                            none => {},
                        }
                        match env.types.enums.get(local_name) {
                            some(edef) => { types.insert(local_name, TypeDef::EnumDef_(edef)) },
                            none => {},
                        }
                        match env.types.effects.get(local_name) {
                            some(effdef) => { effects.insert(local_name, effdef) },
                            none => {},
                        }
                        match env.trait_reg.traits.get(local_name) {
                            some(tdef) => { traits.insert(local_name, tdef) },
                            none => {},
                        }
                    }
                },
                _ => {},
            }
        }
    }

    ModuleExports {
        module_key: module_key,
        module_prefix: module_prefix,
        values: values,
        types: types,
        effects: effects,
        effect_aliases: effect_aliases,
        traits: traits,
        trait_impls: trait_impls,
        impl_methods: impl_methods,
        inherent_methods: inherent_methods,
        struct_field_orders: struct_field_orders,
        extern_values: extern_values,
        mut_methods: mut_methods,
        fn_mut_params: fn_mut_params
    }
}

