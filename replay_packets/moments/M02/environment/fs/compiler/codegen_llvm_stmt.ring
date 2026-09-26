use types::{Type, BUILTIN_RANGE}
use ast::{Pattern, LiteralValue}
use hir::{HExpr, HStmt, HLetDestructureBinding, HForInDestructure, hexpr_type}
use codegen_llvm_ctx::{LlvmCtx, fresh_name, get_or_declare_runtime_fn, get_rt_fn_type, build_entry_alloca}

// Re-declare LLVM types and functions to avoid ESM import issues
extern type LLVMTypeRef
extern type LLVMValueRef
extern type LLVMBasicBlockRef
extern type LLVMContextRef
extern type LLVMBuilderRef

extern fn LLVMBuildAlloca(builder: LLVMBuilderRef, ty: LLVMTypeRef, name: Str) -> LLVMValueRef
extern fn LLVMBuildLoad2(builder: LLVMBuilderRef, ty: LLVMTypeRef, ptr: LLVMValueRef, name: Str) -> LLVMValueRef
extern fn LLVMBuildStore(builder: LLVMBuilderRef, val: LLVMValueRef, ptr: LLVMValueRef) -> LLVMValueRef
extern fn LLVMBuildBr(builder: LLVMBuilderRef, dest: LLVMBasicBlockRef) -> LLVMValueRef
extern fn LLVMBuildRet(builder: LLVMBuilderRef, val: LLVMValueRef) -> LLVMValueRef
extern fn LLVMAppendBasicBlockInContext(ctx: LLVMContextRef, fn_val: LLVMValueRef, name: Str) -> LLVMBasicBlockRef
extern fn LLVMPositionBuilderAtEnd(builder: LLVMBuilderRef, bb: LLVMBasicBlockRef) -> Unit
extern fn LLVMGetInsertBlock(builder: LLVMBuilderRef) -> LLVMBasicBlockRef
extern fn LLVMBuildCondBr(builder: LLVMBuilderRef, cond: LLVMValueRef, then_bb: LLVMBasicBlockRef, else_bb: LLVMBasicBlockRef) -> LLVMValueRef
extern fn LLVMConstPointerNull(ty: LLVMTypeRef) -> LLVMValueRef
extern fn LLVMBuildStructGEP2(builder: LLVMBuilderRef, ty: LLVMTypeRef, ptr: LLVMValueRef, index: Int, name: Str) -> LLVMValueRef
extern fn LLVMConstInt(ty: LLVMTypeRef, val: Int, sign_extend: Int) -> LLVMValueRef
extern fn LLVMBuildAdd(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
extern fn LLVMBuildSub(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
extern fn LLVMStructTypeInContext(ctx: LLVMContextRef, elems: List<LLVMTypeRef>, packed: Int) -> LLVMTypeRef
extern fn LLVMBuildICmp(builder: LLVMBuilderRef, predicate: Int, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
extern fn LLVMBuildCall2(builder: LLVMBuilderRef, fn_ty: LLVMTypeRef, fn_val: LLVMValueRef, args: List<LLVMValueRef>, name: Str) -> LLVMValueRef
extern fn LLVMBuildPhi(builder: LLVMBuilderRef, ty: LLVMTypeRef, name: Str) -> LLVMValueRef
extern fn LLVMAddIncoming(phi: LLVMValueRef, vals: List<LLVMValueRef>, blocks: List<LLVMBasicBlockRef>) -> Unit
extern fn LLVMBuildTrunc(builder: LLVMBuilderRef, val: LLVMValueRef, dest_ty: LLVMTypeRef, name: Str) -> LLVMValueRef

// Forward declaration to break circular dependency with codegen_llvm_expr
extern fn gen_llvm_expr(mut ctx: LlvmCtx, expr: HExpr) -> LLVMValueRef
extern fn unbox_to_i1(mut ctx: LlvmCtx, val: LLVMValueRef) -> LLVMValueRef
extern fn box_int(mut ctx: LlvmCtx, raw: LLVMValueRef) -> LLVMValueRef
extern fn box_bool(mut ctx: LlvmCtx, raw: LLVMValueRef) -> LLVMValueRef
// B-091: boxed mut-cell helpers (defined in codegen_llvm_expr).
extern fn is_boxed_def(ctx: LlvmCtx, def_id: Int?) -> Bool
extern fn build_cell_alloc(mut ctx: LlvmCtx, init_val: LLVMValueRef) -> LLVMValueRef
extern fn build_cell_store(mut ctx: LlvmCtx, cell_ptr: LLVMValueRef, new_val: LLVMValueRef) -> Unit

// Discard an LLVMValueRef (to avoid type mismatch in Unit-returning match arms)
fn discard(v: LLVMValueRef) {
    // intentionally empty — just consume the value
}

// ============================================================
// Statement dispatch
// ============================================================

pub fn emit_llvm_stmt(mut ctx: LlvmCtx, stmt: HStmt) {
    match stmt {
        HStmt::Let { name, init, .. } => {
            let val = gen_llvm_expr(ctx, init)
            let alloca = build_entry_alloca(ctx, ctx.ptr_type, name)
            discard(LLVMBuildStore(ctx.builder, val, alloca))
            ctx.named_values.insert(name, alloca)
        },
        HStmt::Var { name, def_id, init, .. } => {
            let val = gen_llvm_expr(ctx, init)
            // B-091: if this `let mut` is captured-and-written by a closure it was
            // auto-boxed (def_id ∈ boxed_vars).  Box the init into a shared heap
            // cell; the alloca then holds the cell pointer, so reads/writes route
            // through `cell.value` and closures capture the same cell.
            let stored = if is_boxed_def(ctx, def_id) { build_cell_alloc(ctx, val) } else { val }
            let alloca = build_entry_alloca(ctx, ctx.ptr_type, name)
            discard(LLVMBuildStore(ctx.builder, stored, alloca))
            ctx.named_values.insert(name, alloca)
        },
        HStmt::Assign { target, value, .. } => {
            emit_assign(ctx, target, value)
        },
        HStmt::ExprStmt { expr, .. } => {
            discard(gen_llvm_expr(ctx, expr))
        },
        HStmt::Return { value, .. } => {
            emit_return(ctx, value)
        },
        HStmt::While { condition, body, .. } => {
            emit_while(ctx, condition, body)
        },
        HStmt::ForIn { binding, destructure, iterable, body, iterable_type_name, iter_type_name, .. } => {
            emit_for_in(ctx, binding, destructure, iterable, body, iterable_type_name, iter_type_name)
        },
        HStmt::Break { .. } => {
            emit_break(ctx)
        },
        HStmt::Continue { .. } => {
            emit_continue(ctx)
        },
        HStmt::LetDestructure { pattern, bindings, init, .. } => {
            emit_let_destructure(ctx, bindings, init)
        },
        HStmt::IfLet { pattern, expr, then_block, else_block, .. } => {
            emit_if_let(ctx, pattern, expr, then_block, else_block)
        },
        // Perceus L0 — emit ring_drop / ring_dup
        HStmt::Drop { name, .. } => {
            match ctx.named_values.get(name) {
                some(var_ptr) => {
                    let val = LLVMBuildLoad2(ctx.builder, ctx.ptr_type, var_ptr, fresh_name(ctx, "drop_val"))
                    let drop_fn = get_or_declare_runtime_fn(ctx, "ring_drop", [ctx.ptr_type], ctx.void_type)
                    let drop_ty = get_rt_fn_type(ctx, "ring_drop")
                    discard(LLVMBuildCall2(ctx.builder, drop_ty, drop_fn, [val], ""))
                },
                none => {
                    eprintln("[rc-warn] Drop: variable '${name}' not found in named_values")
                },
            }
        },
        HStmt::Dup { name, .. } => {
            match ctx.named_values.get(name) {
                some(var_ptr) => {
                    let val = LLVMBuildLoad2(ctx.builder, ctx.ptr_type, var_ptr, fresh_name(ctx, "dup_val"))
                    let dup_fn = get_or_declare_runtime_fn(ctx, "ring_dup", [ctx.ptr_type], ctx.void_type)
                    let dup_ty = get_rt_fn_type(ctx, "ring_dup")
                    discard(LLVMBuildCall2(ctx.builder, dup_ty, dup_fn, [val], ""))
                },
                none => {
                    eprintln("[rc-warn] Dup: variable '${name}' not found in named_values")
                },
            }
        },
    }
}

fn emit_assign(mut ctx: LlvmCtx, target: HExpr, value: HExpr) {
    let val = gen_llvm_expr(ctx, value)
    match target {
        HExpr::Ident { name, resolved_name, def_id, .. } => {
            let lookup = match resolved_name {
                some(rn) => rn,
                none => name,
            }
            // B-091: a write to a boxed mut-cell stores into `cell.value` (the
            // alloca holds the shared cell pointer), so the write is observed by
            // the outer scope and the capturing closure alike.  A plain mut var
            // overwrites the alloca slot as before.
            let boxed = is_boxed_def(ctx, def_id)
            match ctx.named_values.get(lookup) {
                some(alloca) => {
                    if boxed {
                        let cell_ptr = LLVMBuildLoad2(ctx.builder, ctx.ptr_type, alloca, fresh_name(ctx, "cellp"))
                        build_cell_store(ctx, cell_ptr, val)
                    } else {
                        discard(LLVMBuildStore(ctx.builder, val, alloca))
                    }
                },
                none => {
                    match ctx.named_values.get(name) {
                        some(alloca) => {
                            if boxed {
                                let cell_ptr = LLVMBuildLoad2(ctx.builder, ctx.ptr_type, alloca, fresh_name(ctx, "cellp"))
                                build_cell_store(ctx, cell_ptr, val)
                            } else {
                                discard(LLVMBuildStore(ctx.builder, val, alloca))
                            }
                        },
                        none => panic("LLVM codegen: assign to undefined variable '${name}'"),
                    }
                },
            }
        },
        HExpr::FieldAccess { receiver, field, .. } => {
            let recv_val = gen_llvm_expr(ctx, receiver)
            let recv_type = hexpr_type(receiver)
            let type_name = match recv_type {
                Type::StructType { name, .. } => name,
                _ => panic("LLVM codegen: field assign on non-struct type"),
            }
            match ctx.struct_types.get(type_name) {
                some(info) => {
                    let mut field_idx = -1
                    for i in 0..info.field_names.len() {
                        if info.field_names[i] == field {
                            field_idx = i
                        }
                    }
                    if field_idx < 0 {
                        panic("LLVM codegen: field '${field}' not found in struct '${type_name}'")
                    }
                    let field_ptr = LLVMBuildStructGEP2(ctx.builder, info.llvm_type, recv_val, field_idx, fresh_name(ctx, "fp"))
                    discard(LLVMBuildStore(ctx.builder, val, field_ptr))
                },
                none => panic("LLVM codegen: struct type '${type_name}' not registered"),
            }
        },
        _ => panic("LLVM codegen: unsupported assignment target"),
    }
}

fn emit_return(mut ctx: LlvmCtx, value: HExpr?) {
    match value {
        some(v) => {
            let val = gen_llvm_expr(ctx, v)
            discard(LLVMBuildRet(ctx.builder, val))
        },
        none => {
            let null = LLVMConstPointerNull(ctx.ptr_type)
            discard(LLVMBuildRet(ctx.builder, null))
        },
    }
    // Create a dead block after return so subsequent code doesn't pollute the terminated block
    match ctx.current_fn {
        some(f) => {
            let dead_bb = LLVMAppendBasicBlockInContext(ctx.context, f, "after.ret")
            LLVMPositionBuilderAtEnd(ctx.builder, dead_bb)
        },
        none => {},
    }
}

fn emit_while(mut ctx: LlvmCtx, condition: HExpr, body: HExpr) {
    let current_fn = match ctx.current_fn {
        some(f) => f,
        none => panic("LLVM codegen: while outside function"),
    }
    let cond_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "while.cond")
    let body_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "while.body")
    let merge_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "while.merge")

    discard(LLVMBuildBr(ctx.builder, cond_bb))

    LLVMPositionBuilderAtEnd(ctx.builder, cond_bb)
    let cond_val = gen_llvm_expr(ctx, condition)
    let cond_i1 = unbox_to_i1(ctx, cond_val)
    discard(LLVMBuildCondBr(ctx.builder, cond_i1, body_bb, merge_bb))

    // Save and set loop context for break/continue
    let saved_break = ctx.loop_break_bb
    let saved_continue = ctx.loop_continue_bb
    ctx.loop_break_bb = some(merge_bb)
    ctx.loop_continue_bb = some(cond_bb)

    LLVMPositionBuilderAtEnd(ctx.builder, body_bb)
    discard(gen_llvm_expr(ctx, body))
    discard(LLVMBuildBr(ctx.builder, cond_bb))

    // Restore loop context
    ctx.loop_break_bb = saved_break
    ctx.loop_continue_bb = saved_continue

    LLVMPositionBuilderAtEnd(ctx.builder, merge_bb)
}

