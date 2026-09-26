use ast::{Span, Pattern, BinOp, UnaryOp, TypeParam}
use types::{Type, EffectRow, StructField, EnumVariant, RecordField}

pub use types::{BUILTIN_INT, BUILTIN_FLOAT, BUILTIN_STR, BUILTIN_BOOL,
    BUILTIN_RANGE, BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET,
    BUILTIN_OPTION, BUILTIN_CELL, BUILTIN_STRING_BUILDER}

pub use builtin_methods::{CELL_METHODS, STR_METHODS, INT_METHODS, FLOAT_METHODS,
    LIST_NON_HOF_METHODS, LIST_HOF_METHODS,
    MAP_NON_HOF_METHODS, MAP_HOF_METHODS,
    SET_NON_HOF_METHODS, SET_HOF_METHODS,
    OPTION_NON_HOF_METHODS, OPTION_HOF_METHODS,
    STRINGBUILDER_METHODS}

pub struct HParam {
    pub name: Str,
    pub ty: Type,
    pub def_id: Int?,
    pub is_mutable: Bool
}

pub enum DictRef {
    Simple(Str),
    Wrapped { dict: Str, trait_name: Str, inner_dicts: List<DictRef> }
}

pub enum TraitDispatch {
    Builtin,
    Direct { dict: Str, extra_dicts: List<DictRef> },
    Dict { param: Str }
}

pub struct DictDispatchInfo {
    pub dict_param: Str,
    pub method: Str
}

pub struct HStructFieldInit {
    pub name: Str,
    pub value: HExpr
}

pub struct HMatchArm {
    pub pattern: Pattern,
    pub guard: HExpr?,
    pub body: HExpr,
    pub span: Span
}

pub struct HEffectHandler {
    pub effect_name: Str,
    pub op_name: Str,
    pub params: List<HParam>,
    pub resume_name: Str?,
    pub body: HExpr
}

pub enum HStringInterpPart {
    Literal(Str),
    Expression(HExpr)
}

pub enum HExpr {
    IntLit { value: Int, ty: Type, effects: EffectRow, span: Span },
    FloatLit { value: Float, ty: Type, effects: EffectRow, span: Span },
    StrLit { value: Str, ty: Type, effects: EffectRow, span: Span },
    BoolLit { value: Bool, ty: Type, effects: EffectRow, span: Span },
    Ident { name: Str, resolved_name: Str?, def_id: Int?, dict_closure_dicts: List<Str>?, ty: Type, effects: EffectRow, span: Span },
    BinOp { op: BinOp, left: HExpr, right: HExpr, eq_dispatch: TraitDispatch?, ord_dispatch: TraitDispatch?, ty: Type, effects: EffectRow, span: Span },
    UnaryOp { op: UnaryOp, operand: HExpr, ty: Type, effects: EffectRow, span: Span },
    Call { callee: HExpr, args: List<HExpr>, type_args: List<Type>, resolved_dicts: List<DictRef>, dict_dispatch: DictDispatchInfo?, ty: Type, effects: EffectRow, span: Span },
    FieldAccess { receiver: HExpr, field: Str, ty: Type, effects: EffectRow, span: Span },
    StructLit { name: Str, type_args: List<Type>, fields: List<HStructFieldInit>, spread: HExpr?, ty: Type, effects: EffectRow, span: Span },
    NamedVariantConstruct { enum_name: Str, variant_name: Str, fields: List<HStructFieldInit>, spread: HExpr?, ty: Type, effects: EffectRow, span: Span },
    MatchExpr { scrutinee: HExpr, arms: List<HMatchArm>, ty: Type, effects: EffectRow, span: Span },
    Block { stmts: List<HStmt>, tail: HExpr?, ty: Type, effects: EffectRow, span: Span },
    IfExpr { condition: HExpr, then_branch: HExpr, else_branch: HExpr?, ty: Type, effects: EffectRow, span: Span },
    StringInterp { parts: List<HStringInterpPart>, ty: Type, effects: EffectRow, span: Span },
    TryCatch { body: HExpr, arms: List<HMatchArm>, ty: Type, effects: EffectRow, span: Span },
    HandleExpr { body: HExpr, handlers: List<HEffectHandler>, ty: Type, effects: EffectRow, span: Span },
    Lambda { params: List<HParam>, return_type: Type, body: HExpr, ty: Type, effects: EffectRow, span: Span },
    EffectOp { effect_name: Str, op_name: Str, args: List<HExpr>, ty: Type, effects: EffectRow, span: Span },
    RangeExpr { start: HExpr, end: HExpr, inclusive: Bool, ty: Type, effects: EffectRow, span: Span },
    ListLit { elements: List<HExpr>, ty: Type, effects: EffectRow, span: Span },
    TupleLit { elements: List<HExpr>, ty: Type, effects: EffectRow, span: Span },
    IndexExpr { receiver: HExpr, index: HExpr, ty: Type, effects: EffectRow, span: Span },
    // B-098: value-level clone inserted by the Perceus L1 borrow-inference pass
    // (clone-all-escape) for --target=llvm only.  Wraps an escaping value that
    // already has an independent owner (Ident binding / FieldAccess / IndexExpr /
    // container read result) so the escape gets its own owned reference rather
    // than aliasing the still-live source.  codegen lowers `Clone{inner}` to
    // eval inner -> ring_dup(result) -> result (ty/effects/span taken from inner).
    Clone { inner: HExpr, ty: Type, effects: EffectRow, span: Span }
}

