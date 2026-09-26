// Perceus RC L0: dup/drop insertion pass
// Reference: Koka Perceus (POPL'21) — backward liveness + branch-balancing
//
// Core idea: walk each function body backward to determine the *last use* of
// every owned variable.  Last use = consume (no dup needed).  Non-last use =
// dup required.  On scope exit, dead variables get a drop.
//
// L0 simplifications:
//   - All values are owned (uniform boxing) — every let/var/param needs RC.
//   - Conservative for loops: external vars used in loop body always dup.
//   - Lambda captures: always dup.
//   - Complex nested exprs: conservatively dup.

use ast::{Span, Position, Pattern, NamedPatternField}
use hir::{HDecl, HStmt, HExpr, HParam, HProgram, HMatchArm,
    HStructFieldInit, HStringInterpPart, HEffectHandler,
    HForInDestructure, HLetDestructureBinding,
    hexpr_type, hexpr_span, hexpr_effects}
use types::{Type, EffectRow}

// ============================================================
// Synthetic span for inserted Drop/Dup nodes
// ============================================================

fn synthetic_span() -> Span {
    let pos = Position { line: 0, column: 0, offset: 0 }
    Span { file: "<perceus>", start: pos, end: pos }
}

// B-084 #131(a): the wildcard `_` is never bound to a real named_values slot
// (codegen's destructure / for-in / let lowering deliberately skips `_`), so a
// Drop/Dup naming `_` is unrunnable RC noise (a fail-safe codegen skip + rc-warn).
// `_` also has no observable binding to release — it is a discard, the value
// flows through the enclosing scrutinee's own RC. Centralise the skip so every
// drop/dup emission site is consistent.
fn rc_name_skippable(name: Str) -> Bool {
    name == "_"
}

// ============================================================
// Collect all variable references in an expression (names only)
// This is used to determine which variables are "used" in an expr.
// ============================================================