// ============================================================
// ForIn statement
// ============================================================

fn emit_for_in(mut ctx: LlvmCtx, binding: Str, destructure: List<HForInDestructure>?, iterable: HExpr, body: HExpr, iterable_type_name: Str?, iter_type_name: Str?) {
    let current_fn = match ctx.current_fn {
        some(f) => f,
        none => panic("LLVM codegen: for-in outside function"),
    }

    // Check if iterable is a RangeExpr
    match iterable {
        HExpr::RangeExpr { start, end, inclusive, .. } => {
            emit_for_in_range_direct(ctx, binding, start, end, inclusive, body)
            return
        },
        _ => {},
    }

    // Check if iterable has Range type
    let iter_htype = hexpr_type(iterable)
    let is_range = match iter_htype {
        Type::EnumType { name, .. } => name == BUILTIN_RANGE,
        _ => false,
    }

    if is_range {
        emit_for_in_range_var(ctx, binding, iterable, body)
    } else {
        // Default: for List, use index-based while loop
        emit_for_in_list(ctx, binding, destructure, iterable, body)
    }
}

// for x in start..end { body }
// Drop the per-iteration boxed loop counter of a range for-loop (B-104b).  The
// counter is a FRESH box_int each round (emit_for_in_range_direct/_var), NOT a
// borrowed container element — but perceus treats every for-binding as a borrow
// and never drops it, so without this every iteration leaks one Int box (P0 diag:
// 97% of residual native INT lived in exhaustive.ring's range loops via this path).
// Emitted at the top of the increment block, which BOTH normal fall-through and
// `continue` pass through (loop_continue_bb = incr_bb).  Sound: body escapes of the
// counter are dup'd by perceus's clone-all-escape, so this single drop balances the
// box_int (+1).  Residual: a `break`/`return` mid-iteration still leaks the current
// box — bounded O(loop-runs), not O(iterations); the hot range loops run to
// completion so this is negligible for the G-a wall.
fn emit_drop_value(mut ctx: LlvmCtx, val: LLVMValueRef) {
    let drop_fn = get_or_declare_runtime_fn(ctx, "ring_drop", [ctx.ptr_type], ctx.void_type)
    let drop_ty = get_rt_fn_type(ctx, "ring_drop")
    discard(LLVMBuildCall2(ctx.builder, drop_ty, drop_fn, [val], ""))
}