pub struct HForInDestructure {
    pub name: Str,
    pub def_id: Int?
}

pub struct HLetDestructureBinding {
    pub name: Str,
    pub def_id: Int?,
    pub ty: Type
}

pub enum HStmt {
    Let { name: Str, name_span: Span, def_id: Int?, ty: Type, init: HExpr, span: Span },
    Var { name: Str, name_span: Span, def_id: Int?, ty: Type, init: HExpr, span: Span },
    Assign { target: HExpr, value: HExpr, span: Span },
    ExprStmt { expr: HExpr, span: Span },
    Return { value: HExpr?, span: Span },
    While { condition: HExpr, body: HExpr, span: Span },
    ForIn { binding: Str, binding_span: Span, def_id: Int?, destructure: List<HForInDestructure>?, iterable: HExpr, body: HExpr, iterable_type_name: Str?, iter_type_name: Str?, span: Span },
    Break { span: Span },
    Continue { span: Span },
    LetDestructure { pattern: Pattern, bindings: List<HLetDestructureBinding>, init: HExpr, span: Span },
    IfLet { pattern: Pattern, expr: HExpr, then_block: HExpr, else_block: HExpr?, span: Span },

    // Perceus RC: explicit reference counting ops (inserted by RC pass for --target=llvm only)
    Drop { name: Str, ty: Type, span: Span },
    Dup { name: Str, ty: Type, span: Span }
}

pub struct HStructField {
    pub name: Str,
    pub ty: Type,
    pub is_pub: Bool
}

pub struct HEnumVariant {
    pub name: Str,
    pub fields: List<Type>,
    pub field_names: List<Str>?
}

pub struct HEffectOp {
    pub name: Str,
    pub params: List<HParam>,
    pub return_type: Type,
    pub has_default: Bool,
    pub default_body: HExpr?
}

pub struct HTraitMethod {
    pub name: Str,
    pub params: List<HParam>,
    pub return_type: Type,
    pub has_default: Bool,
    pub body: HExpr?
}

pub struct TraitBound {
    pub type_param: Str,
    pub trait_name: Str
}

pub struct HAssocType {
    pub name: Str,
    pub bounds: List<Str>,
    pub concrete: Type?
}

pub struct HSigMember {
    pub name: Str,
    pub fn_type: Type,
    pub span: Span
}

