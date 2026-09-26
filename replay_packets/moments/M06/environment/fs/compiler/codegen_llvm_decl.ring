use types::{Type, EffectRow}
use ast::{TypeParam}
use hir::{HExpr, HStmt, HDecl, HParam, HStructField, HEnumVariant,
    HTraitMethod, TraitBound, HEffectOp,
    evidence_param_name, trait_dict_name, trait_bound_param_name,
    hexpr_type, hexpr_effects}
use codegen_llvm_ctx::{LlvmCtx, StructFieldInfo, EnumTypeInfo, EnumVariantInfo,
    fresh_name, get_or_declare_runtime_fn, get_rt_fn_type,
    llvm_mangle_fn, llvm_mangle_fn_with_prefix, llvm_mangle_method,
    get_or_assign_typeid}
use codegen_llvm_expr::{gen_llvm_expr}
use codegen_ctx::{extract_effect_names}

// Re-declare LLVM types and functions to avoid ESM cross-module import issues
extern type LLVMContextRef
extern type LLVMModuleRef
extern type LLVMBuilderRef
extern type LLVMTypeRef
extern type LLVMValueRef
extern type LLVMBasicBlockRef

extern fn LLVMConstInt(ty: LLVMTypeRef, val: Int, sign_extend: Int) -> LLVMValueRef
extern fn LLVMConstPointerNull(ty: LLVMTypeRef) -> LLVMValueRef
extern fn LLVMGetParam(fn_val: LLVMValueRef, index: Int) -> LLVMValueRef
extern fn LLVMCountParams(fn_val: LLVMValueRef) -> Int
extern fn LLVMAppendBasicBlockInContext(ctx: LLVMContextRef, fn_val: LLVMValueRef, name: Str) -> LLVMBasicBlockRef
extern fn LLVMPositionBuilderAtEnd(builder: LLVMBuilderRef, bb: LLVMBasicBlockRef) -> Unit
extern fn LLVMGetInsertBlock(builder: LLVMBuilderRef) -> LLVMBasicBlockRef
extern fn LLVMBuildAlloca(builder: LLVMBuilderRef, ty: LLVMTypeRef, name: Str) -> LLVMValueRef
extern fn LLVMBuildStore(builder: LLVMBuilderRef, val: LLVMValueRef, ptr: LLVMValueRef) -> LLVMValueRef
extern fn LLVMBuildRet(builder: LLVMBuilderRef, val: LLVMValueRef) -> LLVMValueRef
extern fn LLVMBuildUnreachable(builder: LLVMBuilderRef) -> LLVMValueRef
extern fn LLVMBuildCall2(builder: LLVMBuilderRef, fn_ty: LLVMTypeRef, fn_val: LLVMValueRef, args: List<LLVMValueRef>, name: Str) -> LLVMValueRef
extern fn LLVMFunctionType(ret: LLVMTypeRef, params: List<LLVMTypeRef>, is_var_arg: Int) -> LLVMTypeRef
extern fn LLVMAddFunction(m: LLVMModuleRef, name: Str, fn_ty: LLVMTypeRef) -> LLVMValueRef
extern fn LLVMStructTypeInContext(ctx: LLVMContextRef, elems: List<LLVMTypeRef>, packed: Int) -> LLVMTypeRef
extern fn LLVMSizeOf(ty: LLVMTypeRef) -> LLVMValueRef
extern fn LLVMBuildStructGEP2(builder: LLVMBuilderRef, ty: LLVMTypeRef, ptr: LLVMValueRef, index: Int, name: Str) -> LLVMValueRef

// ============================================================
// Top-level declaration dispatch
// ============================================================

