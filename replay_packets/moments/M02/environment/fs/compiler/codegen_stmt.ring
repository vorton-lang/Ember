use ast::{Pattern, NamedPatternField, LiteralValue}
use hir::{HExpr, HStmt, HMatchArm, HLetDestructureBinding,
    ENUM_TAG_FIELD, RUNTIME_MATCH_FAIL, hexpr_type, trait_dict_name, HForInDestructure}
use types::{Type, BUILTIN_RANGE}
use codegen_ctx::{CodegenCtx, emit, push_indent, pop_indent, safe_ident, qualify}

// Forward declarations — these will be provided by codegen_expr
// In Ring, we pass gen_expr as a function parameter or use a separate module import
// For now we declare the cross-module functions

extern fn gen_expr(mut ctx: CodegenCtx, expr: HExpr) -> Str

// Resolve a raw pattern name (e.g. "Pair") to a qualified struct key
// in struct_field_order (e.g. "inner$Pair"). Returns qualified name if found, none otherwise.
fn resolve_struct_name(ctx: CodegenCtx, raw_name: Str) -> Str? {
    let safe = safe_ident(raw_name)
    let qualified = qualify(ctx, safe)
    if ctx.struct_field_order.contains_key(qualified) {
        return some(qualified)
    }
    // Fallback: search for a key ending with "$raw_name" (mod-qualified struct)
    let suffix = "\$${safe}"
    for entry in ctx.struct_field_order.entries() {
        let (k, _v) = entry
        if k.ends_with(suffix) {
            return some(k)
        }
    }
    none
}

// ============================================================
// Statement-mode expression emission
// ============================================================

pub fn emit_in_stmt_context(mut ctx: CodegenCtx, expr: HExpr, mode: Str) {
    match expr {
        HExpr::IfExpr { condition, then_branch, else_branch, .. } =>
            emit_if_stmt(ctx, condition, then_branch, else_branch, mode),
        HExpr::Block { stmts, tail, .. } =>
            emit_block_in_stmt_context_inner(ctx, stmts, tail, mode),
        HExpr::MatchExpr { scrutinee, arms, .. } =>
            emit_match_stmt(ctx, scrutinee, arms, mode),
        _ => {
            let e = gen_expr(ctx, expr)
            if mode == "return" {
                emit(ctx, "return ${e};")
            } else {
                emit(ctx, "${e};")
            }
        },
    }
}

// ============================================================
// If statement (statement-mode)
// ============================================================

fn emit_if_stmt(mut ctx: CodegenCtx, condition: HExpr, then_branch: HExpr, else_branch: HExpr?, mode: Str) {
    let cond = gen_expr(ctx, condition)
    emit(ctx, "if (${cond}) {")
    push_indent(ctx)
    emit_block_in_stmt_context(ctx, then_branch, mode)
    pop_indent(ctx)
    match else_branch {
        none => emit(ctx, "}"),
        some(eb) => match eb {
            HExpr::IfExpr { condition: ec, then_branch: et, else_branch: ee, .. } => {
                emit_else_if(ctx, ec, et, ee, mode)
            },
            _ => {
                emit(ctx, "} else {")
                push_indent(ctx)
                emit_block_in_stmt_context(ctx, eb, mode)
                pop_indent(ctx)
                emit(ctx, "}")
            },
        },
    }
}

fn emit_else_if(mut ctx: CodegenCtx, condition: HExpr, then_branch: HExpr, else_branch: HExpr?, mode: Str) {
    let cond = gen_expr(ctx, condition)
    emit(ctx, "} else if (${cond}) {")
    push_indent(ctx)
    emit_block_in_stmt_context(ctx, then_branch, mode)
    pop_indent(ctx)
    match else_branch {
        none => emit(ctx, "}"),
        some(eb) => match eb {
            HExpr::IfExpr { condition: ec, then_branch: et, else_branch: ee, .. } => {
                emit_else_if(ctx, ec, et, ee, mode)
            },
            _ => {
                emit(ctx, "} else {")
                push_indent(ctx)
                emit_block_in_stmt_context(ctx, eb, mode)
                pop_indent(ctx)
                emit(ctx, "}")
            },
        },
    }
}

// ============================================================
// Block in statement context
// ============================================================

pub fn emit_block_in_stmt_context(mut ctx: CodegenCtx, block: HExpr, mode: Str) {
    match block {
        HExpr::Block { stmts, tail, .. } =>
            emit_block_in_stmt_context_inner(ctx, stmts, tail, mode),
        _ => emit_in_stmt_context(ctx, block, mode),
    }
}