pub enum HDecl {
    Fn { name: Str, def_id: Int?, type_params: List<TypeParam>, params: List<HParam>, return_type: Type, effects: EffectRow, body: HExpr, is_pub: Bool, trait_bounds: List<TraitBound>, span: Span },
    Struct { name: Str, type_params: List<TypeParam>, fields: List<HStructField>, is_pub: Bool, span: Span },
    Enum { name: Str, type_params: List<TypeParam>, variants: List<HEnumVariant>, is_pub: Bool, span: Span },
    Impl { target_type: Str, type_params: List<TypeParam>, trait_name: Str?, methods: List<HDecl>, assoc_types: List<HAssocType>, span: Span },
    Effect { name: Str, type_params: List<TypeParam>, ops: List<HEffectOp>, is_pub: Bool, span: Span },
    Test { description: Str, body: HExpr, span: Span },
    Trait { name: Str, type_params: List<TypeParam>, methods: List<HTraitMethod>, supertraits: List<Str>, assoc_types: List<HAssocType>, is_pub: Bool, span: Span },
    ExternFn { name: Str, def_id: Int?, type_params: List<TypeParam>, params: List<HParam>, return_type: Type, effects: EffectRow, is_pub: Bool, span: Span },
    ExternType { name: Str, type_params: List<TypeParam>, is_pub: Bool, span: Span },
    TypeAlias { name: Str, ty: Type, is_pub: Bool, span: Span },
    Const { name: Str, def_id: Int?, ty: Type, init: HExpr, is_pub: Bool, span: Span },
    ModBlock { name: Str, decls: List<HDecl>, is_pub: Bool, span: Span },
    Sig { name: Str, members: List<HSigMember>, is_pub: Bool, span: Span }
}

pub enum FieldAction {
    Identity,
    Call { dict_name: Str, extra_dicts: List<Str> },
    Tuple { element_actions: List<FieldAction> },
    FnLiteral
}

pub struct DerivedField {
    pub name: Str,
    pub positional_index: Int?,
    pub action: FieldAction
}

pub struct DerivedVariant {
    pub name: Str,
    pub fields: List<DerivedField>,
    pub has_named_fields: Bool
}

pub enum TypeKind { StructKind, EnumKind }

pub struct DerivedImpl {
    pub type_name: Str,
    pub trait_name: Str,
    pub type_params: List<Str>,
    pub bounds: List<TraitBound>,
    pub type_kind: TypeKind,
    pub struct_fields: List<DerivedField>?,
    pub enum_variants: List<DerivedVariant>?
}

pub struct HProgram {
    pub decls: List<HDecl>,
    pub derived_impls: List<DerivedImpl>,
    pub boxed_vars: Set<Int>
}

// B-102 R-clean (2026-06-07) — the A1 Type-DAG never-drop special case
// (is_type_dag_type_name / is_type_dag_type) is REMOVED.  Type and the
// structs/enums reachable from it now participate in ordinary Perceus RC:
// codegen_llvm generates a recursive ring_drop_T for them, perceus Clone-wraps
// every escaping owner-bearing Type substructure (so the shallow ring_dup is
// balanced by the deep recursive drop), and the working-set is reclaimed at
// scope end.  See design.md §7.11 "Type-DAG 内存回收：pure Perceus RC".

// JS codegen naming conventions
pub fn variant_js_name(enum_name: Str, variant_name: Str) -> Str {
    "${enum_name}_${variant_name}"
}

pub fn trait_dict_name(type_name: Str, trait_name: Str) -> Str {
    let safe_type = if type_name.contains("::") { type_name.replace("::", "$") } else { type_name }
    let safe_trait = if trait_name.contains("::") { trait_name.replace("::", "$") } else { trait_name }
    "__${safe_type}_${safe_trait}"
}

pub fn evidence_param_name(effect_name: Str) -> Str {
    let safe = if effect_name.contains("::") { effect_name.replace("::", "$") } else { effect_name }
    "__ring_ev_${safe}"
}

pub fn default_evidence_name(effect_name: Str) -> Str {
    let safe = if effect_name.contains("::") { effect_name.replace("::", "$") } else { effect_name }
    "__ring_default_ev_${safe}"
}