pub fn emit_llvm_decl(mut ctx: LlvmCtx, decl: HDecl) {
    match decl {
        HDecl::Fn { name, params, effects, body, trait_bounds, .. } => {
            emit_fn_body(ctx, name, params, effects, body, trait_bounds, none)
        },
        HDecl::Struct { name, fields, .. } => {
            // Struct type already registered in forward_declare pass
            // Generate constructor function
            emit_struct_constructor(ctx, name, fields)
        },
        HDecl::Enum { name, variants, .. } => {
            // Enum type already registered in forward_declare pass
            // Generate variant constructors
            emit_enum_constructors(ctx, name, variants)
        },
        HDecl::Impl { target_type, trait_name, methods, .. } => {
            for method in methods {
                match method {
                    HDecl::Fn { name: mn, params: mp, effects: me, body: mb, trait_bounds: mtb, .. } => {
                        emit_fn_body(ctx, mn, mp, me, mb, mtb, some(target_type))
                    },
                    _ => {},
                }
            }
            // Generate trait dictionary if this is a trait impl
            match trait_name {
                some(tn) => emit_trait_dict(ctx, target_type, tn, methods),
                none => {},
            }
        },
        HDecl::Effect { .. } => {
            // Effect declarations don't generate code directly
        },
        HDecl::Test { .. } => {
            // Tests not compiled in LLVM mode
        },
        HDecl::Trait { .. } => {
            // Trait declarations don't generate code directly (dict handled elsewhere)
        },
        HDecl::ExternFn { .. } => {
            // Extern functions are already handled as runtime declarations
        },
        HDecl::ExternType { .. } => {},
        HDecl::TypeAlias { .. } => {},
        HDecl::Const { name, init, .. } => {
            // Generate const as a zero-arg function that returns the init value
            emit_const_body(ctx, name, init)
        },
        HDecl::ModBlock { decls: mod_decls, .. } => {
            for subdecl in mod_decls {
                emit_llvm_decl(ctx, subdecl)
            }
        },
        HDecl::Sig { .. } => {},
    }
}

// ============================================================
// Function body emission
// ============================================================

fn emit_fn_body(mut ctx: LlvmCtx, name: Str, params: List<HParam>, effects: EffectRow, body: HExpr, trait_bounds: List<TraitBound>, impl_type: Str?) {
    let mangled = match impl_type {
        some(t) => llvm_mangle_method(t, name),
        none => {
            // Use module prefix if set
            match ctx.module_prefix {
                some(prefix) => llvm_mangle_fn_with_prefix(prefix, name),
                none => llvm_mangle_fn(name),
            }
        },
    }

    let fn_val = match ctx.functions.get(mangled) {
        some(f) => f,
        none => {
            panic("LLVM codegen: function '${mangled}' not forward-declared")
        },
    }

    // Save and set current function
    let saved_fn = ctx.current_fn
    ctx.current_fn = some(fn_val)
    let saved_fn_name = ctx.current_fn_name
    ctx.current_fn_name = mangled

    // Save current named_values
    let saved_named = ctx.named_values
    ctx.named_values = map_new()

    // Create entry basic block
    let entry = LLVMAppendBasicBlockInContext(ctx.context, fn_val, "entry")
    LLVMPositionBuilderAtEnd(ctx.builder, entry)

    // Map parameters to allocas
    let mut param_idx = 0
    for p in params {
        let alloca = LLVMBuildAlloca(ctx.builder, ctx.ptr_type, p.name)
        LLVMBuildStore(ctx.builder, LLVMGetParam(fn_val, param_idx), alloca)
        ctx.named_values.insert(p.name, alloca)
        param_idx = param_idx + 1
    }

    // Map trait bound dict params
    for b in trait_bounds {
        let dict_name = trait_bound_param_name(b.type_param, b.trait_name)
        let alloca = LLVMBuildAlloca(ctx.builder, ctx.ptr_type, dict_name)
        LLVMBuildStore(ctx.builder, LLVMGetParam(fn_val, param_idx), alloca)
        ctx.named_values.insert(dict_name, alloca)
        param_idx = param_idx + 1
    }

    // Map evidence params
    let effective_effects = match ctx.local_fn_effects.get(name) {
        some(eff) => eff,
        none => effects,
    }
    let ev_names = extract_effect_names(effective_effects)
    for en in ev_names {
        let ep_name = evidence_param_name(en)
        let alloca = LLVMBuildAlloca(ctx.builder, ctx.ptr_type, ep_name)
        LLVMBuildStore(ctx.builder, LLVMGetParam(fn_val, param_idx), alloca)
        ctx.named_values.insert(ep_name, alloca)
        param_idx = param_idx + 1
    }

    // Generate body
    let body_val = gen_llvm_expr(ctx, body)

    // Return the body value
    LLVMBuildRet(ctx.builder, body_val)

    // Restore state
    ctx.named_values = saved_named
    ctx.current_fn = saved_fn
    ctx.current_fn_name = saved_fn_name
}

