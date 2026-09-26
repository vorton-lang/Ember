use types::{Type, Effect, EffectRow, effect_kind_name}
use hir::{HEffectOp}

// Re-declare LLVM opaque types to avoid cross-module ESM import issues.
// These match the declarations in llvm_ffi.ring and unify to the same types.
extern type LLVMContextRef
extern type LLVMModuleRef
extern type LLVMBuilderRef
extern type LLVMTypeRef
extern type LLVMValueRef
extern type LLVMBasicBlockRef
extern type LLVMTargetMachineRef

// Re-declare LLVM functions used by utility functions
extern fn LLVMFunctionType(ret: LLVMTypeRef, params: List<LLVMTypeRef>, is_var_arg: Int) -> LLVMTypeRef
extern fn LLVMAddFunction(m: LLVMModuleRef, name: Str, fn_ty: LLVMTypeRef) -> LLVMValueRef
extern fn LLVMBuildAlloca(builder: LLVMBuilderRef, ty: LLVMTypeRef, name: Str) -> LLVMValueRef
extern fn LLVMGetInsertBlock(builder: LLVMBuilderRef) -> LLVMBasicBlockRef
extern fn LLVMGetBasicBlockParent(bb: LLVMBasicBlockRef) -> LLVMValueRef
extern fn LLVMGetEntryBasicBlock(fn_val: LLVMValueRef) -> LLVMBasicBlockRef
extern fn LLVMPositionBuilderAtEnd(builder: LLVMBuilderRef, bb: LLVMBasicBlockRef) -> Unit
extern fn LLVMGetFirstInstruction(bb: LLVMBasicBlockRef) -> LLVMValueRef
extern fn LLVMPositionBuilderBefore(builder: LLVMBuilderRef, instr: LLVMValueRef) -> Unit
extern fn LLVMIsNullPtr(val: LLVMValueRef) -> Int

// ============================================================
// Shared data structures for LLVM codegen
// ============================================================

pub struct StructFieldInfo {
    pub field_names: List<Str>,
    pub llvm_type: LLVMTypeRef
}

pub struct EnumVariantInfo {
    pub tag: Int,
    pub field_count: Int,
    pub field_names: List<Str>
}

pub struct EnumTypeInfo {
    pub variants: Map<Str, EnumVariantInfo>,
    pub max_fields: Int,
    pub llvm_type: LLVMTypeRef
}

pub struct LlvmCtx {
    pub context: LLVMContextRef,
    pub module: LLVMModuleRef,
    pub builder: LLVMBuilderRef,
    pub target_machine: LLVMTargetMachineRef,

    // Type cache
    pub ptr_type: LLVMTypeRef,
    pub i64_type: LLVMTypeRef,
    pub i32_type: LLVMTypeRef,
    pub i8_type: LLVMTypeRef,
    pub i1_type: LLVMTypeRef,
    pub void_type: LLVMTypeRef,
    pub double_type: LLVMTypeRef,

    // Value mappings
    pub named_values: Map<Str, LLVMValueRef>,
    pub functions: Map<Str, LLVMValueRef>,
    pub fn_types: Map<Str, LLVMTypeRef>,
    pub struct_types: Map<Str, StructFieldInfo>,
    pub enum_types: Map<Str, EnumTypeInfo>,

    // Runtime function cache
    pub rt_fns: Map<Str, LLVMValueRef>,
    pub rt_fn_types: Map<Str, LLVMTypeRef>,

    // Compiler metadata
    pub local_fn_effects: Map<Str, EffectRow>,
    pub fn_evidence_params: Map<Str, List<Str>>,

    // Trait dict globals: maps dict name → LLVMValueRef (global ptr)
    pub dict_globals: Map<Str, LLVMValueRef>,

    // Trait method order: maps trait_name → [method_name, ...]
    pub trait_method_order: Map<Str, List<Str>>,

    // Module prefix for multi-file compilation (e.g. "lexer" → functions prefixed "ring_lexer$_")
    pub module_prefix: Str?,

    // Imports map: maps imported names to their qualified LLVM names
    pub imports_map: Map<Str, Str>,

    // Local names: set of names defined in the current module
    pub local_names: Set<Str>,