// B-090: declaration-order index of an op within its effect. This is the
// cross-phase contract between gen_handle_expr (which lays out the N-slot
// evidence struct, slot k = op k's {fn_ptr, env} closure) and gen_effect_op
// (which GEPs to this slot to dispatch). Slot order = op order in the effect
// declaration. Property is identical to variant_js_name: a naming/layout
// convention shared across codegen phases that must never be hardcoded per-site.
// Returns -1 if the op is not found (well-typed code never hits this — the
// checker rejects ops not declared on the effect).
pub fn effect_op_slot(effect_ops: Map<Str, List<HEffectOp>>, effect_name: Str, op_name: Str) -> Int {
    match effect_ops.get(effect_name) {
        some(ops) => {
            let mut idx = 0
            let mut found = -1
            for o in ops {
                if o.name == op_name && found == -1 { found = idx }
                idx = idx + 1
            }
            found
        },
        none => -1,
    }
}

pub fn trait_bound_param_name(type_param: Str, trait_name: Str) -> Str {
    let safe_trait = if trait_name.contains("::") { trait_name.replace("::", "$") } else { trait_name }
    "__ring_${type_param}_${safe_trait}"
}

pub fn default_method_self_name(type_name: Str) -> Str {
    "__ring_self_${type_name}"
}

pub const ENUM_TAG_FIELD: Str = "_tag"
pub const OPTION_SOME_TAG: Str = "some"
pub const OPTION_NONE_TAG: Str = "none"
pub const OPTION_PAYLOAD_FIELD: Str = "_0"
pub const RUNTIME_EFFECT_ABORT: Str = "__EffectAbort"
pub const RUNTIME_MATCH_FAIL: Str = "__match_fail"

pub fn hexpr_type(e: HExpr) -> Type {
    match e {
        HExpr::IntLit { ty, .. } => ty,
        HExpr::FloatLit { ty, .. } => ty,
        HExpr::StrLit { ty, .. } => ty,
        HExpr::BoolLit { ty, .. } => ty,
        HExpr::Ident { ty, .. } => ty,
        HExpr::BinOp { ty, .. } => ty,
        HExpr::UnaryOp { ty, .. } => ty,
        HExpr::Call { ty, .. } => ty,
        HExpr::FieldAccess { ty, .. } => ty,
        HExpr::StructLit { ty, .. } => ty,
        HExpr::NamedVariantConstruct { ty, .. } => ty,
        HExpr::MatchExpr { ty, .. } => ty,
        HExpr::Block { ty, .. } => ty,
        HExpr::IfExpr { ty, .. } => ty,
        HExpr::StringInterp { ty, .. } => ty,
        HExpr::TryCatch { ty, .. } => ty,
        HExpr::HandleExpr { ty, .. } => ty,
        HExpr::Lambda { ty, .. } => ty,
        HExpr::EffectOp { ty, .. } => ty,
        HExpr::RangeExpr { ty, .. } => ty,
        HExpr::ListLit { ty, .. } => ty,
        HExpr::TupleLit { ty, .. } => ty,
        HExpr::IndexExpr { ty, .. } => ty,
        HExpr::Clone { ty, .. } => ty
    }
}

pub fn hexpr_effects(e: HExpr) -> EffectRow {
    match e {
        HExpr::IntLit { effects, .. } => effects,
        HExpr::FloatLit { effects, .. } => effects,
        HExpr::StrLit { effects, .. } => effects,
        HExpr::BoolLit { effects, .. } => effects,
        HExpr::Ident { effects, .. } => effects,
        HExpr::BinOp { effects, .. } => effects,
        HExpr::UnaryOp { effects, .. } => effects,
        HExpr::Call { effects, .. } => effects,
        HExpr::FieldAccess { effects, .. } => effects,
        HExpr::StructLit { effects, .. } => effects,
        HExpr::NamedVariantConstruct { effects, .. } => effects,
        HExpr::MatchExpr { effects, .. } => effects,
        HExpr::Block { effects, .. } => effects,
        HExpr::IfExpr { effects, .. } => effects,
        HExpr::StringInterp { effects, .. } => effects,
        HExpr::TryCatch { effects, .. } => effects,
        HExpr::HandleExpr { effects, .. } => effects,
        HExpr::Lambda { effects, .. } => effects,
        HExpr::EffectOp { effects, .. } => effects,
        HExpr::RangeExpr { effects, .. } => effects,
        HExpr::ListLit { effects, .. } => effects,
        HExpr::TupleLit { effects, .. } => effects,
        HExpr::IndexExpr { effects, .. } => effects,
        HExpr::Clone { effects, .. } => effects
    }
}