// ============================================================
// Const body emission (emits as zero-arg getter function)
// ============================================================

fn emit_const_body(mut ctx: LlvmCtx, name: Str, init: HExpr) {
    let const_fn_name = match ctx.module_prefix {
        some(prefix) => llvm_mangle_fn_with_prefix(prefix, name),
        none => llvm_mangle_fn(name),
    }

    match ctx.functions.get(const_fn_name) {
        some(fn_val) => {
            let saved_fn = ctx.current_fn
            ctx.current_fn = some(fn_val)

            let saved_named = ctx.named_values
            ctx.named_values = map_new()

            let entry = LLVMAppendBasicBlockInContext(ctx.context, fn_val, "entry")
            LLVMPositionBuilderAtEnd(ctx.builder, entry)

            let val = gen_llvm_expr(ctx, init)
            LLVMBuildRet(ctx.builder, val)

            ctx.named_values = saved_named
            ctx.current_fn = saved_fn
        },
        none => {
            // Not forward-declared, skip
        },
    }
}

// ============================================================
// Struct info registration + constructor generation
// ============================================================

pub fn register_struct_info(mut ctx: LlvmCtx, name: Str, fields: List<HStructField>) {
    let mut field_names: List<Str> = []
    let mut field_types: List<LLVMTypeRef> = []
    for f in fields {
        field_names.push(f.name)
        field_types.push(ctx.ptr_type)
    }
    let struct_ty = LLVMStructTypeInContext(ctx.context, field_types, 0)
    ctx.struct_types.insert(name, StructFieldInfo {
        field_names: field_names,
        llvm_type: struct_ty
    })
}

fn emit_struct_constructor(mut ctx: LlvmCtx, name: Str, fields: List<HStructField>) {
    // Constructor function: ring_<Name>(field1, field2, ...) -> ptr
    let ctor_name = llvm_mangle_fn(name)

    // Check if already declared (it should not be, constructors are separate)
    match ctx.functions.get(ctor_name) {
        some(_) => {
            // Already exists — this can happen if a fn has the same name as the struct
            return
        },
        none => {},
    }

    let mut param_types: List<LLVMTypeRef> = []
    for f in fields {
        param_types.push(ctx.ptr_type)
    }
    let fn_ty = LLVMFunctionType(ctx.ptr_type, param_types, 0)
    let fn_val = LLVMAddFunction(ctx.module, ctor_name, fn_ty)
    ctx.functions.insert(ctor_name, fn_val)
    ctx.fn_types.insert(ctor_name, fn_ty)

    // Generate body
    let saved_fn = ctx.current_fn
    ctx.current_fn = some(fn_val)
    let entry = LLVMAppendBasicBlockInContext(ctx.context, fn_val, "entry")
    LLVMPositionBuilderAtEnd(ctx.builder, entry)

    let struct_info = match ctx.struct_types.get(name) {
        some(info) => info,
        none => panic("LLVM codegen: struct '${name}' not registered"),
    }

    // Allocate struct via ring_alloc with typeid
    let size = LLVMSizeOf(struct_info.llvm_type)
    let alloc_fn = get_or_declare_runtime_fn(ctx, "ring_alloc", [ctx.i64_type, ctx.i64_type], ctx.ptr_type)
    let alloc_ty = get_rt_fn_type(ctx, "ring_alloc")
    let typeid_val = LLVMConstInt(ctx.i64_type, get_or_assign_typeid(ctx, name), 0)
    let struct_ptr = LLVMBuildCall2(ctx.builder, alloc_ty, alloc_fn, [size, typeid_val], "s")

    // Store each field
    for i in 0..fields.len() {
        let param_val = LLVMGetParam(fn_val, i)
        let field_ptr = LLVMBuildStructGEP2(ctx.builder, struct_info.llvm_type, struct_ptr, i, "fp")
        LLVMBuildStore(ctx.builder, param_val, field_ptr)
    }

    LLVMBuildRet(ctx.builder, struct_ptr)
    ctx.current_fn = saved_fn
}