    // Counters
    pub tmp_counter: Int,
    pub lambda_counter: Int,
    pub match_counter: Int,

    // Current function being codegen'd
    pub current_fn: LLVMValueRef?,
    // Name of the current function (for diagnostics, e.g. non-exhaustive match)
    pub current_fn_name: Str,

    // Loop context for break/continue
    pub loop_break_bb: LLVMBasicBlockRef?,
    pub loop_continue_bb: LLVMBasicBlockRef?,

    // Perceus RC: typeid allocation for user-defined types
    pub next_user_typeid: Int,         // starts at 64 (USER_BASE), increments per type
    pub type_to_typeid: Map<Str, Int>, // type name -> typeid mapping

    // B-091: def_ids of `let mut` variables auto-boxed into heap mut-cells because
    // a closure writes through them.  Mirrors the JS backend's `{value: ...}` cell.
    // Such a var's alloca holds the CELL pointer; reads/writes go through field 0;
    // closures capture the (shared) cell pointer so write-through is observed.
    pub boxed_vars: Set<Int>,

    // #B-087 gap 5 (#103): per-function list of param mutability flags. A flag is
    // true only for params that are `mut` AND value-type (Int/Float/Bool/Str) — the
    // ones the callee receives as a CELL pointer and the caller must box. Mirrors the
    // JS backend's CodegenCtx.fn_mut_params (scan_fn_mut_params). Keyed by both the
    // bare fn name and the UFCS method name (Type_method) for method-call lookup.
    pub fn_mut_params: Map<Str, List<Bool>>,

    // B-090: effect declaration registry, keyed by effect name → ops in
    // declaration order. gen_handle_expr lays the evidence struct out in this
    // order; gen_effect_op dispatches via effect_op_slot (hir.ring) using the
    // same registry. Mirrors the JS backend's CodegenCtx.effect_ops.
    pub effect_ops: Map<Str, List<HEffectOp>>
}

// B-091: the boxed mut-cell typeid (must match RING_TYPEID_CELL in ring_runtime.cpp).
pub const RING_TYPEID_CELL: Int = 14

// B-084: the gen_lambda closure-env typeid (must match RING_TYPEID_CLOSURE_ENV in
// ring_runtime.cpp).  The env struct layout is { i64 count, ptr cap0, ... }; the
// runtime's drop_closure_env reads `count` and ring_drops each owned capture slot.
// Distinct from RING_TYPEID_CLOSURE (7, the {fn,env} pair) so drop_closure's
// ring_drop(env_ptr) dispatches to drop_closure_env, not back to drop_closure.
pub const RING_TYPEID_CLOSURE_ENV: Int = 15

// ============================================================
// LLVM name mangling
// ============================================================

pub fn llvm_mangle_fn(name: Str) -> Str {
    "ring_${name}"
}

// Module-qualified mangling: ring_<prefix>$_<name>
pub fn llvm_mangle_fn_with_prefix(prefix: Str, name: Str) -> Str {
    "ring_${prefix}$$_${name}"
}

pub fn llvm_mangle_method(type_name: Str, method_name: Str) -> Str {
    "ring_${type_name}_${method_name}"
}

// Resolve a function name through module context: check imports_map, then qualify with prefix
pub fn llvm_resolve_fn(ctx: LlvmCtx, name: Str) -> Str {
    // Check imports_map first (cross-module references)
    match ctx.imports_map.get(name) {
        some(qualified) => qualified,
        none => {
            // If we have a module prefix and this is a local name, qualify it
            match ctx.module_prefix {
                some(prefix) => {
                    if ctx.local_names.contains(name) {
                        llvm_mangle_fn_with_prefix(prefix, name)
                    } else {
                        llvm_mangle_fn(name)
                    }
                },
                none => llvm_mangle_fn(name),
            }
        },
    }
}

// Resolve a method name through module context
pub fn llvm_resolve_method(ctx: LlvmCtx, type_name: Str, method_name: Str) -> Str {
    // Methods use type_name which is usually globally unique
    llvm_mangle_method(type_name, method_name)
}

// ============================================================
// Fresh temporary name
// ============================================================

