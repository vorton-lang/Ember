use types::{Type, Effect, EffectRow, effect_kind_name}
use hir::{HExpr, HStmt, HTraitMethod, HEffectOp, evidence_param_name}

const JS_RESERVED: Set<Str> = set_from(
    ["abstract", "arguments", "await", "boolean", "break", "byte", "case", "catch",
     "char", "class", "const", "continue", "debugger", "default", "delete", "do",
     "double", "else", "enum", "eval", "export", "extends", "false", "final",
     "finally", "float", "for", "function", "goto", "if", "implements", "import",
     "in", "instanceof", "int", "interface", "let", "long", "native", "new",
     "null", "package", "private", "protected", "public", "return", "short",
     "static", "super", "switch", "synchronized", "this", "throw", "throws",
     "transient", "true", "try", "typeof", "undefined", "var", "void",
     "volatile", "while", "with", "yield",
     "Object", "Array", "Map", "Set", "String", "Number", "Boolean", "Symbol",
     "Promise", "Error", "RegExp", "Date", "Math", "JSON", "Proxy", "Reflect",
     "WeakMap", "WeakSet", "WeakRef", "BigInt", "ArrayBuffer", "DataView",
     "Int8Array", "Uint8Array", "Float32Array", "Float64Array",
     "NaN", "Infinity", "globalThis", "console", "process"])

pub fn safe_ident(name: Str) -> Str {
    let result = if name.contains("::") { name.replace("::", "$") } else { name }
    if JS_RESERVED.contains(result) { "_${result}" } else { result }
}

pub struct CodegenCtx {
    pub lines: List<Str>,
    pub indent_level: Int,
    pub impl_methods: Map<Str, Str?>,
    pub struct_field_order: Map<Str, List<Str>>,
    pub trait_decls: Map<Str, HTraitDeclInfo>,
    pub match_counter: Int,
    pub dt_counter: Int,
    pub loop_counter: Int,
    pub module_prefix: Str?,
    pub imports_map: Map<Str, Str>?,
    pub skip_preamble: Bool,
    pub skip_main_call: Bool,
    pub local_names: Set<Str>,
    pub local_fn_effects: Map<Str, EffectRow>,
    pub current_fn_effects: EffectRow?,
    pub in_try_fail: Bool,
    pub module_imports: List<Str>?,
    pub module_exports: List<Str>?,
    pub default_evidence_effects: Set<Str>,
    pub default_evidence_params: Map<Str, List<Str>>,
    pub effect_ops: Map<Str, List<HEffectOp>>,
    pub boxed_vars: Set<Int>,
    pub fn_mut_params: Map<Str, List<Bool>>,
    pub block_counter: Int
}

pub struct HTraitDeclInfo {
    pub name: Str,
    pub methods: List<HTraitMethod>,
    pub supertraits: List<Str>
}

pub fn new_codegen_ctx(skip_preamble: Bool, skip_main_call: Bool) -> CodegenCtx {
    CodegenCtx {
        lines: [],
        indent_level: 0,
        impl_methods: map_new(),
        struct_field_order: map_new(),
        trait_decls: map_new(),
        match_counter: 0,
        dt_counter: 0,
        loop_counter: 0,
        module_prefix: none,
        imports_map: none,
        skip_preamble: skip_preamble,
        skip_main_call: skip_main_call,
        local_names: set_new(),
        local_fn_effects: map_new(),
        current_fn_effects: none,
        in_try_fail: false,
        module_imports: none,
        module_exports: none,
        default_evidence_effects: set_new(),
        default_evidence_params: map_new(),
        effect_ops: map_new(),
        boxed_vars: set_new(),
        fn_mut_params: map_new(),
        block_counter: 0
    }
}

fn indent_str(level: Int) -> Str {
    let mut result = ""
    for i in 0..level {
        result = "${result}  "
    }
    result
}

pub fn emit(mut ctx: CodegenCtx, line: Str) {
    let prefix = indent_str(ctx.indent_level)
    ctx.lines.push("${prefix}${line}")
}

pub fn emit_raw(mut ctx: CodegenCtx, text: Str) {
    ctx.lines.push(text)
}

pub fn push_indent(mut ctx: CodegenCtx) {
    ctx.indent_level = ctx.indent_level + 1
}

pub fn pop_indent(mut ctx: CodegenCtx) {
    ctx.indent_level = ctx.indent_level - 1
}

// Check if a name is imported from another module (cross-module reference).
// Imported names carry def_ids from a foreign id-space that can collide with
// local boxed_vars def_ids, so callers must skip boxed_vars checks for them.
pub fn is_imported_name(ctx: CodegenCtx, name: Str) -> Bool {
    match ctx.imports_map {
        some(imap) => {
            if !ctx.local_names.contains(name) {
                return imap.contains_key(name)
            }
            false
        },
        none => false,
    }
}

pub fn qualify(ctx: CodegenCtx, name: Str) -> Str {
    match ctx.imports_map {
        some(imap) => {
            if !ctx.local_names.contains(name) {
                match imap.get(name) {
                    some(qualified) => { return qualified },
                    none => {},
                }
            }
        },
        none => {},
    }
    match ctx.module_prefix {
        some(prefix) => {
            if ctx.local_names.contains(name) {
                let safe = safe_ident(name)
                return "${prefix}$${safe}"
            }
        },
        none => {},
    }
    safe_ident(name)
}

pub fn extract_effect_names(effects: EffectRow) -> List<Str> {
    let mut names: List<Str> = []
    for e in effects.effects {
        // Skip MutEffect — it is a compile-time marker with zero runtime cost
        match e {
            Effect::MutEffect { .. } => {},
            _ => {
                let n = effect_kind_name(e)
                if names.contains(n) == false {
                    names.push(n)
                }
            }
        }
    }
    names.sort()
    names
}

pub fn get_evidence_params(effects: EffectRow) -> List<Str> {
    extract_effect_names(effects).map(fn(n) { evidence_param_name(n) })
}

pub fn LIST_HOF_JS_METHOD(method: Str) -> Str? {
    if method == "map" { some("map") }
    else { if method == "filter" { some("filter") }
    else { if method == "flat_map" { some("flatMap") }
    else { if method == "any" { some("some") }
    else { if method == "all" { some("every") }
    else { none } } } } }
}