// ============================================================
// Enum info registration + variant constructor generation
// ============================================================

pub fn register_enum_info(mut ctx: LlvmCtx, name: Str, variants: List<HEnumVariant>) {
    let mut max_fields = 0
    let mut variant_map: Map<Str, EnumVariantInfo> = map_new()
    let mut tag = 0

    for v in variants {
        let fc = v.fields.len()
        if fc > max_fields {
            max_fields = fc
        }
        let fnames = match v.field_names {
            some(names) => names,
            none => {
                let mut ns: List<Str> = []
                for j in 0..fc { ns.push("") }
                ns
            },
        }
        variant_map.insert(v.name, EnumVariantInfo { tag: tag, field_count: fc, field_names: fnames })
        tag = tag + 1
    }

    // Enum type: { i64 tag, ptr field0, ptr field1, ... }
    let mut elem_types: List<LLVMTypeRef> = [ctx.i64_type]
    for i in 0..max_fields {
        elem_types.push(ctx.ptr_type)
    }
    let enum_ty = LLVMStructTypeInContext(ctx.context, elem_types, 0)

    ctx.enum_types.insert(name, EnumTypeInfo {
        variants: variant_map,
        max_fields: max_fields,
        llvm_type: enum_ty
    })
}

fn emit_enum_constructors(mut ctx: LlvmCtx, name: Str, variants: List<HEnumVariant>) {
    let enum_info = match ctx.enum_types.get(name) {
        some(info) => info,
        none => panic("LLVM codegen: enum '${name}' not registered"),
    }

    for v in variants {
        let ctor_name = "ring_${name}_${v.name}"
        let variant_info = match enum_info.variants.get(v.name) {
            some(vi) => vi,
            none => panic("LLVM codegen: variant '${v.name}' not found in enum '${name}'"),
        }

        // Reuse forward-declared function (declared in first pass)
        let fn_val = match ctx.functions.get(ctor_name) {
            some(fv) => fv,
            none => panic("LLVM codegen: enum ctor '${ctor_name}' not forward-declared"),
        }

        // Generate body
        let saved_fn = ctx.current_fn
        ctx.current_fn = some(fn_val)
        let entry = LLVMAppendBasicBlockInContext(ctx.context, fn_val, "entry")
        LLVMPositionBuilderAtEnd(ctx.builder, entry)

        // Allocate enum struct via ring_alloc with typeid
        let size = LLVMSizeOf(enum_info.llvm_type)
        let alloc_fn = get_or_declare_runtime_fn(ctx, "ring_alloc", [ctx.i64_type, ctx.i64_type], ctx.ptr_type)
        let alloc_ty = get_rt_fn_type(ctx, "ring_alloc")
        let enum_typeid_val = LLVMConstInt(ctx.i64_type, get_or_assign_typeid(ctx, name), 0)
        let enum_ptr = LLVMBuildCall2(ctx.builder, alloc_ty, alloc_fn, [size, enum_typeid_val], "e")

        // Store tag (field 0)
        let tag_val = LLVMConstInt(ctx.i64_type, variant_info.tag, 0)
        let tag_ptr = LLVMBuildStructGEP2(ctx.builder, enum_info.llvm_type, enum_ptr, 0, "tag")
        LLVMBuildStore(ctx.builder, tag_val, tag_ptr)

        // Store fields (starting at index 1)
        for i in 0..v.fields.len() {
            let param_val = LLVMGetParam(fn_val, i)
            let field_ptr = LLVMBuildStructGEP2(ctx.builder, enum_info.llvm_type, enum_ptr, i + 1, "ef")
            LLVMBuildStore(ctx.builder, param_val, field_ptr)
        }

        LLVMBuildRet(ctx.builder, enum_ptr)
        ctx.current_fn = saved_fn
    }
}

// ============================================================
// Trait dictionary generation
// ============================================================