fn emit_range_counter_drop(mut ctx: LlvmCtx, binding_alloca: LLVMValueRef) {
    let iter_box = LLVMBuildLoad2(ctx.builder, ctx.ptr_type, binding_alloca, fresh_name(ctx, "ibx"))
    emit_drop_value(ctx, iter_box)
}

fn emit_for_in_range_direct(mut ctx: LlvmCtx, binding: Str, start: HExpr, end: HExpr, inclusive: Bool, body: HExpr) {
    let current_fn = match ctx.current_fn {
        some(f) => f,
        none => panic("LLVM codegen: for-in range outside function"),
    }

    let start_val = gen_llvm_expr(ctx, start)
    let end_val = gen_llvm_expr(ctx, end)

    // Unbox start and end to i64
    let unbox_fn = get_or_declare_runtime_fn(ctx, "ring_unbox_int", [ctx.ptr_type], ctx.i64_type)
    let unbox_ty = get_rt_fn_type(ctx, "ring_unbox_int")
    let start_raw = LLVMBuildCall2(ctx.builder, unbox_ty, unbox_fn, [start_val], fresh_name(ctx, "si"))
    let end_raw = LLVMBuildCall2(ctx.builder, unbox_ty, unbox_fn, [end_val], fresh_name(ctx, "ei"))

    // B-104b: start_val/end_val are OWNED boxes — perceus rc_expr(RangeExpr) always
    // rc_escapes the bounds (fresh literal/call boxes stay owned; Ident/field/index
    // bounds become HExpr::Clone → ring_dup, a +1 reference owned here).  They are
    // CONSUMED by the unbox above (only the i64 start_raw/end_raw feed the loop), so
    // drop them now; without this every loop ENTRY leaks 2 Int boxes (P0 re-measure:
    // the dominant residual INT after the counter fix — O(loop-entries) in
    // exhaustive.ring's recursive check_matrix/specialize_row, `for i in 1..xs.len()`
    // boxing the `1` and the `.len()` result).  Sound for Clone'd Ident bounds:
    // dropping the dup (rc 2→1) leaves the source variable's own reference intact.
    emit_drop_value(ctx, start_val)
    emit_drop_value(ctx, end_val)

    // Alloca for loop counter
    let counter_alloca = build_entry_alloca(ctx, ctx.i64_type, fresh_name(ctx, "i"))
    discard(LLVMBuildStore(ctx.builder, start_raw, counter_alloca))

    let cond_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "for.cond")
    let body_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "for.body")
    let incr_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "for.incr")
    let merge_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "for.merge")

    discard(LLVMBuildBr(ctx.builder, cond_bb))

    // Condition: i < end (or i <= end if inclusive)
    LLVMPositionBuilderAtEnd(ctx.builder, cond_bb)
    let current_i = LLVMBuildLoad2(ctx.builder, ctx.i64_type, counter_alloca, fresh_name(ctx, "ci"))
    // 40 = slt, 41 = sle
    let predicate = if inclusive { 41 } else { 40 }
    let cond = LLVMBuildICmp(ctx.builder, predicate, current_i, end_raw, fresh_name(ctx, "cmp"))
    discard(LLVMBuildCondBr(ctx.builder, cond, body_bb, merge_bb))

    // Save and set loop context
    let saved_break = ctx.loop_break_bb
    let saved_continue = ctx.loop_continue_bb
    ctx.loop_break_bb = some(merge_bb)
    ctx.loop_continue_bb = some(incr_bb)

    // Body: bind loop variable, execute body
    LLVMPositionBuilderAtEnd(ctx.builder, body_bb)
    let boxed_i = box_int(ctx, current_i)
    let binding_alloca = build_entry_alloca(ctx, ctx.ptr_type, binding)
    discard(LLVMBuildStore(ctx.builder, boxed_i, binding_alloca))
    ctx.named_values.insert(binding, binding_alloca)
    discard(gen_llvm_expr(ctx, body))
    discard(LLVMBuildBr(ctx.builder, incr_bb))

    // Increment
    LLVMPositionBuilderAtEnd(ctx.builder, incr_bb)
    emit_range_counter_drop(ctx, binding_alloca)
    let current_i2 = LLVMBuildLoad2(ctx.builder, ctx.i64_type, counter_alloca, fresh_name(ctx, "ci"))
    let one = LLVMConstInt(ctx.i64_type, 1, 0)
    let next_i = LLVMBuildAdd(ctx.builder, current_i2, one, fresh_name(ctx, "ni"))
    discard(LLVMBuildStore(ctx.builder, next_i, counter_alloca))
    discard(LLVMBuildBr(ctx.builder, cond_bb))

    // Restore loop context
    ctx.loop_break_bb = saved_break
    ctx.loop_continue_bb = saved_continue

    LLVMPositionBuilderAtEnd(ctx.builder, merge_bb)
}