pub fn fresh_name(mut ctx: LlvmCtx, prefix: Str) -> Str {
    let n = ctx.tmp_counter
    ctx.tmp_counter = ctx.tmp_counter + 1
    "${prefix}${n}"
}

// ============================================================
// get_or_declare_runtime_fn — lazy declaration of runtime functions
// ============================================================

pub fn get_or_declare_runtime_fn(mut ctx: LlvmCtx, name: Str, param_types: List<LLVMTypeRef>, ret_type: LLVMTypeRef) -> LLVMValueRef {
    match ctx.rt_fns.get(name) {
        some(f) => f,
        none => {
            let fn_ty = LLVMFunctionType(ret_type, param_types, 0)
            let fn_val = LLVMAddFunction(ctx.module, name, fn_ty)
            ctx.rt_fns.insert(name, fn_val)
            ctx.rt_fn_types.insert(name, fn_ty)
            fn_val
        },
    }
}

pub fn get_rt_fn_type(ctx: LlvmCtx, name: Str) -> LLVMTypeRef {
    match ctx.rt_fn_types.get(name) {
        some(t) => t,
        none => panic("LLVM codegen: runtime function type not found: ${name}"),
    }
}

// ============================================================
// build_entry_alloca — place alloca in function's entry block
// ============================================================
// LLVM best practice: all allocas go in the entry block so they
// dominate all uses, preventing "instruction does not dominate
// all uses" verify errors when allocas would otherwise be inside
// loops, match arms, catch blocks, etc.

// ============================================================
// Perceus RC: typeid helpers
// ============================================================

// Assign (or retrieve existing) typeid for a user-defined type name.
pub fn get_or_assign_typeid(mut ctx: LlvmCtx, type_name: Str) -> Int {
    match ctx.type_to_typeid.get(type_name) {
        some(id) => id,
        none => {
            let id = ctx.next_user_typeid
            ctx.next_user_typeid = id + 1
            ctx.type_to_typeid.insert(type_name, id)
            id
        },
    }
}

// Return the built-in typeid constant for primitive / well-known types.
// Returns -1 for types that should use get_or_assign_typeid instead.
pub fn get_builtin_typeid(ty: Type) -> Int {
    match ty {
        Type::IntType => 0,        // RING_TYPEID_INT
        Type::FloatType => 1,      // RING_TYPEID_FLOAT
        Type::BoolType => 2,       // RING_TYPEID_BOOL
        Type::StrType => 3,        // RING_TYPEID_STR
        Type::UnitType => 9,       // RING_TYPEID_UNIT
        Type::TupleType { .. } => 10,  // RING_TYPEID_TUPLE
        Type::StructType { name, .. } => {
            if name == "List" { 4 }        // RING_TYPEID_LIST
            else if name == "Map" { 5 }    // RING_TYPEID_MAP
            else if name == "Set" { 6 }    // RING_TYPEID_SET
            else if name == "StringBuilder" { 13 }  // RING_TYPEID_SB
            else { -1 }  // user struct — use get_or_assign_typeid
        },
        Type::EnumType { name, .. } => {
            if name == "Option" { 8 }  // RING_TYPEID_OPTION
            else { -1 }  // user enum — use get_or_assign_typeid
        },
        Type::FnType { .. } => 7,  // RING_TYPEID_CLOSURE
        _ => -1,
    }
}

pub fn build_entry_alloca(mut ctx: LlvmCtx, ty: LLVMTypeRef, name: Str) -> LLVMValueRef {
    let current_bb = LLVMGetInsertBlock(ctx.builder)
    let fn_val = LLVMGetBasicBlockParent(current_bb)
    let entry_bb = LLVMGetEntryBasicBlock(fn_val)
    let first_instr = LLVMGetFirstInstruction(entry_bb)
    if LLVMIsNullPtr(first_instr) == 0 {
        LLVMPositionBuilderBefore(ctx.builder, first_instr)
    } else {
        LLVMPositionBuilderAtEnd(ctx.builder, entry_bb)
    }
    let alloca = LLVMBuildAlloca(ctx.builder, ty, name)
    LLVMPositionBuilderAtEnd(ctx.builder, current_bb)
    alloca
}