fn emit_trait_dict(mut ctx: LlvmCtx, target_type: Str, trait_name: Str, methods: List<HDecl>) {
    // Build dict name following hir.ring convention: __Type_Trait
    let dict_name = trait_dict_name(target_type, trait_name)

    // Collect impl method names in order
    let mut impl_methods: List<Str> = []
    for m in methods {
        match m {
            HDecl::Fn { name, .. } => impl_methods.push(name),
            _ => {},
        }
    }

    // Get trait method order if available
    let method_order = match ctx.trait_method_order.get(trait_name) {
        some(order) => order,
        none => impl_methods,
    }

    let method_count = method_order.len()
    if method_count == 0 { return }

    // Generate a dict init function: ring_dict_init_<dictname>() -> ptr
    // This function allocates a dict struct and fills it with closure pointers
    let init_fn_name = "ring_dict_init_${dict_name}"
    let init_fn_ty = LLVMFunctionType(ctx.ptr_type, [], 0)
    let init_fn = LLVMAddFunction(ctx.module, init_fn_name, init_fn_ty)
    ctx.functions.insert(init_fn_name, init_fn)
    ctx.fn_types.insert(init_fn_name, init_fn_ty)

    let saved_fn = ctx.current_fn
    ctx.current_fn = some(init_fn)
    let entry = LLVMAppendBasicBlockInContext(ctx.context, init_fn, "entry")
    LLVMPositionBuilderAtEnd(ctx.builder, entry)

    // Dict struct type: one ptr per method (each is a RingClosure)
    let mut dict_elem_types: List<LLVMTypeRef> = []
    for i in 0..method_count {
        dict_elem_types.push(ctx.ptr_type)
    }
    let dict_struct_ty = LLVMStructTypeInContext(ctx.context, dict_elem_types, 0)

    // Allocate dict via ring_alloc (use TUPLE typeid for trait dicts)
    let dict_size = LLVMSizeOf(dict_struct_ty)
    let alloc_fn = get_or_declare_runtime_fn(ctx, "ring_alloc", [ctx.i64_type, ctx.i64_type], ctx.ptr_type)
    let alloc_ty = get_rt_fn_type(ctx, "ring_alloc")
    let dict_typeid = LLVMConstInt(ctx.i64_type, 10, 0)  // RING_TYPEID_TUPLE
    let dict_ptr = LLVMBuildCall2(ctx.builder, alloc_ty, alloc_fn, [dict_size, dict_typeid], "dict")

    // Closure struct type: { fn_ptr, env_ptr }
    let closure_ty = LLVMStructTypeInContext(ctx.context, [ctx.ptr_type, ctx.ptr_type], 0)
    let closure_size = LLVMSizeOf(closure_ty)

    // For each method in the trait, find the corresponding impl method and create a closure
    for i in 0..method_count {
        match method_order.get(i) {
            some(method_name) => {
                emit_dict_method_slot(ctx, target_type, method_name, dict_struct_ty, dict_ptr, closure_ty, closure_size, alloc_fn, alloc_ty, i)
            },
            none => {},
        }
    }

    LLVMBuildRet(ctx.builder, dict_ptr)
    ctx.current_fn = saved_fn

    // Register the dict init function so it can be found by resolve_dict_ref
    ctx.dict_globals.insert(dict_name, init_fn)
}