fn collect_expr_vars(expr: HExpr, mut out: Set<Str>) {
    match expr {
        HExpr::Ident { name, .. } => { out.insert(name) },
        HExpr::BinOp { left, right, .. } => {
            collect_expr_vars(left, out)
            collect_expr_vars(right, out)
        },
        HExpr::UnaryOp { operand, .. } => {
            collect_expr_vars(operand, out)
        },
        HExpr::Call { callee, args, .. } => {
            collect_expr_vars(callee, out)
            for a in args { collect_expr_vars(a, out) }
        },
        HExpr::FieldAccess { receiver, .. } => {
            collect_expr_vars(receiver, out)
        },
        HExpr::StructLit { fields, spread, .. } => {
            for f in fields { collect_expr_vars(f.value, out) }
            match spread {
                some(s) => collect_expr_vars(s, out),
                none => {},
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for f in fields { collect_expr_vars(f.value, out) }
            match spread {
                some(s) => collect_expr_vars(s, out),
                none => {},
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            collect_expr_vars(scrutinee, out)
            for arm in arms {
                collect_expr_vars(arm.body, out)
                match arm.guard {
                    some(g) => collect_expr_vars(g, out),
                    none => {},
                }
            }
        },
        HExpr::Block { stmts, tail, .. } => {
            for s in stmts { collect_stmt_vars(s, out) }
            match tail {
                some(t) => collect_expr_vars(t, out),
                none => {},
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            collect_expr_vars(condition, out)
            collect_expr_vars(then_branch, out)
            match else_branch {
                some(eb) => collect_expr_vars(eb, out),
                none => {},
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for p in parts {
                match p {
                    HStringInterpPart::Expression(e) => collect_expr_vars(e, out),
                    HStringInterpPart::Literal(_) => {},
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            collect_expr_vars(body, out)
            for arm in arms { collect_expr_vars(arm.body, out) }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            collect_expr_vars(body, out)
            for h in handlers { collect_expr_vars(h.body, out) }
        },
        HExpr::Lambda { body, .. } => {
            collect_expr_vars(body, out)
        },
        HExpr::EffectOp { args, .. } => {
            for a in args { collect_expr_vars(a, out) }
        },
        HExpr::RangeExpr { start, end, .. } => {
            collect_expr_vars(start, out)
            collect_expr_vars(end, out)
        },
        HExpr::ListLit { elements, .. } => {
            for e in elements { collect_expr_vars(e, out) }
        },
        HExpr::TupleLit { elements, .. } => {
            for e in elements { collect_expr_vars(e, out) }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            collect_expr_vars(receiver, out)
            collect_expr_vars(index, out)
        },
        HExpr::IntLit { .. } => {},
        HExpr::FloatLit { .. } => {},
        HExpr::StrLit { .. } => {},
        HExpr::BoolLit { .. } => {},
    }
}

fn collect_stmt_vars(stmt: HStmt, mut out: Set<Str>) {
    match stmt {
        HStmt::Let { init, .. } => collect_expr_vars(init, out),
        HStmt::Var { init, .. } => collect_expr_vars(init, out),
        HStmt::Assign { target, value, .. } => {
            collect_expr_vars(target, out)
            collect_expr_vars(value, out)
        },
        HStmt::ExprStmt { expr, .. } => collect_expr_vars(expr, out),
        HStmt::Return { value, .. } => {
            match value {
                some(v) => collect_expr_vars(v, out),
                none => {},
            }
        },
        HStmt::While { condition, body, .. } => {
            collect_expr_vars(condition, out)
            collect_expr_vars(body, out)
        },
        HStmt::ForIn { iterable, body, .. } => {
            collect_expr_vars(iterable, out)
            collect_expr_vars(body, out)
        },
        HStmt::LetDestructure { init, .. } => collect_expr_vars(init, out),
        HStmt::IfLet { expr, then_block, else_block, .. } => {
            collect_expr_vars(expr, out)
            collect_expr_vars(then_block, out)
            match else_block {
                some(eb) => collect_expr_vars(eb, out),
                none => {},
            }
        },
        HStmt::Break { .. } => {},
        HStmt::Continue { .. } => {},
        HStmt::Drop { .. } => {},
        HStmt::Dup { .. } => {},
    }
}

// ============================================================
// B-083 #3: collect the free variables captured by any lambda that appears
// (at any nesting depth) inside an expression / statement.
//
// A "capture" of a lambda is a name referenced in its body that is neither one
// of its parameters nor a variable defined inside the lambda body.  These are
// exactly the names the LLVM codegen stores into the closure env (filtered to
// owned locals at the dup site).  The loop handlers need this set so that, for
// a closure CREATED INSIDE a loop body, the captured outer variable is dup-ed
// once PER ITERATION (each iteration builds a fresh closure that takes its own
// reference) rather than (a) moved — single-pass backward analysis cannot see
// the next iteration, so it would wrongly treat the capture as a last use — or
// (b) dup-ed once before the loop by the conservative loop-var dup, which is one
// total dup, not one per iteration.
//
// We deliberately reuse collect_expr_vars (records bare `name`, matching the RC
// tracking + the loop-var dup) so the produced names key the same named_values
// slot the emitted HStmt::Dup will look up.
// ============================================================

fn collect_lambda_captures_expr(expr: HExpr, mut out: Set<Str>) {
    match expr {
        HExpr::Lambda { params, body, .. } => {
            let mut bound: Set<Str> = set_new()
            for p in params { bound.insert(p.name) }
            collect_local_defs_expr(body, bound)
            let mut body_vars: Set<Str> = set_new()
            collect_expr_vars(body, body_vars)
            for v in body_vars {
                if bound.contains(v) == false { out.insert(v) }
            }
            // Recurse into the body too: a lambda nested inside this lambda's
            // body whose captures escape THIS lambda would be reachable, but its
            // captures relative to the outer loop are already covered by the
            // body_vars scan above (nested-lambda free vars surface as free vars
            // of the enclosing lambda body via collect_expr_vars).  Still recurse
            // so sibling lambdas inside the body are not missed.
            collect_lambda_captures_expr(body, out)
        },
        HExpr::BinOp { left, right, .. } => {
            collect_lambda_captures_expr(left, out)
            collect_lambda_captures_expr(right, out)
        },
        HExpr::UnaryOp { operand, .. } => collect_lambda_captures_expr(operand, out),
        HExpr::Call { callee, args, .. } => {
            collect_lambda_captures_expr(callee, out)
            for a in args { collect_lambda_captures_expr(a, out) }
        },
        HExpr::FieldAccess { receiver, .. } => collect_lambda_captures_expr(receiver, out),
        HExpr::StructLit { fields, spread, .. } => {
            for f in fields { collect_lambda_captures_expr(f.value, out) }
            match spread {
                some(s) => collect_lambda_captures_expr(s, out),
                none => {},
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for f in fields { collect_lambda_captures_expr(f.value, out) }
            match spread {
                some(s) => collect_lambda_captures_expr(s, out),
                none => {},
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            collect_lambda_captures_expr(scrutinee, out)
            for arm in arms {
                collect_lambda_captures_expr(arm.body, out)
                match arm.guard {
                    some(g) => collect_lambda_captures_expr(g, out),
                    none => {},
                }
            }
        },
        HExpr::Block { stmts, tail, .. } => {
            for s in stmts { collect_lambda_captures_stmt(s, out) }
            match tail {
                some(t) => collect_lambda_captures_expr(t, out),
                none => {},
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            collect_lambda_captures_expr(condition, out)
            collect_lambda_captures_expr(then_branch, out)
            match else_branch {
                some(eb) => collect_lambda_captures_expr(eb, out),
                none => {},
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for p in parts {
                match p {
                    HStringInterpPart::Expression(e) => collect_lambda_captures_expr(e, out),
                    HStringInterpPart::Literal(_) => {},
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            collect_lambda_captures_expr(body, out)
            for arm in arms { collect_lambda_captures_expr(arm.body, out) }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            collect_lambda_captures_expr(body, out)
            for h in handlers { collect_lambda_captures_expr(h.body, out) }
        },
        HExpr::EffectOp { args, .. } => {
            for a in args { collect_lambda_captures_expr(a, out) }
        },
        HExpr::RangeExpr { start, end, .. } => {
            collect_lambda_captures_expr(start, out)
            collect_lambda_captures_expr(end, out)
        },
        HExpr::ListLit { elements, .. } => {
            for e in elements { collect_lambda_captures_expr(e, out) }
        },
        HExpr::TupleLit { elements, .. } => {
            for e in elements { collect_lambda_captures_expr(e, out) }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            collect_lambda_captures_expr(receiver, out)
            collect_lambda_captures_expr(index, out)
        },
        HExpr::Ident { .. } => {},
        HExpr::IntLit { .. } => {},
        HExpr::FloatLit { .. } => {},
        HExpr::StrLit { .. } => {},
        HExpr::BoolLit { .. } => {},
    }
}

fn collect_lambda_captures_stmt(stmt: HStmt, mut out: Set<Str>) {
    match stmt {
        HStmt::Let { init, .. } => collect_lambda_captures_expr(init, out),
        HStmt::Var { init, .. } => collect_lambda_captures_expr(init, out),
        HStmt::Assign { target, value, .. } => {
            collect_lambda_captures_expr(target, out)
            collect_lambda_captures_expr(value, out)
        },
        HStmt::ExprStmt { expr, .. } => collect_lambda_captures_expr(expr, out),
        HStmt::Return { value, .. } => {
            match value {
                some(v) => collect_lambda_captures_expr(v, out),
                none => {},
            }
        },
        HStmt::While { condition, body, .. } => {
            collect_lambda_captures_expr(condition, out)
            collect_lambda_captures_expr(body, out)
        },
        HStmt::ForIn { iterable, body, .. } => {
            collect_lambda_captures_expr(iterable, out)
            collect_lambda_captures_expr(body, out)
        },
        HStmt::LetDestructure { init, .. } => collect_lambda_captures_expr(init, out),
        HStmt::IfLet { expr, then_block, else_block, .. } => {
            collect_lambda_captures_expr(expr, out)
            collect_lambda_captures_expr(then_block, out)
            match else_block {
                some(eb) => collect_lambda_captures_expr(eb, out),
                none => {},
            }
        },
        HStmt::Break { .. } => {},
        HStmt::Continue { .. } => {},
        HStmt::Drop { .. } => {},
        HStmt::Dup { .. } => {},
    }
}

// ============================================================
// Collect pattern binding names
// ============================================================

fn pattern_binding_names(pat: Pattern, mut out: List<Str>) {
    match pat {
        Pattern::Wildcard { .. } => {},
        Pattern::Literal { .. } => {},
        Pattern::Binding { name, .. } => out.push(name),
        Pattern::Constructor { fields, .. } => {
            for f in fields { pattern_binding_names(f, out) }
        },
        Pattern::NamedConstructor { fields, .. } => {
            for f in fields { pattern_binding_names(f.pattern, out) }
        },
        Pattern::TuplePattern { elements, .. } => {
            for e in elements { pattern_binding_names(e, out) }
        },
        Pattern::OrPattern { patterns, .. } => {
            // All sub-patterns bind the same names; collect from first
            if patterns.len() > 0 {
                match patterns.get(0) {
                    some(p) => pattern_binding_names(p, out),
                    none => {},
                }
            }
        },
    }
}

// ============================================================
// Collect all locally-defined variable names in statements/expressions
// Used to distinguish local variables (need RC) from globals (skip RC).
// ============================================================

fn collect_local_defs_stmts(stmts: List<HStmt>, mut out: Set<Str>) {
    for stmt in stmts {
        match stmt {
            HStmt::Let { name, .. } => { out.insert(name) },
            HStmt::Var { name, .. } => { out.insert(name) },
            HStmt::LetDestructure { pattern, bindings, .. } => {
                for b in bindings { out.insert(b.name) }
            },
            HStmt::ForIn { binding, body, .. } => {
                out.insert(binding)
                collect_local_defs_expr(body, out)
            },
            HStmt::While { body, .. } => {
                collect_local_defs_expr(body, out)
            },
            HStmt::IfLet { pattern, then_block, else_block, .. } => {
                let mut pat_names: List<Str> = []
                pattern_binding_names(pattern, pat_names)
                for pn in pat_names { out.insert(pn) }
                collect_local_defs_expr(then_block, out)
                match else_block {
                    some(e) => collect_local_defs_expr(e, out),
                    none => {},
                }
            },
            HStmt::ExprStmt { expr, .. } => {
                collect_local_defs_expr(expr, out)
            },
            HStmt::Return { value, .. } => {
                match value {
                    some(v) => collect_local_defs_expr(v, out),
                    none => {},
                }
            },
            HStmt::Assign { value, .. } => {
                collect_local_defs_expr(value, out)
            },
            HStmt::Break { .. } => {},
            HStmt::Continue { .. } => {},
            HStmt::Drop { .. } => {},
            HStmt::Dup { .. } => {},
        }
    }
}

fn collect_local_defs_expr(expr: HExpr, mut out: Set<Str>) {
    match expr {
        HExpr::Block { stmts, tail, .. } => {
            collect_local_defs_stmts(stmts, out)
            match tail {
                some(t) => collect_local_defs_expr(t, out),
                none => {},
            }
        },
        HExpr::IfExpr { then_branch, else_branch, .. } => {
            collect_local_defs_expr(then_branch, out)
            match else_branch {
                some(e) => collect_local_defs_expr(e, out),
                none => {},
            }
        },
        HExpr::MatchExpr { arms, .. } => {
            for arm in arms {
                let mut pat_names: List<Str> = []
                pattern_binding_names(arm.pattern, pat_names)
                for pn in pat_names { out.insert(pn) }
                collect_local_defs_expr(arm.body, out)
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            collect_local_defs_expr(body, out)
            for arm in arms {
                let mut pat_names: List<Str> = []
                pattern_binding_names(arm.pattern, pat_names)
                for pn in pat_names { out.insert(pn) }
                collect_local_defs_expr(arm.body, out)
            }
        },
        HExpr::Lambda { .. } => {
            // Lambda has its own scope — do not collect its internals
        },
        _ => {},
    }
}

// ============================================================
// Main entry: transform all declarations
// ============================================================

pub fn perceus_transform(program: HProgram) -> HProgram {
    // B-091: `boxed_vars` (def_ids of `let mut` vars auto-boxed for write-through
    // closure capture) is threaded through the RC pass so the Assign old-value
    // Drop is suppressed for them — a boxed write mutates `cell.value`, it does
    // NOT consume/free the shared cell pointer.
    let new_decls = transform_decls(program.decls, program.boxed_vars)
    HProgram {
        decls: new_decls,
        derived_impls: program.derived_impls,
        boxed_vars: program.boxed_vars
    }
}

fn transform_decls(decls: List<HDecl>, boxed: Set<Int>) -> List<HDecl> {
    let mut result: List<HDecl> = []
    for d in decls {
        result.push(transform_decl(d, boxed))
    }
    result
}

fn transform_decl(decl: HDecl, boxed: Set<Int>) -> HDecl {
    match decl {
        HDecl::Fn { name, def_id, type_params, params, return_type, effects, body, is_pub, trait_bounds, span } => {
            let new_body = transform_fn_body(params, body, boxed)
            HDecl::Fn {
                name: name, def_id: def_id, type_params: type_params,
                params: params, return_type: return_type, effects: effects,
                body: new_body, is_pub: is_pub, trait_bounds: trait_bounds, span: span
            }
        },
        HDecl::Impl { target_type, type_params, trait_name, methods, assoc_types, span } => {
            let new_methods = transform_decls(methods, boxed)
            HDecl::Impl {
                target_type: target_type, type_params: type_params,
                trait_name: trait_name, methods: new_methods,
                assoc_types: assoc_types, span: span
            }
        },
        HDecl::Test { description, body, span } => {
            // Transform test bodies as parameterless functions
            let new_body = transform_fn_body([], body, boxed)
            HDecl::Test { description: description, body: new_body, span: span }
        },
        HDecl::Const { name, def_id, ty, init, is_pub, span } => {
            // Transform const initializer.
            // B-081: const init root is a flush point. locals is empty here, so
            // dups will be empty in practice, but the flush makes the invariant
            // explicit and is harmless (flush_dups_into_expr is a no-op on []).
            let live: Set<Str> = set_new()
            let locals: Set<Str> = set_new()
            let result = rc_expr(init, live, locals, boxed)
            let init_flushed = flush_dups_into_expr(result.expr, result.dups)
            HDecl::Const { name: name, def_id: def_id, ty: ty, init: init_flushed, is_pub: is_pub, span: span }
        },
        HDecl::ModBlock { name, decls: mod_decls, is_pub, span } => {
            HDecl::ModBlock { name: name, decls: transform_decls(mod_decls, boxed), is_pub: is_pub, span: span }
        },
        // Non-function declarations pass through unchanged
        HDecl::Struct { .. } => decl,
        HDecl::Enum { .. } => decl,
        HDecl::Effect { .. } => decl,
        HDecl::Trait { .. } => decl,
        HDecl::ExternFn { .. } => decl,
        HDecl::ExternType { .. } => decl,
        HDecl::TypeAlias { .. } => decl,
        HDecl::Sig { .. } => decl,
    }
}

// ============================================================
// Transform a function body: analyze body, then drop unused params
// ============================================================

fn transform_fn_body(params: List<HParam>, body: HExpr, boxed: Set<Int>) -> HExpr {
    // Collect all locally-defined variable names in this function
    let mut locals: Set<Str> = set_new()
    for p in params { locals.insert(p.name) }
    collect_local_defs_expr(body, locals)

    let live: Set<Str> = set_new()
    let result = rc_expr(body, live, locals, boxed)
    let remaining_live = result.live

    // B-081: the function body root is a statement-sequence boundary. Any dups
    // the body reports must be emitted at the function entry (after param drops,
    // before the body executes). Flush them into the body expression first.
    let body_flushed = flush_dups_into_expr(result.expr, result.dups)

    // Parameters that were NOT consumed in the body need to be dropped.
    // Insert drops at the beginning of the function body.
    let mut param_drops: List<HStmt> = []
    for p in params {
        if remaining_live.contains(p.name) == false && rc_name_skippable(p.name) == false {
            param_drops.push(HStmt::Drop { name: p.name, ty: p.ty, span: synthetic_span() })
        }
    }

    if param_drops.len() == 0 {
        return body_flushed
    }

    // Wrap body in a block that starts with param drops
    match body_flushed {
        HExpr::Block { stmts, tail, ty, effects, span } => {
            let new_stmts = param_drops.concat(stmts)
            HExpr::Block { stmts: new_stmts, tail: tail, ty: ty, effects: effects, span: span }
        },
        _ => {
            // Wrap non-block body: drops + original expr as tail
            let ty = hexpr_type(body_flushed)
            let effects = hexpr_effects(body_flushed)
            let span = hexpr_span(body_flushed)
            HExpr::Block { stmts: param_drops, tail: some(body_flushed), ty: ty, effects: effects, span: span }
        },
    }
}

// hexpr_effects is imported from hir

// ============================================================
// Result type for RC transformations
// ============================================================

struct RcResult {
    expr: HExpr,
    live: Set<Str>,
    // Names of variables that must be `dup`-ed before this expression is
    // evaluated.  B-081: instead of wrapping non-last-use Idents in a Block
    // (which breaks codegen assumptions about callee / assign-target shapes),
    // a non-last-use reports the dup need upward via `dups`.  The dup is then
    // emitted as a statement-level HStmt::Dup at the nearest statement-sequence
    // boundary, or flushed into a conditional branch body before that branch.
    // List (not Set): the same variable may need dup-ing multiple times within
    // one expression (e.g. f(x, x, x) needs 2 dups).
    dups: List<Str>
}

struct RcStmtsResult {
    stmts: List<HStmt>,
    live: Set<Str>
}

// ============================================================
// RC transform for a list of statements (backward traversal)
// ============================================================

fn rc_stmts(stmts: List<HStmt>, live: Set<Str>, locals: Set<Str>, boxed: Set<Int>) -> RcStmtsResult {
    // Process statements from last to first.
    // We iterate forward over a reversed copy, building the result list,
    // then reverse the result at the end.
    let mut result: List<HStmt> = []
    let mut cur_live = live

    // Walk backward: index from len-1 down to 0
    let mut i = stmts.len() - 1
    while i >= 0 {
        match stmts.get(i) {
            some(stmt) => {
                let r = rc_stmt(stmt, cur_live, locals, boxed)
                // r.stmts are in forward order for this stmt position;
                // prepend them (they go before anything we've accumulated)
                // Since we're building backward, we push them and reverse later
                let mut j = r.stmts.len() - 1
                while j >= 0 {
                    match r.stmts.get(j) {
                        some(s) => result.push(s),
                        none => {},
                    }
                    j = j - 1
                }
                cur_live = r.live
            },
            none => {},
        }
        i = i - 1
    }

    result.reverse()
    RcStmtsResult { stmts: result, live: cur_live }
}

// ============================================================
// RC transform for a single statement
// Returns: (replacement stmts, updated live set)
// ============================================================

fn rc_stmt(stmt: HStmt, live: Set<Str>, locals: Set<Str>, boxed: Set<Int>) -> RcStmtsResult {
    match stmt {
        HStmt::Let { name, name_span, def_id, ty, init, span } => {
            // Process the initializer expression
            let init_result = rc_expr(init, live, locals, boxed)
            let mut cur_live = init_result.live

            // The variable `name` is defined here.
            // If cur_live contains `name`, it means the variable is used later (backward analysis).
            // If not, the variable is never used after this point → insert Drop right after Let.
            // B-081: flush the initializer's reported dups as statements emitted
            // BEFORE the Let (so they execute before the init is evaluated).
            let mut out: List<HStmt> = dups_to_stmts(init_result.dups)
            out.push(HStmt::Let { name: name, name_span: name_span, def_id: def_id, ty: ty, init: init_result.expr, span: span })

            if cur_live.contains(name) {
                // Variable is used later — remove from live set (it was just defined)
                cur_live.remove(name)
            } else if rc_name_skippable(name) == false {
                // Variable is never used → drop immediately after definition
                out.push(HStmt::Drop { name: name, ty: ty, span: synthetic_span() })
            }

            RcStmtsResult { stmts: out, live: cur_live }
        },

        HStmt::Var { name, name_span, def_id, ty, init, span } => {
            let init_result = rc_expr(init, live, locals, boxed)
            let mut cur_live = init_result.live
            let mut out: List<HStmt> = dups_to_stmts(init_result.dups)
            out.push(HStmt::Var { name: name, name_span: name_span, def_id: def_id, ty: ty, init: init_result.expr, span: span })

            if cur_live.contains(name) {
                cur_live.remove(name)
            } else if rc_name_skippable(name) == false {
                out.push(HStmt::Drop { name: name, ty: ty, span: synthetic_span() })
            }

            RcStmtsResult { stmts: out, live: cur_live }
        },

        HStmt::Assign { target, value, span } => {
            // Target is an L-value (write destination) — do NOT rc_expr it.
            // Only the value (R-value) is consumed.
            let val_result = rc_expr(value, live, locals, boxed)
            // B-081: flush the value's reported dups before the old-value Drop
            // and the Assign itself.
            let mut out: List<HStmt> = dups_to_stmts(val_result.dups)
            let mut result_live = val_result.live

            // Drop the old value before the assignment overwrites it.
            // B-091: EXCEPT when the target is an auto-boxed mut-cell.  A write to
            // such a var stores into `cell.value` (LLVM codegen), it does NOT
            // overwrite the alloca's cell pointer — so dropping `name` here would
            // `ring_drop` the *shared* cell ptr on every write, freeing a cell the
            // outer scope and the capturing closure still hold (deterministic UAF).
            // The old `cell.value` is leaked, matching the L0 struct-field-assign
            // convention (field assigns also do not drop the overwritten value).
            match target {
                HExpr::Ident { name, def_id, ty, .. } => {
                    let is_boxed = match def_id {
                        some(did) => boxed.contains(did),
                        none => false,
                    }
                    if is_boxed == false {
                        out.push(HStmt::Drop { name: name, ty: ty, span: synthetic_span() })
                        // #134: the assign READS (drops) the old value, so the
                        // target is live entering this statement.  Mark it live so
                        // reads of it in EARLIER statements borrow (dup) instead of
                        // moving the value out — otherwise the last read before the
                        // reassign consumes the box and this drop double-frees it
                        // (parse_expr_bp's `last_was_comparison` in the bp loop).
                        if rc_name_skippable(name) == false { result_live.insert(name) }
                    }
                },
                _ => {},
            }
            out.push(HStmt::Assign { target: target, value: val_result.expr, span: span })

            RcStmtsResult { stmts: out, live: result_live }
        },

        HStmt::ExprStmt { expr, span } => {
            let r = rc_expr(expr, live, locals, boxed)
            // B-081: flush reported dups before the expression statement.
            let mut out: List<HStmt> = dups_to_stmts(r.dups)
            out.push(HStmt::ExprStmt { expr: r.expr, span: span })
            RcStmtsResult { stmts: out, live: r.live }
        },

        HStmt::Return { value, span } => {
            match value {
                some(v) => {
                    // #134: drop the vars owned at the return point — i.e. the
                    // INCOMING live set — NOT r.live.  r.live additionally contains
                    // the vars the return VALUE consumes as a last use (moved into
                    // the call / the returned struct); dropping those double-frees
                    // (e.g. `return self.make_token(.., end)` moves `end` into the
                    // Token, but r.live still lists it).  A var that v dups instead
                    // (non-last use) is in the incoming live set, so its original
                    // reference is still dropped here — balance preserved.  Clone
                    // before rc_expr in case it mutates the live set in place.
                    let live_at_return = set_clone(live)
                    let r = rc_expr(v, live, locals, boxed)
                    // B-081: flush the return value's reported dups before both
                    // the drop-all-live and the Return.
                    let mut out: List<HStmt> = dups_to_stmts(r.dups)
                    // B-085: sort so the drop order is backend-independent.
                    for name in sorted_set_names(live_at_return) {
                        // We don't have the type info for these vars easily here,
                        // so use UnitType as a placeholder. The LLVM codegen for Drop
                        // uses the variable's actual runtime type via the refcount header.
                        out.push(HStmt::Drop { name: name, ty: Type::UnitType, span: synthetic_span() })
                    }
                    out.push(HStmt::Return { value: some(r.expr), span: span })
                    // After return, live set is empty (dead code)
                    RcStmtsResult { stmts: out, live: set_new() }
                },
                none => {
                    // void return — drop all live variables
                    let mut out: List<HStmt> = []
                    // B-085: sort so the drop-all-live order is backend-independent.
                    for name in sorted_set_names(live) {
                        out.push(HStmt::Drop { name: name, ty: Type::UnitType, span: synthetic_span() })
                    }
                    out.push(HStmt::Return { value: none, span: span })
                    RcStmtsResult { stmts: out, live: set_new() }
                },
            }
        },

        HStmt::While { condition, body, span } => {
            // Conservative for loops: any external variable used inside the loop
            // body or condition gets a Dup before the loop, since each iteration
            // may consume it.
            let mut loop_vars: Set<Str> = set_new()
            collect_expr_vars(condition, loop_vars)
            collect_expr_vars(body, loop_vars)

            // B-083 #3: variables captured by closures created inside the loop
            // need a dup PER ITERATION (each iteration builds a fresh closure
            // taking its own reference), not the single conservative pre-loop dup.
            // Restrict to owned locals — globals/functions are not RC-tracked.
            let mut loop_captures: Set<Str> = set_new()
            collect_lambda_captures_expr(condition, loop_captures)
            collect_lambda_captures_expr(body, loop_captures)
            let mut local_loop_captures: Set<Str> = set_new()
            for v in loop_captures {
                if locals.contains(v) { local_loop_captures.insert(v) }
            }

            // Seed the body's incoming live set with the loop captures so each
            // lambda's last-use check treats them as live → it reports a dup via
            // the dups channel (flushed into the body = per-iteration) instead of
            // moving the single owned reference into the first iteration's
            // closure (which single-pass backward analysis would otherwise do,
            // leaving later iterations + the post-loop drop double-freeing).
            let mut seeded_live = set_clone(live)
            for v in local_loop_captures { seeded_live.insert(v) }

            // Transform body and condition
            let body_result = rc_expr(body, seeded_live, locals, boxed)
            let cond_result = rc_expr(condition, body_result.live, locals, boxed)
            let mut cur_live = cond_result.live

            // B-081: condition and body are re-evaluated each iteration, so any
            // dups they report must be flushed INTO those expressions (so they
            // execute per iteration), not hoisted before the loop.  This is
            // orthogonal to the conservative loop-var dup below: the conservative
            // dup handles loop-carried consumption (dup once outside the loop for
            // values consumed across iterations); the flush handles multi-use
            // balancing within a single iteration.  They do not double-dup.
            let cond_flushed = flush_dups_into_expr(cond_result.expr, cond_result.dups)
            let body_flushed = flush_dups_into_expr(body_result.expr, body_result.dups)

            // Restore the seeded captures' liveness to their true pre-loop state:
            // seeding only forced per-iteration dups, it must not make the
            // surrounding scope believe a capture is live after the loop (which
            // would suppress its drop and leak it).  The loop neither defines nor
            // outlives these outer bindings, so their post-loop liveness equals
            // their pre-loop liveness.
            for v in local_loop_captures {
                if live.contains(v) { cur_live.insert(v) } else { cur_live.remove(v) }
            }

            // External vars used in the loop that are still live → need Dup,
            // EXCEPT loop captures: those are already dup-ed per iteration via the
            // body flush, so a conservative pre-loop dup would over-count (leak).
            let mut out: List<HStmt> = []
            // B-085: sort loop-var dups so the pre-loop dup order is backend-independent.
            for v in sorted_set_names(loop_vars) {
                if cur_live.contains(v) && local_loop_captures.contains(v) == false && rc_name_skippable(v) == false {
                    out.push(HStmt::Dup { name: v, ty: Type::UnitType, span: synthetic_span() })
                }
            }

            out.push(HStmt::While { condition: cond_flushed, body: body_flushed, span: span })
            RcStmtsResult { stmts: out, live: cur_live }
        },

        HStmt::ForIn { binding, binding_span, def_id, destructure, iterable, body, iterable_type_name, iter_type_name, span } => {
            // Similar to While — conservative Dup for external vars
            let mut loop_vars: Set<Str> = set_new()
            collect_expr_vars(iterable, loop_vars)
            collect_expr_vars(body, loop_vars)

            // B-083 #3: closures created inside the loop body capture outer
            // owned locals; each iteration's fresh closure needs its own dup of
            // the capture.  Mirror the While handling: seed + per-iteration flush
            // + exclude from the conservative pre-loop dup.  The for-in binding
            // (and any destructure names) are per-iteration locals, never outer
            // captures, so they are naturally excluded by the locals filter below
            // only if shadowed — guard explicitly for safety.
            let mut loop_captures: Set<Str> = set_new()
            collect_lambda_captures_expr(body, loop_captures)
            let mut local_loop_captures: Set<Str> = set_new()
            for v in loop_captures {
                if locals.contains(v) && v != binding { local_loop_captures.insert(v) }
            }
            match destructure {
                some(ds) => {
                    for d in ds { local_loop_captures.remove(d.name) }
                },
                none => {},
            }

            let mut seeded_live = set_clone(live)
            for v in local_loop_captures { seeded_live.insert(v) }

            let body_result = rc_expr(body, seeded_live, locals, boxed)
            let iter_result = rc_expr(iterable, body_result.live, locals, boxed)
            let mut cur_live = iter_result.live

            // Remove the binding variable (it's defined by the for-in)
            cur_live.remove(binding)
            match destructure {
                some(ds) => {
                    for d in ds { cur_live.remove(d.name) }
                },
                none => {},
            }

            // Restore loop captures to their true pre-loop liveness (see While).
            for v in local_loop_captures {
                if live.contains(v) { cur_live.insert(v) } else { cur_live.remove(v) }
            }

            // B-081: the iterable is evaluated exactly once (before the loop),
            // so its dups are emitted before the ForIn statement (alongside the
            // conservative loop-var dup).  The body is re-evaluated per
            // iteration, so its dups flush INTO the body expression.
            let mut out: List<HStmt> = dups_to_stmts(iter_result.dups)
            // B-085: sort loop-var dups so the pre-loop dup order is backend-independent.
            for v in sorted_set_names(loop_vars) {
                if cur_live.contains(v) && local_loop_captures.contains(v) == false && rc_name_skippable(v) == false {
                    out.push(HStmt::Dup { name: v, ty: Type::UnitType, span: synthetic_span() })
                }
            }

            let body_flushed = flush_dups_into_expr(body_result.expr, body_result.dups)
            out.push(HStmt::ForIn {
                binding: binding, binding_span: binding_span, def_id: def_id,
                destructure: destructure, iterable: iter_result.expr,
                body: body_flushed, iterable_type_name: iterable_type_name,
                iter_type_name: iter_type_name, span: span
            })
            RcStmtsResult { stmts: out, live: cur_live }
        },

        HStmt::Break { span } => {
            RcStmtsResult { stmts: [HStmt::Break { span: span }], live: live }
        },

        HStmt::Continue { span } => {
            RcStmtsResult { stmts: [HStmt::Continue { span: span }], live: live }
        },

        HStmt::LetDestructure { pattern, bindings, init, span } => {
            let init_result = rc_expr(init, live, locals, boxed)
            let mut cur_live = init_result.live

            // Collect binding names
            let mut bound: List<Str> = []
            for b in bindings { bound.push(b.name) }

            // B-081: flush the init's reported dups before the destructure.
            let mut out: List<HStmt> = dups_to_stmts(init_result.dups)
            out.push(HStmt::LetDestructure { pattern: pattern, bindings: bindings, init: init_result.expr, span: span })

            // Drop any bound variables that are not live
            for b in bindings {
                if cur_live.contains(b.name) {
                    cur_live.remove(b.name)
                } else if rc_name_skippable(b.name) == false {
                    out.push(HStmt::Drop { name: b.name, ty: b.ty, span: synthetic_span() })
                }
            }

            RcStmtsResult { stmts: out, live: cur_live }
        },

        HStmt::IfLet { pattern, expr, then_block, else_block, span } => {
            // Conditional-evaluation boundary: then/else are conditionally
            // evaluated, so their dups flush INTO each branch body (before
            // balancing).  The scrutinee (always evaluated) emits its dups as
            // statements before the IfLet.
            let then_result = rc_expr(then_block, set_clone(live), locals, boxed)
            let else_result = match else_block {
                some(eb) => {
                    let r = rc_expr(eb, set_clone(live), locals, boxed)
                    some(r)
                },
                none => none,
            }

            let live_then = then_result.live
            let live_else = match else_result {
                some(r) => r.live,
                none => set_clone(live),
            }

            // Flush branch dups before balancing.
            let then_flushed = flush_dups_into_expr(then_result.expr, then_result.dups)

            // Branch balance: insert drops for variables live in one branch but not the other.
            // #134: diverging branches (return/break/continue) self-clean — skip balancing.
            let balanced_then = if expr_diverges(then_result.expr) {
                then_flushed
            } else {
                balance_branch(then_flushed, live_then, live_else)
            }
            let balanced_else = match else_result {
                some(r) => {
                    let else_flushed = flush_dups_into_expr(r.expr, r.dups)
                    if expr_diverges(r.expr) {
                        some(else_flushed)
                    } else {
                        some(balance_branch(else_flushed, live_else, live_then))
                    }
                },
                none => {
                    // No else branch — need to drop vars that are live in then but not here
                    let drops = make_drop_list(live_then.difference(live_else))
                    if drops.len() > 0 {
                        let ty = hexpr_type(then_result.expr)
                        let effects = hexpr_effects(then_result.expr)
                        some(HExpr::Block { stmts: drops, tail: none, ty: Type::UnitType,
                            effects: effects, span: synthetic_span() })
                    } else {
                        none
                    }
                },
            }

            let merged_live = live_then.union(live_else)

            // Collect bindings introduced by pattern
            let mut pat_names: List<Str> = []
            pattern_binding_names(pattern, pat_names)
            let mut final_live = merged_live
            for pn in pat_names { final_live.remove(pn) }

            // Transform the scrutinee expression
            let expr_result = rc_expr(expr, final_live, locals, boxed)

            // B-081: flush the scrutinee's reported dups before the IfLet stmt.
            let mut out: List<HStmt> = dups_to_stmts(expr_result.dups)
            out.push(HStmt::IfLet {
                pattern: pattern, expr: expr_result.expr,
                then_block: balanced_then, else_block: balanced_else, span: span
            })

            RcStmtsResult {
                stmts: out,
                live: expr_result.live
            }
        },

        // Drop and Dup should not appear in input (we are inserting them)
        HStmt::Drop { .. } => RcStmtsResult { stmts: [stmt], live: live },
        HStmt::Dup { .. } => RcStmtsResult { stmts: [stmt], live: live },
    }
}

// ============================================================
// RC transform for expressions
// ============================================================

fn rc_expr(expr: HExpr, mut live: Set<Str>, locals: Set<Str>, boxed: Set<Int>) -> RcResult {
    match expr {
        HExpr::Ident { name, resolved_name, def_id, dict_closure_dicts, ty, effects, span } => {
            // Only track RC for locally-defined variables (params + let/var bindings).
            // Global functions, extern fns, trait methods etc. are not heap-allocated
            // owned values and must not be wrapped in Dup/Drop.
            if !locals.contains(name) {
                RcResult { expr: expr, live: live, dups: [] }
            } else if live.contains(name) {
                // Non-last use of a local variable — need Dup.
                // B-081: do NOT wrap in a Block.  Return the bare Ident and
                // report the dup need upward via `dups`; it will be emitted as
                // a statement-level HStmt::Dup at the nearest boundary.
                RcResult { expr: expr, live: live, dups: [name] }
            } else {
                // Last use — consume without Dup. Add to live set.
                live.insert(name)
                RcResult {
                    expr: HExpr::Ident { name: name, resolved_name: resolved_name,
                        def_id: def_id, dict_closure_dicts: dict_closure_dicts,
                        ty: ty, effects: effects, span: span },
                    live: live,
                    dups: []
                }
            }
        },

        HExpr::IntLit { .. } => RcResult { expr: expr, live: live, dups: [] },
        HExpr::FloatLit { .. } => RcResult { expr: expr, live: live, dups: [] },
        HExpr::StrLit { .. } => RcResult { expr: expr, live: live, dups: [] },
        HExpr::BoolLit { .. } => RcResult { expr: expr, live: live, dups: [] },

        HExpr::BinOp { op, left, right, eq_dispatch, ord_dispatch, ty, effects, span } => {
            // Process right first, then left (right-to-left evaluation for backward analysis)
            let r_result = rc_expr(right, live, locals, boxed)
            let l_result = rc_expr(left, r_result.live, locals, boxed)

            // Short-circuit operators (&&, ||): the RHS is conditionally
            // evaluated, so its dups must be flushed INTO the RHS expression
            // rather than reported upward.  Only the (unconditional) LHS dups
            // propagate.  Non-short-circuit operators evaluate both sides
            // unconditionally, so their dups concatenate (left ++ right, the
            // backward-traversal order is right-then-left but evaluation /
            // reporting order is left-to-right).
            match op {
                BinOp::And => {
                    let new_right = flush_dups_into_expr(r_result.expr, r_result.dups)
                    RcResult {
                        expr: HExpr::BinOp { op: op, left: l_result.expr, right: new_right,
                            eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
                            ty: ty, effects: effects, span: span },
                        live: l_result.live,
                        dups: l_result.dups
                    }
                },
                BinOp::Or => {
                    let new_right = flush_dups_into_expr(r_result.expr, r_result.dups)
                    RcResult {
                        expr: HExpr::BinOp { op: op, left: l_result.expr, right: new_right,
                            eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
                            ty: ty, effects: effects, span: span },
                        live: l_result.live,
                        dups: l_result.dups
                    }
                },
                _ => {
                    RcResult {
                        expr: HExpr::BinOp { op: op, left: l_result.expr, right: r_result.expr,
                            eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
                            ty: ty, effects: effects, span: span },
                        live: l_result.live,
                        dups: l_result.dups.concat(r_result.dups)
                    }
                },
            }
        },

        HExpr::UnaryOp { op, operand, ty, effects, span } => {
            let r = rc_expr(operand, live, locals, boxed)
            RcResult {
                expr: HExpr::UnaryOp { op: op, operand: r.expr, ty: ty, effects: effects, span: span },
                live: r.live,
                dups: r.dups
            }
        },

        HExpr::Call { callee, args, type_args, resolved_dicts, dict_dispatch, ty, effects, span } => {
            // Process args right-to-left, then callee
            let mut cur_live = live
            let mut new_args: List<HExpr> = []
            // Collect arg dups in reverse (backward traversal); reversed to
            // forward order below.  All args are evaluated unconditionally.
            let mut arg_dups_rev: List<Str> = []
            // Build in reverse order
            let mut i = args.len() - 1
            while i >= 0 {
                match args.get(i) {
                    some(a) => {
                        let r = rc_expr(a, cur_live, locals, boxed)
                        new_args.push(r.expr)
                        for d in r.dups { arg_dups_rev.push(d) }
                        cur_live = r.live
                    },
                    none => {},
                }
                i = i - 1
            }
            new_args.reverse()
            arg_dups_rev.reverse()

            let callee_result = rc_expr(callee, cur_live, locals, boxed)
            RcResult {
                expr: HExpr::Call { callee: callee_result.expr, args: new_args,
                    type_args: type_args, resolved_dicts: resolved_dicts,
                    dict_dispatch: dict_dispatch, ty: ty, effects: effects, span: span },
                live: callee_result.live,
                dups: arg_dups_rev.concat(callee_result.dups)
            }
        },

        HExpr::FieldAccess { receiver, field, ty, effects, span } => {
            let r = rc_expr(receiver, live, locals, boxed)
            RcResult {
                expr: HExpr::FieldAccess { receiver: r.expr, field: field, ty: ty, effects: effects, span: span },
                live: r.live,
                dups: r.dups
            }
        },

        HExpr::StructLit { name, type_args, fields, spread, ty, effects, span } => {
            let mut cur_live = live
            // Process spread first (if any). All subexprs unconditionally evaluated.
            let mut spread_dups: List<Str> = []
            let new_spread = match spread {
                some(s) => {
                    let r = rc_expr(s, cur_live, locals, boxed)
                    cur_live = r.live
                    spread_dups = r.dups
                    some(r.expr)
                },
                none => none,
            }
            // Process fields right-to-left
            let mut new_fields: List<HStructFieldInit> = []
            let mut field_dups_rev: List<Str> = []
            let mut i = fields.len() - 1
            while i >= 0 {
                match fields.get(i) {
                    some(f) => {
                        let r = rc_expr(f.value, cur_live, locals, boxed)
                        new_fields.push(HStructFieldInit { name: f.name, value: r.expr })
                        for d in r.dups { field_dups_rev.push(d) }
                        cur_live = r.live
                    },
                    none => {},
                }
                i = i - 1
            }
            new_fields.reverse()
            field_dups_rev.reverse()

            RcResult {
                expr: HExpr::StructLit { name: name, type_args: type_args, fields: new_fields,
                    spread: new_spread, ty: ty, effects: effects, span: span },
                live: cur_live,
                dups: spread_dups.concat(field_dups_rev)
            }
        },

        HExpr::NamedVariantConstruct { enum_name, variant_name, fields, spread, ty, effects, span } => {
            let mut cur_live = live
            let mut spread_dups: List<Str> = []
            let new_spread = match spread {
                some(s) => {
                    let r = rc_expr(s, cur_live, locals, boxed)
                    cur_live = r.live
                    spread_dups = r.dups
                    some(r.expr)
                },
                none => none,
            }
            let mut new_fields: List<HStructFieldInit> = []
            let mut field_dups_rev: List<Str> = []
            let mut i = fields.len() - 1
            while i >= 0 {
                match fields.get(i) {
                    some(f) => {
                        let r = rc_expr(f.value, cur_live, locals, boxed)
                        new_fields.push(HStructFieldInit { name: f.name, value: r.expr })
                        for d in r.dups { field_dups_rev.push(d) }
                        cur_live = r.live
                    },
                    none => {},
                }
                i = i - 1
            }
            new_fields.reverse()
            field_dups_rev.reverse()

            RcResult {
                expr: HExpr::NamedVariantConstruct { enum_name: enum_name, variant_name: variant_name,
                    fields: new_fields, spread: new_spread, ty: ty, effects: effects, span: span },
                live: cur_live,
                dups: spread_dups.concat(field_dups_rev)
            }
        },

        HExpr::Block { stmts, tail, ty, effects, span } => {
            // Statement-sequence boundary: absorb dups here, report none upward.
            // Process tail first (it's the last thing evaluated).
            let mut cur_live = live
            let mut tail_dups: List<Str> = []
            let new_tail = match tail {
                some(t) => {
                    let r = rc_expr(t, cur_live, locals, boxed)
                    cur_live = r.live
                    tail_dups = r.dups
                    some(r.expr)
                },
                none => none,
            }
            // Then process statements backward
            let stmts_result = rc_stmts(stmts, cur_live, locals, boxed)

            // The tail's dups must execute after all statements but before the
            // tail expression — append them to the end of the statement list.
            let final_stmts = stmts_result.stmts.concat(dups_to_stmts(tail_dups))

            RcResult {
                expr: HExpr::Block { stmts: final_stmts, tail: new_tail,
                    ty: ty, effects: effects, span: span },
                live: stmts_result.live,
                dups: []
            }
        },

        HExpr::IfExpr { condition, then_branch, else_branch, ty, effects, span } => {
            // Conditional-evaluation boundary: the then/else bodies are only
            // conditionally evaluated, so their dups must be flushed INTO the
            // branch body (before balancing).  Only the condition (always
            // evaluated) reports its dups upward.
            let then_result = rc_expr(then_branch, set_clone(live), locals, boxed)
            let else_result = match else_branch {
                some(eb) => {
                    let r = rc_expr(eb, set_clone(live), locals, boxed)
                    some(r)
                },
                none => none,
            }

            let live_then = then_result.live
            let live_else = match else_result {
                some(r) => r.live,
                none => set_clone(live),
            }

            // Flush dups into each branch body BEFORE balancing.
            // #134: skip balancing a diverging branch — it cleans up via its own
            // return/break/continue, so prepended balance drops would double-free.
            let then_flushed = flush_dups_into_expr(then_result.expr, then_result.dups)
            let balanced_then = if expr_diverges(then_result.expr) {
                then_flushed
            } else {
                balance_branch(then_flushed, live_then, live_else)
            }
            let balanced_else = match else_result {
                some(r) => {
                    let else_flushed = flush_dups_into_expr(r.expr, r.dups)
                    if expr_diverges(r.expr) {
                        some(else_flushed)
                    } else {
                        some(balance_branch(else_flushed, live_else, live_then))
                    }
                },
                none => else_branch,
            }

            let merged_live = live_then.union(live_else)

            // Transform condition with merged live set
            let cond_result = rc_expr(condition, merged_live, locals, boxed)

            RcResult {
                expr: HExpr::IfExpr { condition: cond_result.expr,
                    then_branch: balanced_then, else_branch: balanced_else,
                    ty: ty, effects: effects, span: span },
                live: cond_result.live,
                dups: cond_result.dups
            }
        },

        HExpr::MatchExpr { scrutinee, arms, ty, effects, span } => {
            // Conditional-evaluation boundary: each arm's body and guard are
            // only conditionally evaluated, so their dups are flushed INTO the
            // respective expressions.  Only the scrutinee (always evaluated)
            // reports its dups upward.
            //
            // GUARD FALL-THROUGH (B-083): a guarded arm `P if g => body` only
            // commits when both the pattern matches AND `g` is true; a false `g`
            // falls through to re-test the NEXT arm's pattern+guard.  So the
            // guard sits on a control-flow fork with two live-out edges:
            //   * guard-true  -> this arm's body         (needs body_result.live)
            //   * guard-false -> the next arm's entry     (needs fallthrough_live)
            // The guard must therefore preserve (dup, not move) any variable
            // needed on EITHER edge — moving a fall-through-needed variable would
            // be a use-after-free in a later arm.  We model this by analysing the
            // guard with live-out = union(body_result.live, fallthrough_live) and
            // walking the arms in REVERSE so each arm sees the next arm's entry
            // live set.  The last arm has an empty fallthrough_live (falling past
            // it is a non-exhaustive panic / unreachable).
            //
            // For an UNGUARDED arm fallthrough_live is irrelevant: the pattern
            // test has no RC side effect, so the arm behaves exactly as before
            // (arm_ext = body_result.live minus bindings), preserving the existing
            // flat-merge balancing for non-guarded matches.
            // --- Phase 1 (reverse): gather each arm's body live-in and external
            // live-in, chaining fallthrough_live so each arm sees the next arm's
            // entry needs.  The arm_ext SET membership is what feeds merged_live;
            // it is independent of the guard's dup/move bookkeeping (a referenced
            // variable is referenced regardless of live-out), so this single pass
            // yields a stable merged_live.
            let mut arm_exts: List<Set<Str>> = []     // forward order
            let mut fallthrough_live: Set<Str> = set_new()
            // Pre-size with placeholders so we can write by index in reverse.
            for arm in arms { arm_exts.push(set_new()) }
            let mut ai = arms.len() - 1
            while ai >= 0 {
                match arms.get(ai) {
                    some(arm) => {
                        let body_result = rc_expr(arm.body, set_clone(live), locals, boxed)
                        let mut arm_ext = match arm.guard {
                            some(g) => {
                                let guard_live_out = body_result.live.union(fallthrough_live)
                                let gr = rc_expr(g, guard_live_out, locals, boxed)
                                set_clone(gr.live)
                            },
                            none => set_clone(body_result.live),
                        }
                        // Pattern bindings are arm-local: they do not exist at the
                        // arm's entry / fall-through point, so they are excluded
                        // from the external live set propagated to earlier arms.
                        let mut pat_names: List<Str> = []
                        pattern_binding_names(arm.pattern, pat_names)
                        for pn in pat_names { arm_ext.remove(pn) }

                        arm_exts.set(ai, set_clone(arm_ext))
                        fallthrough_live = arm_ext
                    },
                    none => {},
                }
                ai = ai - 1
            }

            // merged_live = union of every arm's external live-in.  This is the
            // set the whole match consumes (the scrutinee is analysed against it).
            // Because earlier arms' arm_ext already absorb later arms' needs via
            // fallthrough_live, the first arm's arm_ext alone equals this union;
            // the explicit union is kept for clarity and to match the previous
            // (unguarded) behaviour exactly.
            let mut merged_live: Set<Str> = set_new()
            for ae in arm_exts {
                merged_live = merged_live.union(ae)
            }

            // --- Phase 2 (forward): emit each arm.  Guards are re-analysed with
            // live-out = union(merged_live, body_result.live): every variable the
            // match consumes (merged_live) is kept alive (dup-ed, never moved)
            // across the guard fork, so the owned set entering EVERY arm body is
            // merged_live (plus this arm's bindings the body uses).  That makes
            // the body balance below uniformly safe — it can never drop a variable
            // the guard already moved.  Moving only this-arm's bindings the body
            // does not use is fine (they are arm-local).
            let mut balanced_arms: List<HMatchArm> = []
            for i in 0..arms.len() {
                match arms.get(i) {
                    some(arm) => {
                        let body_result = rc_expr(arm.body, set_clone(live), locals, boxed)
                        let new_guard = match arm.guard {
                            some(g) => {
                                let guard_live_out = merged_live.union(body_result.live)
                                let gr = rc_expr(g, guard_live_out, locals, boxed)
                                some(flush_dups_into_expr(gr.expr, gr.dups))
                            },
                            none => none,
                        }
                        // Balance the BODY (guard-true / pattern-matched path):
                        // drop everything live entering the match (merged_live)
                        // that this body does not itself keep alive.  Covers vars
                        // other arms need AND vars this arm's guard kept purely for
                        // the fall-through edge.  Pattern bindings are never in
                        // merged_live, so unguarded arms reduce exactly to the
                        // prior `merged \ (body.live - bindings)` behaviour.
                        let need_drop = merged_live.difference(body_result.live)
                        let body_flushed = flush_dups_into_expr(body_result.expr, body_result.dups)
                        // #134: a diverging arm body (break/continue) self-cleans; do not
                        // prepend balance drops it would never reach, double-freeing.
                        let body_balanced = if need_drop.len() > 0 && expr_diverges(body_result.expr) == false {
                            prepend_stmts_to_expr(body_flushed, make_drop_list(need_drop))
                        } else {
                            body_flushed
                        }
                        balanced_arms.push(HMatchArm {
                            pattern: arm.pattern, guard: new_guard,
                            body: body_balanced, span: arm.span
                        })
                    },
                    none => {},
                }
            }

            // Transform scrutinee
            let scrut_result = rc_expr(scrutinee, merged_live, locals, boxed)

            RcResult {
                expr: HExpr::MatchExpr { scrutinee: scrut_result.expr, arms: balanced_arms,
                    ty: ty, effects: effects, span: span },
                live: scrut_result.live,
                dups: scrut_result.dups
            }
        },

        HExpr::StringInterp { parts, ty, effects, span } => {
            let mut cur_live = live
            // Process parts right-to-left. All parts evaluated unconditionally.
            let mut new_parts: List<HStringInterpPart> = []
            let mut part_dups_rev: List<Str> = []
            let mut i = parts.len() - 1
            while i >= 0 {
                match parts.get(i) {
                    some(p) => {
                        match p {
                            HStringInterpPart::Expression(e) => {
                                let r = rc_expr(e, cur_live, locals, boxed)
                                new_parts.push(HStringInterpPart::Expression(r.expr))
                                for d in r.dups { part_dups_rev.push(d) }
                                cur_live = r.live
                            },
                            HStringInterpPart::Literal(s) => {
                                new_parts.push(HStringInterpPart::Literal(s))
                            },
                        }
                    },
                    none => {},
                }
                i = i - 1
            }
            new_parts.reverse()
            part_dups_rev.reverse()

            RcResult {
                expr: HExpr::StringInterp { parts: new_parts, ty: ty, effects: effects, span: span },
                live: cur_live,
                dups: part_dups_rev
            }
        },

        HExpr::TryCatch { body, arms, ty, effects, span } => {
            // Conditional-evaluation boundary: body and each catch arm body are
            // conditionally evaluated, so their dups are flushed into their own
            // expressions. Report no dups upward.
            let body_result = rc_expr(body, set_clone(live), locals, boxed)
            let body_flushed = flush_dups_into_expr(body_result.expr, body_result.dups)
            let mut arm_results: List<(HMatchArm, Set<Str>)> = []

            for arm in arms {
                let arm_live = set_clone(live)
                let body_r = rc_expr(arm.body, arm_live, locals, boxed)
                let arm_body_flushed = flush_dups_into_expr(body_r.expr, body_r.dups)
                let mut arm_final = body_r.live
                let mut pat_names: List<Str> = []
                pattern_binding_names(arm.pattern, pat_names)
                for pn in pat_names { arm_final.remove(pn) }
                arm_results.push((HMatchArm { pattern: arm.pattern, guard: arm.guard, body: arm_body_flushed, span: arm.span }, arm_final))
            }

            // Merge all branch live sets
            let mut merged = body_result.live
            for ar in arm_results { merged = merged.union(ar.1) }

            // Balance body and arms.
            // #134: diverging body/arms (return/break/continue) self-clean — skip balancing.
            let balanced_body = if expr_diverges(body_result.expr) {
                body_flushed
            } else {
                balance_branch(body_flushed, body_result.live, merged)
            }
            let mut balanced_arms: List<HMatchArm> = []
            for ar in arm_results {
                let need_drop = merged.difference(ar.1)
                if need_drop.len() > 0 && expr_diverges(ar.0.body) == false {
                    let drops = make_drop_list(need_drop)
                    balanced_arms.push(HMatchArm { pattern: ar.0.pattern, guard: ar.0.guard,
                        body: prepend_stmts_to_expr(ar.0.body, drops), span: ar.0.span })
                } else {
                    balanced_arms.push(ar.0)
                }
            }

            RcResult {
                expr: HExpr::TryCatch { body: balanced_body, arms: balanced_arms, ty: ty, effects: effects, span: span },
                live: merged,
                dups: []
            }
        },

        HExpr::HandleExpr { body, handlers, ty, effects, span } => {
            // Conditional-evaluation boundary: body and handlers are flushed in
            // their own expressions; report no dups upward.
            let body_result = rc_expr(body, live, locals, boxed)
            let body_flushed = flush_dups_into_expr(body_result.expr, body_result.dups)

            // B-087/#133: each handler arm becomes a CLOSURE at codegen time
            // (build_handler_evidence → gen_lambda), capturing every enclosing-scope
            // local its body references into the closure env WITHOUT a ring_dup —
            // exactly like the Lambda case.  The dup/move responsibility therefore
            // lives here: an arm capture is a *use* of the outer variable, so the
            // enclosing scope must NOT prematurely drop it.  Without this, an arm
            // that references an outer `let x` (e.g. `Calc.add(a,b) => a+b+base`)
            // hits a drop(base) emitted right after `base`'s binding (base looks
            // dead from the handle body's view) → the arm closure then captures a
            // freed pointer → intermittent heap corruption / garbage reads.
            //
            // Mirror the Lambda capture decision against the incoming live set:
            //   - capture still live after the handle  → closure needs its own dup;
            //   - last use is the handle               → move it in (mark live so the
            //                                             enclosing scope won't drop).
            // The evidence struct + arm closures are intentionally leaked at L0 (D2),
            // so a moved/dup'd capture simply leaks with the env — never freed-then-used.
            let incoming = set_clone(live)
            let mut outer_live = set_clone(body_result.live)
            let mut capture_dups: List<Str> = []
            for h in handlers {
                let mut h_bound: Set<Str> = set_new()
                for hp in h.params { h_bound.insert(hp.name) }
                match h.resume_name {
                    some(rn) => h_bound.insert(rn),
                    none => {},
                }
                collect_local_defs_expr(h.body, h_bound)

                let mut h_body_vars: Set<Str> = set_new()
                collect_expr_vars(h.body, h_body_vars)
                for v in h_body_vars {
                    if h_bound.contains(v) == false && locals.contains(v) {
                        if incoming.contains(v) {
                            // Used again after the handle → the arm closure's copy
                            // needs an independent reference; dup at construction.
                            let mut seen = false
                            for d in capture_dups { if d == v { seen = true } }
                            if seen == false { capture_dups.push(v) }
                        } else {
                            // Last use is this handle → move the single owned ref into
                            // the arm closure; the enclosing scope must not drop it.
                            outer_live.insert(v)
                        }
                    }
                }
            }

            let mut new_handlers: List<HEffectHandler> = []
            for h in handlers {
                let h_live: Set<Str> = set_new()
                // Handler has its own scope with its own locals
                let mut h_locals: Set<Str> = set_new()
                for hp in h.params { h_locals.insert(hp.name) }
                match h.resume_name {
                    some(rn) => h_locals.insert(rn),
                    none => {},
                }
                collect_local_defs_expr(h.body, h_locals)
                let h_result = rc_expr(h.body, h_live, h_locals, boxed)
                let h_body_flushed = flush_dups_into_expr(h_result.expr, h_result.dups)
                new_handlers.push(HEffectHandler {
                    effect_name: h.effect_name, op_name: h.op_name,
                    params: h.params, resume_name: h.resume_name,
                    body: h_body_flushed
                })
            }
            RcResult {
                expr: HExpr::HandleExpr { body: body_flushed, handlers: new_handlers,
                    ty: ty, effects: effects, span: span },
                live: outer_live,
                dups: capture_dups
            }
        },

        HExpr::Lambda { params, return_type, body, ty, effects, span } => {
            // B-083 #1: a lambda CAPTURES every free variable it references from
            // the enclosing scope.  The LLVM codegen (gen_lambda /
            // collect_captures) stores each captured variable's pointer into the
            // closure env struct WITHOUT a ring_dup — it just copies the bare
            // pointer (borrow-style store).  So the dup responsibility lives in
            // this pass: a capture is a *use* of the outer variable and the
            // closure now holds its own reference, which must be balanced by a
            // dup at closure-construction time.  Missing this is a UAF (the env
            // outlives the original binding's drop).
            //
            // Compute the captures the same way codegen does: free identifiers in
            // the body that are owned locals of the *enclosing* scope and are
            // neither lambda params nor lambda-internal local definitions.  We do
            // NOT recurse into the body with rc_expr to discover them, because
            // rc_expr only tracks names present in the scope's `locals`; an outer
            // local is (correctly) absent from the lambda's own `lambda_locals`,
            // so it would never surface in body_result.live.  Hence we collect
            // free vars structurally and intersect with the enclosing `locals`.
            let mut lambda_bound: Set<Str> = set_new()
            for p in params { lambda_bound.insert(p.name) }
            collect_local_defs_expr(body, lambda_bound)

            let mut body_vars: Set<Str> = set_new()
            collect_expr_vars(body, body_vars)

            // Snapshot the incoming live membership BEFORE we mutate the live set:
            // in Ring a Set is reference-typed, so `outer_live = live` aliases the
            // same object and a later outer_live.insert(v) would perturb the
            // last-use decision for a subsequently-iterated capture.  `incoming`
            // is the frozen entry-state we make the move/dup decision against;
            // `outer_live` is the (separately-owned) result we mutate.
            let incoming = set_clone(live)
            let mut outer_live = set_clone(live)

            // A capture v is an enclosing owned local not bound inside the lambda.
            let mut capture_dups: List<Str> = []
            for v in body_vars {
                if lambda_bound.contains(v) == false && locals.contains(v) {
                    // Standard Perceus last-use, decided against the entry state.
                    if incoming.contains(v) {
                        // v is still live after the lambda (used again in the
                        // enclosing scope) → non-last use → the closure's copy
                        // needs its own dup, reported via the dups channel.
                        capture_dups.push(v)
                    } else {
                        // The lambda is the last use of v in this scope → move the
                        // single owned reference into the closure (no dup).  Mark
                        // it live so the enclosing scope does not also drop it.
                        outer_live.insert(v)
                    }
                }
            }

            // Build new body with param drops for unused params
            // (transform_fn_body collects its own locals internally)
            let new_body = transform_fn_body(params, body, boxed)

            RcResult {
                expr: HExpr::Lambda { params: params, return_type: return_type,
                    body: new_body, ty: ty, effects: effects, span: span },
                live: outer_live,
                dups: capture_dups
            }
        },

        HExpr::EffectOp { effect_name, op_name, args, ty, effects, span } => {
            let mut cur_live = live
            let mut new_args: List<HExpr> = []
            let mut arg_dups_rev: List<Str> = []
            let mut i = args.len() - 1
            while i >= 0 {
                match args.get(i) {
                    some(a) => {
                        let r = rc_expr(a, cur_live, locals, boxed)
                        new_args.push(r.expr)
                        for d in r.dups { arg_dups_rev.push(d) }
                        cur_live = r.live
                    },
                    none => {},
                }
                i = i - 1
            }
            new_args.reverse()
            arg_dups_rev.reverse()
            RcResult {
                expr: HExpr::EffectOp { effect_name: effect_name, op_name: op_name,
                    args: new_args, ty: ty, effects: effects, span: span },
                live: cur_live,
                dups: arg_dups_rev
            }
        },

        HExpr::RangeExpr { start, end, inclusive, ty, effects, span } => {
            let end_r = rc_expr(end, live, locals, boxed)
            let start_r = rc_expr(start, end_r.live, locals, boxed)
            RcResult {
                expr: HExpr::RangeExpr { start: start_r.expr, end: end_r.expr,
                    inclusive: inclusive, ty: ty, effects: effects, span: span },
                live: start_r.live,
                dups: start_r.dups.concat(end_r.dups)
            }
        },

        HExpr::ListLit { elements, ty, effects, span } => {
            let mut cur_live = live
            let mut new_elems: List<HExpr> = []
            let mut elem_dups_rev: List<Str> = []
            let mut i = elements.len() - 1
            while i >= 0 {
                match elements.get(i) {
                    some(e) => {
                        let r = rc_expr(e, cur_live, locals, boxed)
                        new_elems.push(r.expr)
                        for d in r.dups { elem_dups_rev.push(d) }
                        cur_live = r.live
                    },
                    none => {},
                }
                i = i - 1
            }
            new_elems.reverse()
            elem_dups_rev.reverse()
            RcResult {
                expr: HExpr::ListLit { elements: new_elems, ty: ty, effects: effects, span: span },
                live: cur_live,
                dups: elem_dups_rev
            }
        },

        HExpr::TupleLit { elements, ty, effects, span } => {
            let mut cur_live = live
            let mut new_elems: List<HExpr> = []
            let mut elem_dups_rev: List<Str> = []
            let mut i = elements.len() - 1
            while i >= 0 {
                match elements.get(i) {
                    some(e) => {
                        let r = rc_expr(e, cur_live, locals, boxed)
                        new_elems.push(r.expr)
                        for d in r.dups { elem_dups_rev.push(d) }
                        cur_live = r.live
                    },
                    none => {},
                }
                i = i - 1
            }
            new_elems.reverse()
            elem_dups_rev.reverse()
            RcResult {
                expr: HExpr::TupleLit { elements: new_elems, ty: ty, effects: effects, span: span },
                live: cur_live,
                dups: elem_dups_rev
            }
        },

        HExpr::IndexExpr { receiver, index, ty, effects, span } => {
            let idx_r = rc_expr(index, live, locals, boxed)
            let recv_r = rc_expr(receiver, idx_r.live, locals, boxed)
            RcResult {
                expr: HExpr::IndexExpr { receiver: recv_r.expr, index: idx_r.expr,
                    ty: ty, effects: effects, span: span },
                live: recv_r.live,
                dups: recv_r.dups.concat(idx_r.dups)
            }
        },
    }
}

// ============================================================
// Helper: deterministic iteration order for a Set<Str>
// ============================================================
//
// B-085: Set iteration order is backend-dependent — the JS backend (Set
// insertion order) and the LLVM backend (std::unordered_set hash order)
// disagree.  Any RC emission (drop/dup) that walks a Set directly therefore
// produces a different statement order under the two backends, which breaks
// double-bootstrap byte equivalence when several variables drop/dup at the
// same program point.  Sorting the names by their string value makes the
// emission order depend only on the variable names (deterministic) and thus
// identical across backends.
fn sorted_set_names(names: Set<Str>) -> List<Str> {
    let mut out: List<Str> = names.to_list()
    out.sort()
    out
}

// ============================================================
// Helper: create Drop stmts for a set of variable names
// ============================================================

fn make_drop_list(names: Set<Str>) -> List<HStmt> {
    let mut drops: List<HStmt> = []
    for name in sorted_set_names(names) {
        if rc_name_skippable(name) == false {
            drops.push(HStmt::Drop { name: name, ty: Type::UnitType, span: synthetic_span() })
        }
    }
    drops
}

// ============================================================
// Divergence analysis (#134): a branch that unconditionally transfers control
// away — return / break / continue — never reaches the enclosing merge point.
// Such a branch must be EXEMPT from branch balancing: its live variables are
// already released by the diverging terminator's own handling (e.g. the Return
// case's drop-all-live).  Balancing it double-frees — it prepends `Drop(x)` for
// vars the sibling branch keeps live, but the diverging path already released
// them, so a later dup/drop on `x` hits freed memory (the next_token UAF).
//
// NOTE: the empty live-set a diverging branch reports already makes merged_live
// and the SIBLING branch's balancing come out correct (a diverging branch
// contributes nothing to the merge).  The only thing that must change is not
// prepending balance drops to the diverging branch itself.
// ============================================================

fn stmt_diverges(stmt: HStmt) -> Bool {
    match stmt {
        HStmt::Return { .. } => true,
        HStmt::Break { .. } => true,
        HStmt::Continue { .. } => true,
        HStmt::ExprStmt { expr, .. } => expr_diverges(expr),
        _ => false,
    }
}

fn expr_diverges(expr: HExpr) -> Bool {
    match expr {
        HExpr::Block { stmts, tail, .. } => {
            // Diverges if any top-level statement diverges (statements after it
            // are dead) or, failing that, the tail expression diverges.
            let mut any = false
            for s in stmts {
                if stmt_diverges(s) { any = true }
            }
            if any {
                true
            } else {
                match tail {
                    some(t) => expr_diverges(t),
                    none => false,
                }
            }
        },
        HExpr::IfExpr { then_branch, else_branch, .. } => {
            // Diverges only if BOTH arms diverge; a missing else leaves a
            // fall-through path that reaches the merge.
            match else_branch {
                some(eb) => expr_diverges(then_branch) && expr_diverges(eb),
                none => false,
            }
        },
        HExpr::MatchExpr { arms, .. } => {
            // Diverges if every arm body diverges (match is exhaustive).
            let mut all = arms.len() > 0
            for arm in arms {
                if expr_diverges(arm.body) == false { all = false }
            }
            all
        },
        _ => false,
    }
}

// ============================================================
// Helper: balance a branch — insert drops for vars in other_live but not my_live
// ============================================================

fn balance_branch(body: HExpr, my_live: Set<Str>, other_live: Set<Str>) -> HExpr {
    let need_drop = other_live.difference(my_live)
    if need_drop.len() == 0 {
        return body
    }
    let drops = make_drop_list(need_drop)
    prepend_stmts_to_expr(body, drops)
}

// ============================================================
// Helper: prepend statements to an expression (wrapping in Block if needed)
// ============================================================

fn prepend_stmts_to_expr(expr: HExpr, stmts: List<HStmt>) -> HExpr {
    if stmts.len() == 0 { return expr }

    match expr {
        HExpr::Block { stmts: existing, tail, ty, effects, span } => {
            let new_stmts = stmts.concat(existing)
            HExpr::Block { stmts: new_stmts, tail: tail, ty: ty, effects: effects, span: span }
        },
        _ => {
            let ty = hexpr_type(expr)
            let effects = hexpr_effects(expr)
            let span = hexpr_span(expr)
            HExpr::Block { stmts: stmts, tail: some(expr), ty: ty, effects: effects, span: span }
        },
    }
}

// ============================================================
// B-081 helpers: convert reported dup needs into statement-level Dup nodes
// ============================================================

// Turn a list of variable names into a list of HStmt::Dup statements.
// Dup's ty is UnitType: codegen looks up the variable by name in named_values
// and ignores the ty field (same convention as the While/ForIn loop-var dups
// and make_drop_list).
fn dups_to_stmts(dups: List<Str>) -> List<HStmt> {
    let mut out: List<HStmt> = []
    for name in dups {
        if rc_name_skippable(name) == false {
            out.push(HStmt::Dup { name: name, ty: Type::UnitType, span: synthetic_span() })
        }
    }
    out
}

// Flush reported dups into an expression: prepend the dup statements so they
// execute immediately before `expr` is evaluated.  Used at conditional-branch
// boundaries (if/match arms, short-circuit RHS, loop bodies) where the dup
// must not escape to the surrounding statement level.
fn flush_dups_into_expr(expr: HExpr, dups: List<Str>) -> HExpr {
    prepend_stmts_to_expr(expr, dups_to_stmts(dups))
}