// for x in range_var { body } — range stored in a variable.
// The range value is the struct gen_range_expr produces: { ptr start, ptr end,
// ptr inclusive } (typeid TUPLE), where start/end are boxed Ints and inclusive is a
// boxed Bool. We GEP each field, unbox start/end to i64 and inclusive to i64, then
// run the same counted loop as emit_for_in_range_direct. `inclusive` is a *runtime*
// value here, so instead of a compile-time predicate we fold it into the upper
// bound: end_bound = end - (1 - inclusive)  (== end when inclusive, end-1 otherwise)
// and always compare i <= end_bound. (#B-087 gap 4 — previously a stub that fell
// back to list iteration and called ring_list_len on the range struct → crash.)
fn emit_for_in_range_var(mut ctx: LlvmCtx, binding: Str, iterable: HExpr, body: HExpr) {
    let current_fn = match ctx.current_fn {
        some(f) => f,
        none => panic("LLVM codegen: for-in range var outside function"),
    }

    let range_val = gen_llvm_expr(ctx, iterable)
    // Range struct layout must match gen_range_expr: { ptr start, ptr end, ptr inclusive }.
    let range_struct_ty = LLVMStructTypeInContext(ctx.context, [ctx.ptr_type, ctx.ptr_type, ctx.ptr_type], 0)

    let start_slot = LLVMBuildStructGEP2(ctx.builder, range_struct_ty, range_val, 0, fresh_name(ctx, "rs"))
    let start_box = LLVMBuildLoad2(ctx.builder, ctx.ptr_type, start_slot, fresh_name(ctx, "sb"))
    let end_slot = LLVMBuildStructGEP2(ctx.builder, range_struct_ty, range_val, 1, fresh_name(ctx, "re"))
    let end_box = LLVMBuildLoad2(ctx.builder, ctx.ptr_type, end_slot, fresh_name(ctx, "eb"))
    let incl_slot = LLVMBuildStructGEP2(ctx.builder, range_struct_ty, range_val, 2, fresh_name(ctx, "ri"))
    let incl_box = LLVMBuildLoad2(ctx.builder, ctx.ptr_type, incl_slot, fresh_name(ctx, "ib"))

    let unbox_int_fn = get_or_declare_runtime_fn(ctx, "ring_unbox_int", [ctx.ptr_type], ctx.i64_type)
    let unbox_int_ty = get_rt_fn_type(ctx, "ring_unbox_int")
    let start_raw = LLVMBuildCall2(ctx.builder, unbox_int_ty, unbox_int_fn, [start_box], fresh_name(ctx, "si"))
    let end_raw = LLVMBuildCall2(ctx.builder, unbox_int_ty, unbox_int_fn, [end_box], fresh_name(ctx, "ei"))
    let unbox_bool_fn = get_or_declare_runtime_fn(ctx, "ring_unbox_bool", [ctx.ptr_type], ctx.i64_type)
    let unbox_bool_ty = get_rt_fn_type(ctx, "ring_unbox_bool")
    let incl_raw = LLVMBuildCall2(ctx.builder, unbox_bool_ty, unbox_bool_fn, [incl_box], fresh_name(ctx, "ic"))

    // end_bound = end_raw - (1 - incl_raw): when inclusive (incl=1) → end; else end-1.
    let one = LLVMConstInt(ctx.i64_type, 1, 0)
    let one_minus_incl = LLVMBuildSub(ctx.builder, one, incl_raw, fresh_name(ctx, "omi"))
    let end_bound = LLVMBuildSub(ctx.builder, end_raw, one_minus_incl, fresh_name(ctx, "eb2"))

    // Counter starts at start_raw; loop while i <= end_bound.
    let counter_alloca = build_entry_alloca(ctx, ctx.i64_type, fresh_name(ctx, "i"))
    discard(LLVMBuildStore(ctx.builder, start_raw, counter_alloca))

    let cond_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "forv.cond")
    let body_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "forv.body")
    let incr_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "forv.incr")
    let merge_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "forv.merge")

    discard(LLVMBuildBr(ctx.builder, cond_bb))

    LLVMPositionBuilderAtEnd(ctx.builder, cond_bb)
    let current_i = LLVMBuildLoad2(ctx.builder, ctx.i64_type, counter_alloca, fresh_name(ctx, "ci"))
    // 41 = sle
    let cond = LLVMBuildICmp(ctx.builder, 41, current_i, end_bound, fresh_name(ctx, "cmp"))
    discard(LLVMBuildCondBr(ctx.builder, cond, body_bb, merge_bb))

    let saved_break = ctx.loop_break_bb
    let saved_continue = ctx.loop_continue_bb
    ctx.loop_break_bb = some(merge_bb)
    ctx.loop_continue_bb = some(incr_bb)

    LLVMPositionBuilderAtEnd(ctx.builder, body_bb)
    let boxed_i = box_int(ctx, current_i)
    let binding_alloca = build_entry_alloca(ctx, ctx.ptr_type, binding)
    discard(LLVMBuildStore(ctx.builder, boxed_i, binding_alloca))
    ctx.named_values.insert(binding, binding_alloca)
    discard(gen_llvm_expr(ctx, body))
    discard(LLVMBuildBr(ctx.builder, incr_bb))

    LLVMPositionBuilderAtEnd(ctx.builder, incr_bb)
    emit_range_counter_drop(ctx, binding_alloca)
    let current_i2 = LLVMBuildLoad2(ctx.builder, ctx.i64_type, counter_alloca, fresh_name(ctx, "ci"))
    let next_i = LLVMBuildAdd(ctx.builder, current_i2, one, fresh_name(ctx, "ni"))
    discard(LLVMBuildStore(ctx.builder, next_i, counter_alloca))
    discard(LLVMBuildBr(ctx.builder, cond_bb))

    ctx.loop_break_bb = saved_break
    ctx.loop_continue_bb = saved_continue

    LLVMPositionBuilderAtEnd(ctx.builder, merge_bb)
}