pub fn hexpr_span(e: HExpr) -> Span {
    match e {
        HExpr::IntLit { span, .. } => span,
        HExpr::FloatLit { span, .. } => span,
        HExpr::StrLit { span, .. } => span,
        HExpr::BoolLit { span, .. } => span,
        HExpr::Ident { span, .. } => span,
        HExpr::BinOp { span, .. } => span,
        HExpr::UnaryOp { span, .. } => span,
        HExpr::Call { span, .. } => span,
        HExpr::FieldAccess { span, .. } => span,
        HExpr::StructLit { span, .. } => span,
        HExpr::NamedVariantConstruct { span, .. } => span,
        HExpr::MatchExpr { span, .. } => span,
        HExpr::Block { span, .. } => span,
        HExpr::IfExpr { span, .. } => span,
        HExpr::StringInterp { span, .. } => span,
        HExpr::TryCatch { span, .. } => span,
        HExpr::HandleExpr { span, .. } => span,
        HExpr::Lambda { span, .. } => span,
        HExpr::EffectOp { span, .. } => span,
        HExpr::RangeExpr { span, .. } => span,
        HExpr::ListLit { span, .. } => span,
        HExpr::TupleLit { span, .. } => span,
        HExpr::IndexExpr { span, .. } => span,
        HExpr::Clone { span, .. } => span
    }
}

// ============================================================
// B-104 D1 built-in rule ① — extern-handle type-level RC exclusion (audit #139)
// ============================================================
//
// `extern type` declarations (llvm_ffi.ring / the codegen_llvm_* re-declarations)
// describe OPAQUE FOREIGN handles: their values are raw pointers produced by a
// non-Ring allocator (LLVM-C API), with NO ring_alloc RC header at ptr-8.
// ring_dup on one WRITES a refcount into foreign memory; ring_drop READS a
// garbage header and may free a foreign interior pointer — both corrupt the
// foreign heap.  Such values are therefore EXCLUDED from RC entirely, decided at
// the TYPE level (not a name-list of the 59 LLVM-C externs, which would drift as
// the FFI grows — 2026-06-11 user decision, backlog B-104 D1 rule ①):
//   * never Clone   (rc_escape: escape = MOVE, no ring_dup)
//   * never Drop    (is_droppable_init: false → never enters the owned set)
//   * never materialise (anf_should_materialize: false → no __anf binding)
//
// The registry side: checker registers `extern type X` as
// `StructDef { fields: [], is_extern: true }` (infer_register.ring), and every
// use site resolves to `Type::StructType { name: X, .. }` carrying the SAME name
// as the `HDecl::ExternType` decl (bare for file-level decls; `${mod}::${name}`
// for inline-mod decls — check_mod_decl prefixes the decl BEFORE check_decl, so
// HIR decl name and StructType name agree in both forms).  Perceus runs PER
// MODULE (compiler_mod.ring), and every module that handles LLVM values
// re-declares the extern types locally (codegen_llvm_* convention), so
// collecting this module's HDecl::ExternType names covers all its use sites.
// KNOWN LIMIT (crash direction, documented in worker_feedback): a module that
// imports an extern type via `use` WITHOUT a local re-declaration would not be
// covered — no such module exists today, and the codegen_llvm convention is to
// re-declare.

// Collect the extern type names declared by this module's HIR (recursing into
// inline mod blocks, whose decl names are already module-prefixed).
pub fn collect_extern_type_names(decls: List<HDecl>) -> Set<Str> {
    let mut out: Set<Str> = set_new()
    collect_extern_type_names_rec(decls, out)
    out
}

fn collect_extern_type_names_rec(decls: List<HDecl>, mut out: Set<Str>) {
    for d in decls {
        match d {
            HDecl::ExternType { name, .. } => { out.insert(name) },
            HDecl::ModBlock { decls: md, .. } => { collect_extern_type_names_rec(md, out) },
            _ => {},
        }
    }
}