fn emit_block_in_stmt_context_inner(mut ctx: CodegenCtx, stmts: List<HStmt>, tail: HExpr?, mode: Str) {
    for stmt in stmts {
        emit_stmt(ctx, stmt)
    }
    match tail {
        some(t) => emit_in_stmt_context(ctx, t, mode),
        none => {},
    }
}

// ============================================================
// Block body (shared between functions and IIFE blocks)
// ============================================================

pub fn emit_block_body(mut ctx: CodegenCtx, block: HExpr) {
    match block {
        HExpr::Block { stmts, tail, .. } => {
            for stmt in stmts {
                emit_stmt(ctx, stmt)
            }
            match tail {
                some(t) => emit_in_stmt_context(ctx, t, "return"),
                none => {},
            }
        },
        _ => emit_in_stmt_context(ctx, block, "return"),
    }
}

// ============================================================
// Iterator protocol for-in codegen
// ============================================================

// Generates JS code for for..in using the Iterator/Iterable trait protocol:
//   const __ring_iter_N = __Type_Iterable.iter(collection);
//   while (true) {
//       const __ring_next_N = __IterType_Iterator.next(__ring_iter_N);
//       if (__ring_next_N._tag === "none") break;
//       const x = __ring_next_N._0;
//       // body
//   }
fn emit_iterator_for_in(mut ctx: CodegenCtx, binding: Str, destructure: List<HForInDestructure>?,
                         iterable: HExpr, body: HExpr, iterable_type_name: Str?, iter_type_name: Str?) {
    let counter = ctx.loop_counter
    ctx.loop_counter = ctx.loop_counter + 1
    let it_expr = gen_expr(ctx, iterable)

    match (iterable_type_name, iter_type_name) {
        (some(itn), some(iter_tn)) => {
            let iter_dict = trait_dict_name(qualify(ctx, itn), "Iterable")
            let next_dict = trait_dict_name(qualify(ctx, iter_tn), "Iterator")
            let iter_var = "__ring_iter_${counter}"
            let next_var = "__ring_next_${counter}"
            emit(ctx, "const ${iter_var} = ${iter_dict}.iter(${it_expr});")
            emit(ctx, "while (true) {")
            push_indent(ctx)
            emit(ctx, "const ${next_var} = ${next_dict}.next(${iter_var});")
            emit(ctx, "if (${next_var}._tag === \"none\") break;")
            match destructure {
                some(ds) => {
                    if ds.len() > 0 {
                        let mut names: List<Str> = []
                        for d in ds { names.push(safe_ident(d.name)) }
                        let joined = names.join(", ")
                        emit(ctx, "const [${joined}] = ${next_var}._0;")
                    } else {
                        let b = safe_ident(binding)
                        emit(ctx, "const ${b} = ${next_var}._0;")
                    }
                },
                none => {
                    let b = safe_ident(binding)
                    emit(ctx, "const ${b} = ${next_var}._0;")
                },
            }
            emit_block_in_stmt_context(ctx, body, "discard")
            pop_indent(ctx)
            emit(ctx, "}")
        },
        _ => {
            // Fallback: should not happen if checker is correct, but generate for..of as safety net
            let b = safe_ident(binding)
            emit(ctx, "for (const ${b} of ${it_expr}) {")
            push_indent(ctx)
            emit_block_in_stmt_context(ctx, body, "discard")
            pop_indent(ctx)
            emit(ctx, "}")
        }
    }
}

// ============================================================
// Match statement (statement-mode)
// ============================================================