// for x in list { body } — index-based while loop
fn emit_for_in_list(mut ctx: LlvmCtx, binding: Str, destructure: List<HForInDestructure>?, iterable: HExpr, body: HExpr) {
    let current_fn = match ctx.current_fn {
        some(f) => f,
        none => panic("LLVM codegen: for-in list outside function"),
    }

    let list_val_raw = gen_llvm_expr(ctx, iterable)

    // A Set is backed by a hash table, not a vector — convert it to a List before
    // index-based iteration. List iterables pass through unchanged.
    let list_val = match hexpr_type(iterable) {
        Type::StructType { name, type_params, .. } => {
            if name == "Set" {
                let is_int_elem = if type_params.len() > 0 {
                    match type_params[0] {
                        Type::IntType => true,
                        _ => false,
                    }
                } else { false }
                let conv_name = if is_int_elem { "ring_set_int_to_list" } else { "ring_set_to_list" }
                let conv_fn = get_or_declare_runtime_fn(ctx, conv_name, [ctx.ptr_type], ctx.ptr_type)
                let conv_ty = get_rt_fn_type(ctx, conv_name)
                LLVMBuildCall2(ctx.builder, conv_ty, conv_fn, [list_val_raw], fresh_name(ctx, "s2l"))
            } else {
                list_val_raw
            }
        },
        _ => list_val_raw,
    }

    // Get list length
    let len_fn = get_or_declare_runtime_fn(ctx, "ring_list_len", [ctx.ptr_type], ctx.i64_type)
    let len_ty = get_rt_fn_type(ctx, "ring_list_len")
    let list_len = LLVMBuildCall2(ctx.builder, len_ty, len_fn, [list_val], fresh_name(ctx, "len"))

    // Alloca for index counter
    let counter_alloca = build_entry_alloca(ctx, ctx.i64_type, fresh_name(ctx, "idx"))
    let zero = LLVMConstInt(ctx.i64_type, 0, 0)
    discard(LLVMBuildStore(ctx.builder, zero, counter_alloca))

    let cond_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "forl.cond")
    let body_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "forl.body")
    let incr_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "forl.incr")
    let merge_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "forl.merge")

    discard(LLVMBuildBr(ctx.builder, cond_bb))

    // Condition: idx < len
    LLVMPositionBuilderAtEnd(ctx.builder, cond_bb)
    let current_idx = LLVMBuildLoad2(ctx.builder, ctx.i64_type, counter_alloca, fresh_name(ctx, "ci"))
    let cond = LLVMBuildICmp(ctx.builder, 40, current_idx, list_len, fresh_name(ctx, "cmp"))
    discard(LLVMBuildCondBr(ctx.builder, cond, body_bb, merge_bb))

    // Save and set loop context
    let saved_break = ctx.loop_break_bb
    let saved_continue = ctx.loop_continue_bb
    ctx.loop_break_bb = some(merge_bb)
    ctx.loop_continue_bb = some(incr_bb)

    // Body
    LLVMPositionBuilderAtEnd(ctx.builder, body_bb)
    let get_fn = get_or_declare_runtime_fn(ctx, "ring_list_get", [ctx.ptr_type, ctx.i64_type], ctx.ptr_type)
    let get_ty = get_rt_fn_type(ctx, "ring_list_get")
    let elem = LLVMBuildCall2(ctx.builder, get_ty, get_fn, [list_val, current_idx], fresh_name(ctx, "el"))

    // Handle destructuring
    match destructure {
        some(ds) => {
            if ds.len() > 0 {
                // Destructure: each element is a tuple (list)
                for i in 0..ds.len() {
                    match ds.get(i) {
                        some(d) => {
                            let idx_val = LLVMConstInt(ctx.i64_type, i, 0)
                            let sub_elem = LLVMBuildCall2(ctx.builder, get_ty, get_fn, [elem, idx_val], fresh_name(ctx, "de"))
                            let alloca = build_entry_alloca(ctx, ctx.ptr_type, d.name)
                            discard(LLVMBuildStore(ctx.builder, sub_elem, alloca))
                            ctx.named_values.insert(d.name, alloca)
                        },
                        none => {},
                    }
                }
            } else {
                let alloca = build_entry_alloca(ctx, ctx.ptr_type, binding)
                discard(LLVMBuildStore(ctx.builder, elem, alloca))
                ctx.named_values.insert(binding, alloca)
            }
        },
        none => {
            let alloca = build_entry_alloca(ctx, ctx.ptr_type, binding)
            discard(LLVMBuildStore(ctx.builder, elem, alloca))
            ctx.named_values.insert(binding, alloca)
        },
    }

    discard(gen_llvm_expr(ctx, body))
    discard(LLVMBuildBr(ctx.builder, incr_bb))

    // Increment
    LLVMPositionBuilderAtEnd(ctx.builder, incr_bb)
    let current_idx2 = LLVMBuildLoad2(ctx.builder, ctx.i64_type, counter_alloca, fresh_name(ctx, "ci"))
    let one = LLVMConstInt(ctx.i64_type, 1, 0)
    let next_idx = LLVMBuildAdd(ctx.builder, current_idx2, one, fresh_name(ctx, "ni"))
    discard(LLVMBuildStore(ctx.builder, next_idx, counter_alloca))
    discard(LLVMBuildBr(ctx.builder, cond_bb))

    // Restore loop context
    ctx.loop_break_bb = saved_break
    ctx.loop_continue_bb = saved_continue

    LLVMPositionBuilderAtEnd(ctx.builder, merge_bb)
}