// A type whose values ARE foreign handles (direct extern type).  ring_dup /
// ring_drop on such a value corrupts foreign memory — full RC exclusion.
pub fn is_extern_handle_type(ty: Type, externs: Set<Str>) -> Bool {
    if externs.len() == 0 {
        false
    } else {
        match ty {
            Type::StructType { name, .. } => externs.contains(name),
            _ => false,
        }
    }
}

// B-104 D1 rule ② (Unit) + rule ① (direct extern): a value of this type must
// never be Clone'd, never be Drop'ed, never enter the owned set, and never be
// materialised.  UnitType: the checker guarantees Unit has no value semantics
// (JS backend yields undefined); at the LLVM ABI a Unit-typed call may
// accidentally return a live pointer (the receiver-returning mutators —
// `return list;` etc., see perceus.ring's B-103 classification table), so
// dup/drop bookkeeping on it is at best a pin-leak and at worst a UAF.
pub fn is_rc_excluded_type(ty: Type, externs: Set<Str>) -> Bool {
    match ty {
        Type::UnitType => true,
        _ => is_extern_handle_type(ty, externs),
    }
}

// A type whose values, when DEEP-DROPPED, would reach a foreign handle: the
// extern type itself, or a container / Option / tuple / struct / enum that
// transitively holds one (e.g. `List<LLVMTypeRef>` — drop_list ring_drops each
// element; `LLVMValueRef?` — drop_option drops the payload; `LlvmCtx` — its
// drop_T would drop extern fields and `Map<Str, LLVMValueRef>` fields whose
// runtime drop_map drops the foreign values).  Such values must never be
// scope-end-dropped or materialised (leak instead — crash-free direction).
// A SHALLOW ring_dup on a non-extern container of extern handles is safe (the
// container itself has a real RC header), so Clone-on-escape stays allowed for
// these (only the DIRECT extern type suppresses Clone — is_extern_handle_type).
//
// FnType is NOT recursed: a closure's captures are not described by its
// signature, and drop_closure_env releases captures, not param/return values.
// Recursive types terminate via an on-stack visited set (struct/enum names);
// monotone OR + one full exploration per name keeps reachability exact.
pub fn type_contains_extern_handle(ty: Type, externs: Set<Str>) -> Bool {
    if externs.len() == 0 {
        false
    } else {
        let mut visited: Set<Str> = set_new()
        type_contains_extern_rec(ty, externs, visited)
    }
}

fn type_contains_extern_rec(ty: Type, externs: Set<Str>, mut visited: Set<Str>) -> Bool {
    match ty {
        Type::StructType { name, type_params, fields } => {
            if externs.contains(name) {
                true
            } else if visited.contains("S:${name}") {
                false
            } else {
                visited.insert("S:${name}")
                let mut found = false
                for tp in type_params {
                    if type_contains_extern_rec(tp, externs, visited) { found = true }
                }
                for f in fields {
                    if type_contains_extern_rec(f.ty, externs, visited) { found = true }
                }
                found
            }
        },
        Type::EnumType { name, type_params, variants } => {
            if visited.contains("E:${name}") {
                false
            } else {
                visited.insert("E:${name}")
                let mut found = false
                for tp in type_params {
                    if type_contains_extern_rec(tp, externs, visited) { found = true }
                }
                for v in variants {
                    for ft in v.fields {
                        if type_contains_extern_rec(ft, externs, visited) { found = true }
                    }
                }
                found
            }
        },
        Type::TupleType { elements } => {
            let mut found = false
            for e in elements {
                if type_contains_extern_rec(e, externs, visited) { found = true }
            }
            found
        },
        Type::GenericType { base, args } => {
            let mut found = type_contains_extern_rec(base, externs, visited)
            for a in args {
                if type_contains_extern_rec(a, externs, visited) { found = true }
            }
            found
        },
        Type::RecordType { fields, .. } => {
            let mut found = false
            for f in fields {
                if type_contains_extern_rec(f.ty, externs, visited) { found = true }
            }
            found
        },
        _ => false,
    }
}