// Match codegen uses a JS labeled block (`__ring_matchN: { ... break __ring_matchN; }`) to
// exit early when a pattern matches. User `break` (to exit a loop) compiles to plain `break;`,
// which targets the enclosing loop — not the labeled block — so they do not conflict.
fn emit_match_stmt(mut ctx: CodegenCtx, scrutinee: HExpr, arms: List<HMatchArm>, mode: Str) {
    let label = "__ring_match${ctx.match_counter}"
    ctx.match_counter = ctx.match_counter + 1
    let scrut_js = gen_expr(ctx, scrutinee)
    emit(ctx, "${label}: {")
    push_indent(ctx)
    let scrut_var = "__ring_m${ctx.match_counter - 1}"
    emit(ctx, "const ${scrut_var} = ${scrut_js};")

    for arm in arms {
        let cond = gen_pattern_condition(ctx, scrut_var, arm.pattern)
        let bindings_str = gen_pattern_bindings(ctx, scrut_var, arm.pattern)
        match arm.guard {
            none => {
                if cond == "true" {
                    if bindings_str.len() > 0 { emit(ctx, bindings_str.trim()) }
                    emit_in_stmt_context(ctx, arm.body, mode)
                    emit(ctx, "break ${label};")
                } else {
                    emit(ctx, "if (${cond}) {")
                    push_indent(ctx)
                    if bindings_str.len() > 0 { emit(ctx, bindings_str.trim()) }
                    emit_in_stmt_context(ctx, arm.body, mode)
                    emit(ctx, "break ${label};")
                    pop_indent(ctx)
                    emit(ctx, "}")
                }
            },
            some(guard) => {
                emit(ctx, "if (${cond}) {")
                push_indent(ctx)
                if bindings_str.len() > 0 { emit(ctx, bindings_str.trim()) }
                let guard_js = gen_expr(ctx, guard)
                emit(ctx, "if (${guard_js}) {")
                push_indent(ctx)
                emit_in_stmt_context(ctx, arm.body, mode)
                emit(ctx, "break ${label};")
                pop_indent(ctx)
                emit(ctx, "}")
                pop_indent(ctx)
                emit(ctx, "}")
            },
        }
    }

    let mut has_catchall = false
    for a in arms {
        match a.guard { some(_) => {}, none => {
            if pattern_is_catchall(a.pattern) { has_catchall = true }
        }}
    }
    if has_catchall == false {
        emit(ctx, "${RUNTIME_MATCH_FAIL}(${scrut_var});")
    }
    pop_indent(ctx)
    emit(ctx, "}")
}

// ============================================================
// Statements
// ============================================================