// ============================================================
// Break / Continue
// ============================================================

fn emit_break(mut ctx: LlvmCtx) {
    match ctx.loop_break_bb {
        some(bb) => {
            discard(LLVMBuildBr(ctx.builder, bb))
            // After a break, the current BB is terminated. Create a dummy unreachable BB
            // so subsequent statements can still be emitted (they're dead code).
            let current_fn_val = match ctx.current_fn {
                some(f) => f,
                none => panic("LLVM codegen: break outside function"),
            }
            let dummy_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn_val, "post.break")
            LLVMPositionBuilderAtEnd(ctx.builder, dummy_bb)
        },
        none => {
            // Break outside loop — this shouldn't happen in well-typed code
        },
    }
}

fn emit_continue(mut ctx: LlvmCtx) {
    match ctx.loop_continue_bb {
        some(bb) => {
            discard(LLVMBuildBr(ctx.builder, bb))
            let current_fn_val = match ctx.current_fn {
                some(f) => f,
                none => panic("LLVM codegen: continue outside function"),
            }
            let dummy_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn_val, "post.continue")
            LLVMPositionBuilderAtEnd(ctx.builder, dummy_bb)
        },
        none => {},
    }
}

// ============================================================
// LetDestructure
// ============================================================

fn emit_let_destructure(mut ctx: LlvmCtx, bindings: List<HLetDestructureBinding>, init: HExpr) {
    let val = gen_llvm_expr(ctx, init)

    // Destructure: val is a tuple (list), extract each element by index
    let get_fn = get_or_declare_runtime_fn(ctx, "ring_list_get", [ctx.ptr_type, ctx.i64_type], ctx.ptr_type)
    let get_ty = get_rt_fn_type(ctx, "ring_list_get")

    for i in 0..bindings.len() {
        match bindings.get(i) {
            some(b) => {
                if b.name != "_" {
                    let idx = LLVMConstInt(ctx.i64_type, i, 0)
                    let elem = LLVMBuildCall2(ctx.builder, get_ty, get_fn, [val, idx], fresh_name(ctx, "dt"))
                    let alloca = build_entry_alloca(ctx, ctx.ptr_type, b.name)
                    discard(LLVMBuildStore(ctx.builder, elem, alloca))
                    ctx.named_values.insert(b.name, alloca)
                }
            },
            none => {},
        }
    }
}