fn emit_dict_method_slot(mut ctx: LlvmCtx, target_type: Str, method_name: Str, dict_struct_ty: LLVMTypeRef, dict_ptr: LLVMValueRef, closure_ty: LLVMTypeRef, closure_size: LLVMValueRef, alloc_fn: LLVMValueRef, alloc_ty: LLVMTypeRef, slot_idx: Int) {
    let mangled = llvm_mangle_method(target_type, method_name)
    let closure_typeid = LLVMConstInt(ctx.i64_type, 7, 0)  // RING_TYPEID_CLOSURE
    match ctx.functions.get(mangled) {
        some(method_fn) => {
            // The dict slot must conform to the uniform closure ABI: a RingClosure
            // { fn_ptr, env_ptr } whose fn_ptr is called as fn(env, args...). But the
            // impl method `ring_<Type>_<method>` is generated with the *direct* ABI
            // fn(self, args...) — it has no leading env parameter. Storing the bare
            // method fn here makes gen_closure_call pass env (=null) as the receiver,
            // corrupting `self` (B-092: crashes in str_from_cstr on self.<field>).
            // Emit a thin env-first thunk that drops env and forwards to the method,
            // mirroring the runtime's ring_cl_eq_str(env, a, b) wrappers.
            let thunk_fn = emit_dict_method_thunk(ctx, mangled, method_fn)

            // Create a closure: { thunk_fn, null_env }
            let closure_ptr = LLVMBuildCall2(ctx.builder, alloc_ty, alloc_fn, [closure_size, closure_typeid], fresh_name(ctx, "cls"))
            let fn_slot = LLVMBuildStructGEP2(ctx.builder, closure_ty, closure_ptr, 0, fresh_name(ctx, "fps"))
            LLVMBuildStore(ctx.builder, thunk_fn, fn_slot)
            let env_slot = LLVMBuildStructGEP2(ctx.builder, closure_ty, closure_ptr, 1, fresh_name(ctx, "eps"))
            LLVMBuildStore(ctx.builder, LLVMConstPointerNull(ctx.ptr_type), env_slot)

            // Store closure in dict slot
            let slot_ptr = LLVMBuildStructGEP2(ctx.builder, dict_struct_ty, dict_ptr, slot_idx, fresh_name(ctx, "ds"))
            LLVMBuildStore(ctx.builder, closure_ptr, slot_ptr)
        },
        none => {
            // Method not found — store null closure
            let slot_ptr = LLVMBuildStructGEP2(ctx.builder, dict_struct_ty, dict_ptr, slot_idx, fresh_name(ctx, "ds"))
            LLVMBuildStore(ctx.builder, LLVMConstPointerNull(ctx.ptr_type), slot_ptr)
        },
    }
}

// Emit (once) an env-first thunk wrapping a direct-ABI impl method, so it can be
// stored in a trait dict and invoked through the uniform closure ABI fn(env, args...).
// The thunk has type (env, p0, ..., p_{n-1}) -> ptr where n is the method's param
// count; it ignores env and tail-forwards (p0, ..., p_{n-1}) to the method.
fn emit_dict_method_thunk(mut ctx: LlvmCtx, mangled: Str, method_fn: LLVMValueRef) -> LLVMValueRef {
    let thunk_name = "${mangled}__dictthunk"
    // Reuse if already emitted (one impl method may seed multiple dict inits).
    match ctx.functions.get(thunk_name) {
        some(existing) => { return existing },
        none => {},
    }

    let method_arity = LLVMCountParams(method_fn)

    // Thunk param types: leading env ptr + one ptr per method param.
    let mut thunk_param_types: List<LLVMTypeRef> = [ctx.ptr_type]
    for i in 0..method_arity {
        thunk_param_types.push(ctx.ptr_type)
    }
    let thunk_ty = LLVMFunctionType(ctx.ptr_type, thunk_param_types, 0)
    let thunk_fn = LLVMAddFunction(ctx.module, thunk_name, thunk_ty)
    ctx.functions.insert(thunk_name, thunk_fn)
    ctx.fn_types.insert(thunk_name, thunk_ty)

    // Method fn type: (p0, ..., p_{n-1}) -> ptr.
    let method_ty = match ctx.fn_types.get(mangled) {
        some(t) => t,
        none => {
            let mut method_param_types: List<LLVMTypeRef> = []
            for i in 0..method_arity {
                method_param_types.push(ctx.ptr_type)
            }
            LLVMFunctionType(ctx.ptr_type, method_param_types, 0)
        },
    }

    // Emit the thunk body in its own block, then restore the builder position so the
    // surrounding dict-init emission continues uninterrupted.
    let saved_block = LLVMGetInsertBlock(ctx.builder)
    let entry = LLVMAppendBasicBlockInContext(ctx.context, thunk_fn, "entry")
    LLVMPositionBuilderAtEnd(ctx.builder, entry)

    // Forward thunk params 1..arity (skip param 0 = env) to the method.
    let mut fwd_args: List<LLVMValueRef> = []
    for i in 0..method_arity {
        fwd_args.push(LLVMGetParam(thunk_fn, i + 1))
    }
    let call_res = LLVMBuildCall2(ctx.builder, method_ty, method_fn, fwd_args, fresh_name(ctx, "tk"))
    LLVMBuildRet(ctx.builder, call_res)

    LLVMPositionBuilderAtEnd(ctx.builder, saved_block)
    thunk_fn
}