pub fn emit_stmt(mut ctx: CodegenCtx, stmt: HStmt) {
    match stmt {
        HStmt::ExprStmt { expr, .. } => emit_in_stmt_context(ctx, expr, "discard"),
        HStmt::Return { value, .. } => match value {
            some(v) => emit_in_stmt_context(ctx, v, "return"),
            none => emit(ctx, "return;"),
        },
        HStmt::While { condition, body, .. } => {
            let cond = gen_expr(ctx, condition)
            emit(ctx, "while (${cond}) {")
            push_indent(ctx)
            emit_block_in_stmt_context(ctx, body, "discard")
            pop_indent(ctx)
            emit(ctx, "}")
        },
        HStmt::ForIn { binding, destructure, iterable, body, iterable_type_name, iter_type_name, .. } => {
            match iterable {
                HExpr::RangeExpr { start, end, inclusive, .. } => {
                    let start_js = gen_expr(ctx, start)
                    let end_js = gen_expr(ctx, end)
                    let b = safe_ident(binding)
                    let end_var = "__ring_end${ctx.loop_counter}"
                    ctx.loop_counter = ctx.loop_counter + 1
                    emit(ctx, "const ${end_var} = ${end_js};")
                    let cmp = if inclusive { "<=" } else { "<" }
                    emit(ctx, "for (let ${b} = ${start_js}; ${b} ${cmp} ${end_var}; ${b}++) {")
                    push_indent(ctx)
                    emit_block_in_stmt_context(ctx, body, "discard")
                    pop_indent(ctx)
                    emit(ctx, "}")
                },
                _ => {
                    // Check if the iterable has Range type (e.g. variable holding a range)
                    let iter_htype = hexpr_type(iterable)
                    let is_range = match iter_htype {
                        Type::EnumType { name, .. } => name == BUILTIN_RANGE,
                        _ => false,
                    }
                    if is_range {
                        let rng_var = "__ring_rng${ctx.loop_counter}"
                        ctx.loop_counter = ctx.loop_counter + 1
                        let it = gen_expr(ctx, iterable)
                        let b = safe_ident(binding)
                        emit(ctx, "const ${rng_var} = ${it};")
                        emit(ctx, "for (let ${b} = ${rng_var}.start; ${rng_var}.inclusive ? ${b} <= ${rng_var}.end : ${b} < ${rng_var}.end; ${b}++) {")
                        push_indent(ctx)
                        emit_block_in_stmt_context(ctx, body, "discard")
                        pop_indent(ctx)
                        emit(ctx, "}")
                    } else {
                        // Iterator trait protocol: call iter() then loop with next()
                        emit_iterator_for_in(ctx, binding, destructure, iterable, body, iterable_type_name, iter_type_name)
                    }
                },
            }
        },
        HStmt::Break { .. } => emit(ctx, "break;"),
        HStmt::Continue { .. } => emit(ctx, "continue;"),
        HStmt::LetDestructure { bindings, init, .. } => {
            let init_js = gen_expr(ctx, init)
            let tmp = "__ring_dt${ctx.dt_counter}"
            ctx.dt_counter = ctx.dt_counter + 1
            emit(ctx, "const ${tmp} = ${init_js};")
            for i in 0..bindings.len() {
                match bindings.get(i) {
                    some(b) => {
                        if b.name != "_" {
                            let sname = safe_ident(b.name)
                            emit(ctx, "const ${sname} = ${tmp}[${i}];")
                        }
                    },
                    none => {},
                }
            }
        },
        HStmt::IfLet { pattern, expr, then_block, else_block, .. } => {
            emit(ctx, "{")
            push_indent(ctx)
            let scrutinee = gen_expr(ctx, expr)
            emit(ctx, "const __ring_t = ${scrutinee};")
            let cond = gen_pattern_condition(ctx, "__ring_t", pattern)
            emit(ctx, "if (${cond}) {")
            push_indent(ctx)
            let bindings = gen_pattern_bindings(ctx, "__ring_t", pattern)
            if bindings.trim().len() > 0 { emit(ctx, bindings.trim()) }
            emit_block_in_stmt_context(ctx, then_block, "discard")
            pop_indent(ctx)
            match else_block {
                some(eb) => {
                    emit(ctx, "} else {")
                    push_indent(ctx)
                    emit_block_in_stmt_context(ctx, eb, "discard")
                    pop_indent(ctx)
                    emit(ctx, "}")
                },
                none => emit(ctx, "}"),
            }
            pop_indent(ctx)
            emit(ctx, "}")
        },
        HStmt::Let { name, init, .. } => {
            let sname = safe_ident(name)
            let init_js = gen_expr(ctx, init)
            emit(ctx, "const ${sname} = ${init_js};")
        },
        HStmt::Var { name, def_id, init, .. } => {
            let sname = safe_ident(name)
            let init_js = gen_expr(ctx, init)
            let is_boxed = match def_id { some(did) => ctx.boxed_vars.contains(did), none => false }
            if is_boxed {
                emit(ctx, "let ${sname} = {value: ${init_js}};")
            } else {
                emit(ctx, "let ${sname} = ${init_js};")
            }
        },
        HStmt::Assign { target, value, .. } => {
            let t = gen_expr(ctx, target)
            let v = gen_expr(ctx, value)
            emit(ctx, "${t} = ${v};")
        },
        // Perceus RC ops — no-op for JS backend (GC handles memory)
        HStmt::Drop { .. } => {},
        HStmt::Dup { .. } => {},
    }
}

// ============================================================
// Inline statement generation (for IIFE bodies)
// ============================================================

pub fn gen_stmt_inline(mut ctx: CodegenCtx, stmt: HStmt) -> Str {
    match stmt {
        HStmt::Let { name, init, .. } => {
            let sname = safe_ident(name)
            let init_js = gen_expr(ctx, init)
            "const ${sname} = ${init_js};"
        },
        HStmt::Var { name, def_id, init, .. } => {
            let sname = safe_ident(name)
            let init_js = gen_expr(ctx, init)
            let is_boxed = match def_id { some(did) => ctx.boxed_vars.contains(did), none => false }
            if is_boxed {
                "let ${sname} = {value: ${init_js}};"
            } else {
                "let ${sname} = ${init_js};"
            }
        },
        HStmt::Assign { target, value, .. } => {
            let t = gen_expr(ctx, target)
            let v = gen_expr(ctx, value)
            "${t} = ${v};"
        },
        HStmt::ExprStmt { expr, .. } => {
            let e = gen_expr(ctx, expr)
            "${e};"
        },
        HStmt::Return { value, .. } => match value {
            some(v) => {
                let e = gen_expr(ctx, v)
                "return ${e};"
            },
            none => "return;",
        },
        _ => "/* codegen: unhandled inline stmt */ undefined;",
    }
}

pub fn pattern_is_catchall(pat: Pattern) -> Bool {
    match pat {
        Pattern::Wildcard { .. } => true,
        Pattern::Binding { .. } => true,
        Pattern::OrPattern { patterns, .. } => {
            for p in patterns {
                if pattern_is_catchall(p) { return true }
            }
            false
        },
        _ => false,
    }
}