// ============================================================
// IfLet
// ============================================================

fn emit_if_let(mut ctx: LlvmCtx, pattern: Pattern, expr: HExpr, then_block: HExpr, else_block: HExpr?) {
    let current_fn = match ctx.current_fn {
        some(f) => f,
        none => panic("LLVM codegen: if-let outside function"),
    }

    let scrut_val = gen_llvm_expr(ctx, expr)
    let scrut_ty = hexpr_type(expr)

    let then_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "iflet.then")
    let else_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "iflet.else")
    let merge_bb = LLVMAppendBasicBlockInContext(ctx.context, current_fn, "iflet.merge")

    // Generate condition based on pattern
    match pattern {
        Pattern::Constructor { name, fields, .. } => {
            // Check if scrutinee is the specified variant
            let enum_name = match scrut_ty {
                Type::EnumType { name: ename, .. } => ename,
                _ => "Option",  // Fallback for common if-let on Option
            }
            match ctx.enum_types.get(enum_name) {
                some(enum_info) => {
                    match enum_info.variants.get(name) {
                        some(vi) => {
                            let tag_ptr = LLVMBuildStructGEP2(ctx.builder, enum_info.llvm_type, scrut_val, 0, fresh_name(ctx, "tp"))
                            let tag_val = LLVMBuildLoad2(ctx.builder, ctx.i64_type, tag_ptr, fresh_name(ctx, "tag"))
                            let expected_tag = LLVMConstInt(ctx.i64_type, vi.tag, 0)
                            let cond = LLVMBuildICmp(ctx.builder, 32, tag_val, expected_tag, fresh_name(ctx, "eq"))
                            discard(LLVMBuildCondBr(ctx.builder, cond, then_bb, else_bb))

                            // Then: bind fields
                            LLVMPositionBuilderAtEnd(ctx.builder, then_bb)
                            for i in 0..fields.len() {
                                match fields.get(i) {
                                    some(fp) => {
                                        match fp {
                                            Pattern::Binding { name: bname, .. } => {
                                                let field_ptr = LLVMBuildStructGEP2(ctx.builder, enum_info.llvm_type, scrut_val, i + 1, fresh_name(ctx, "ef"))
                                                let field_val = LLVMBuildLoad2(ctx.builder, ctx.ptr_type, field_ptr, fresh_name(ctx, bname))
                                                let alloca = build_entry_alloca(ctx, ctx.ptr_type, bname)
                                                discard(LLVMBuildStore(ctx.builder, field_val, alloca))
                                                ctx.named_values.insert(bname, alloca)
                                            },
                                            _ => {},
                                        }
                                    },
                                    none => {},
                                }
                            }
                            discard(gen_llvm_expr(ctx, then_block))
                            discard(LLVMBuildBr(ctx.builder, merge_bb))

                            // Else
                            LLVMPositionBuilderAtEnd(ctx.builder, else_bb)
                            match else_block {
                                some(eb) => { discard(gen_llvm_expr(ctx, eb)) },
                                none => {},
                            }
                            discard(LLVMBuildBr(ctx.builder, merge_bb))

                            LLVMPositionBuilderAtEnd(ctx.builder, merge_bb)
                        },
                        none => {
                            // Variant not found — just execute then block
                            discard(LLVMBuildBr(ctx.builder, then_bb))
                            LLVMPositionBuilderAtEnd(ctx.builder, then_bb)
                            discard(gen_llvm_expr(ctx, then_block))
                            discard(LLVMBuildBr(ctx.builder, merge_bb))
                            LLVMPositionBuilderAtEnd(ctx.builder, else_bb)
                            discard(LLVMBuildBr(ctx.builder, merge_bb))
                            LLVMPositionBuilderAtEnd(ctx.builder, merge_bb)
                        },
                    }
                },
                none => {
                    // Enum not registered
                    discard(LLVMBuildBr(ctx.builder, then_bb))
                    LLVMPositionBuilderAtEnd(ctx.builder, then_bb)
                    discard(gen_llvm_expr(ctx, then_block))
                    discard(LLVMBuildBr(ctx.builder, merge_bb))
                    LLVMPositionBuilderAtEnd(ctx.builder, else_bb)
                    discard(LLVMBuildBr(ctx.builder, merge_bb))
                    LLVMPositionBuilderAtEnd(ctx.builder, merge_bb)
                },
            }
        },
        _ => {
            // Non-constructor pattern in if-let: just evaluate then
            discard(LLVMBuildBr(ctx.builder, then_bb))
            LLVMPositionBuilderAtEnd(ctx.builder, then_bb)
            discard(gen_llvm_expr(ctx, then_block))
            discard(LLVMBuildBr(ctx.builder, merge_bb))
            LLVMPositionBuilderAtEnd(ctx.builder, else_bb)
            match else_block {
                some(eb) => { discard(gen_llvm_expr(ctx, eb)) },
                none => {},
            }
            discard(LLVMBuildBr(ctx.builder, merge_bb))
            LLVMPositionBuilderAtEnd(ctx.builder, merge_bb)
        },
    }
}