// ============================================================
// Pattern condition generation
// ============================================================

pub fn gen_pattern_condition(ctx: CodegenCtx, target: Str, pat: Pattern) -> Str {
    match pat {
        Pattern::Wildcard { .. } => "true",
        Pattern::Binding { .. } => "true",
        Pattern::Literal { value, .. } => {
            let val_str = match value {
                LiteralValue::IntVal(n) => n.to_str(),
                LiteralValue::FloatVal(f) => f.to_str(),
                LiteralValue::StrVal(s) => json_stringify(s),
                LiteralValue::BoolVal(b) => if b { "true" } else { "false" },
            }
            "${target} === ${val_str}"
        },
        Pattern::Constructor { name, fields, .. } => {
            let tag_check = "${target}.${ENUM_TAG_FIELD} === \"${name}\""
            let mut sub_conds: List<Str> = []
            for i in 0..fields.len() {
                match fields.get(i) {
                    some(f) => {
                        let sub = gen_pattern_condition(ctx, "${target}._${i}", f)
                        if sub != "true" { sub_conds.push(sub) }
                    },
                    none => {},
                }
            }
            if sub_conds.len() == 0 { tag_check }
            else {
                let joined = sub_conds.join(" && ")
                "${tag_check} && ${joined}"
            }
        },
        Pattern::NamedConstructor { name, fields, .. } => {
            let resolved = resolve_struct_name(ctx, name)
            match resolved {
            some(qualified_name) => {
                let inst_check = "${target} instanceof ${qualified_name}"
                let mut sub_conds: List<Str> = []
                for f in fields {
                    let sname = safe_ident(f.name)
                    let sub = gen_pattern_condition(ctx, "${target}.${sname}", f.pattern)
                    if sub != "true" { sub_conds.push(sub) }
                }
                if sub_conds.len() == 0 { inst_check }
                else {
                    let joined = sub_conds.join(" && ")
                    "${inst_check} && ${joined}"
                }
            },
            none => {
                let tag_check = "${target}.${ENUM_TAG_FIELD} === \"${name}\""
                let mut sub_conds: List<Str> = []
                for f in fields {
                    let sname = safe_ident(f.name)
                    let sub = gen_pattern_condition(ctx, "${target}.${sname}", f.pattern)
                    if sub != "true" { sub_conds.push(sub) }
                }
                if sub_conds.len() == 0 { tag_check }
                else {
                    let joined = sub_conds.join(" && ")
                    "${tag_check} && ${joined}"
                }
            },
            }
        },
        Pattern::TuplePattern { elements, .. } => {
            let len_check = "Array.isArray(${target}) && ${target}.length === ${elements.len()}"
            let mut sub_conds: List<Str> = []
            for i in 0..elements.len() {
                match elements.get(i) {
                    some(e) => {
                        let sub = gen_pattern_condition(ctx, "${target}[${i}]", e)
                        if sub != "true" { sub_conds.push(sub) }
                    },
                    none => {},
                }
            }
            if sub_conds.len() == 0 { len_check }
            else {
                let joined = sub_conds.join(" && ")
                "${len_check} && ${joined}"
            }
        },
        Pattern::OrPattern { patterns, .. } => {
            let mut or_conds: List<Str> = []
            for p in patterns {
                let sub = gen_pattern_condition(ctx, target, p)
                or_conds.push("(${sub})")
            }
            or_conds.join(" || ")
        },
    }
}

// ============================================================
// Pattern bindings generation
// ============================================================

pub fn gen_pattern_bindings(ctx: CodegenCtx, target: Str, pat: Pattern) -> Str {
    match pat {
        Pattern::Wildcard { .. } => "",
        Pattern::Literal { .. } => "",
        Pattern::Binding { name, .. } => {
            let sname = safe_ident(name)
            "const ${sname} = ${target}; "
        },
        Pattern::Constructor { fields, .. } => {
            let mut result = ""
            for i in 0..fields.len() {
                match fields.get(i) {
                    some(f) => {
                        let sub = gen_pattern_bindings(ctx, "${target}._${i}", f)
                        result = "${result}${sub}"
                    },
                    none => {},
                }
            }
            result
        },
        Pattern::NamedConstructor { fields, .. } => {
            let mut result = ""
            for f in fields {
                let sname = safe_ident(f.name)
                let sub = gen_pattern_bindings(ctx, "${target}.${sname}", f.pattern)
                result = "${result}${sub}"
            }
            result
        },
        Pattern::TuplePattern { elements, .. } => {
            let mut result = ""
            for i in 0..elements.len() {
                match elements.get(i) {
                    some(e) => {
                        let sub = gen_pattern_bindings(ctx, "${target}[${i}]", e)
                        result = "${result}${sub}"
                    },
                    none => {},
                }
            }
            result
        },
        Pattern::OrPattern { patterns, .. } => {
            // Collect binding names from the first sub-pattern
            let mut binding_names: List<Str> = []
            collect_binding_names(pat_at_list(patterns, 0), binding_names)
            if binding_names.len() == 0 {
                // No bindings in any sub-pattern — nothing to emit
                ""
            } else {
                // Declare binding variables with let, then conditionally assign
                let mut result = ""
                for name in binding_names {
                    let sname = safe_ident(name)
                    result = "${result}let ${sname}; "
                }
                let mut i = 0
                for p in patterns {
                    let cond = gen_pattern_condition(ctx, target, p)
                    let assigns = gen_pattern_assignments(ctx, target, p)
                    if i == 0 {
                        result = "${result}if (${cond}) { ${assigns}} "
                    } else {
                        result = "${result}else if (${cond}) { ${assigns}} "
                    }
                    i = i + 1
                }
                result
            }
        },
    }
}

fn pat_at_list(list: List<Pattern>, i: Int) -> Pattern {
    match list.get(i) { some(v) => v, none => panic("unreachable: pat_at_list out of bounds") }
}

// Collect all binding variable names from a pattern (recursive)
fn collect_binding_names(pat: Pattern, mut names: List<Str>) {
    match pat {
        Pattern::Wildcard { .. } => {},
        Pattern::Literal { .. } => {},
        Pattern::Binding { name, .. } => names.push(name),
        Pattern::Constructor { fields, .. } => {
            for f in fields { collect_binding_names(f, names) }
        },
        Pattern::NamedConstructor { fields, .. } => {
            for f in fields { collect_binding_names(f.pattern, names) }
        },
        Pattern::TuplePattern { elements, .. } => {
            for e in elements { collect_binding_names(e, names) }
        },
        Pattern::OrPattern { patterns, .. } => {
            // Only collect from first sub-pattern (all should have same names)
            collect_binding_names(pat_at_list(patterns, 0), names)
        },
    }
}

// Generate pattern bindings as assignments (= instead of const =) for or-pattern
fn gen_pattern_assignments(ctx: CodegenCtx, target: Str, pat: Pattern) -> Str {
    match pat {
        Pattern::Wildcard { .. } => "",
        Pattern::Literal { .. } => "",
        Pattern::Binding { name, .. } => {
            let sname = safe_ident(name)
            "${sname} = ${target}; "
        },
        Pattern::Constructor { fields, .. } => {
            let mut result = ""
            for i in 0..fields.len() {
                match fields.get(i) {
                    some(f) => {
                        let sub = gen_pattern_assignments(ctx, "${target}._${i}", f)
                        result = "${result}${sub}"
                    },
                    none => {},
                }
            }
            result
        },
        Pattern::NamedConstructor { fields, .. } => {
            let mut result = ""
            for f in fields {
                let sname = safe_ident(f.name)
                let sub = gen_pattern_assignments(ctx, "${target}.${sname}", f.pattern)
                result = "${result}${sub}"
            }
            result
        },
        Pattern::TuplePattern { elements, .. } => {
            let mut result = ""
            for i in 0..elements.len() {
                match elements.get(i) {
                    some(e) => {
                        let sub = gen_pattern_assignments(ctx, "${target}[${i}]", e)
                        result = "${result}${sub}"
                    },
                    none => {},
                }
            }
            result
        },
        Pattern::OrPattern { patterns, .. } => {
            // Nested or-pattern in or-pattern — use same conditional approach
            let mut result = ""
            let mut i = 0
            for p in patterns {
                let cond = gen_pattern_condition(ctx, target, p)
                let assigns = gen_pattern_assignments(ctx, target, p)
                if i == 0 {
                    result = "${result}if (${cond}) { ${assigns}} "
                } else {
                    result = "${result}else if (${cond}) { ${assigns}} "
                }
                i = i + 1
            }
            result
        },
    }
}

