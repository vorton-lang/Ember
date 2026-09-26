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

use ast::{Span, Position, Pattern, BinOp}
use hir::{HDecl, HStmt, HExpr, HParam, HProgram, HMatchArm,
    HStructFieldInit, HStringInterpPart, HEffectHandler,
    hexpr_type, hexpr_span, hexpr_effects,
    collect_extern_type_names, is_rc_excluded_type, type_contains_extern_handle,
    is_borrow_returning_call, is_arg_returning_call}
use types::{Type}

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
// Main entry: transform all declarations
// ============================================================

pub fn perceus_transform(program: HProgram) -> HProgram {
    // B-104: ANF/materialize pre-pass — hoist every FRESH-OWNED intermediate
    // temporary (call args / operands / conditions / subexprs that are not bound
    // by a `let`) into a `let __anf_N = <expr>` statement so the clone-all-escape
    // RC machinery below reclaims it via the normal scope-end-drop (its `let`
    // binding is droppable per is_droppable_init).  Without this, intermediate
    // owned temporaries (`i < len`, `i + 1`, the `g(x)` in `f(g(x))`, every boxed
    // Int/Bool/Option/Str call-arg) have no binding and no one drops them — the
    // diagnosed 88% never-freed leak (live ≈ allocs 1:1).  Run BEFORE the RC pass.
    //
    // B-104 D1 rule ① (audit #139): collect this module's extern type names ONCE
    // and thread them through both passes.  A value whose HIR type is an extern
    // type is a raw foreign pointer (no ring_alloc RC header) — it is excluded
    // from RC entirely (never Clone / never Drop / never owned / never
    // materialised), and a value whose type transitively CONTAINS an extern
    // handle (List<LLVMTypeRef>, LLVMValueRef?, LlvmCtx, …) is excluded from
    // Drop/materialise (its deep drop would reach the foreign pointer).  See
    // hir.ring's collect_extern_type_names / type_contains_extern_handle.
    let externs = collect_extern_type_names(program.decls)
    let anf_program = anf_normalize(program, externs)
    // B-091: `boxed_vars` (def_ids of `let mut` vars auto-boxed for write-through
    // closure capture) is threaded through the RC pass so the Assign old-value
    // Drop is suppressed for them — a boxed write mutates `cell.value`, it does
    // NOT consume/free the shared cell pointer.
    let new_decls = transform_decls(anf_program.decls, anf_program.boxed_vars, externs)
    HProgram {
        decls: new_decls,
        derived_impls: anf_program.derived_impls,
        boxed_vars: anf_program.boxed_vars
    }
}

// ============================================================
// B-104: ANF / materialize pre-pass
// ============================================================
//
// Goal: give every FRESH-OWNED intermediate temporary a `let` binding so the
// clone-all-escape RC pass below reclaims it via scope-end-drop.  An intermediate
// temporary is a sub-expression in a NON-binding position (a call/ctor argument,
// an arithmetic/comparison operand, a loop/branch condition, an interpolation
// piece, …) that allocates a fresh owned value (boxed Int/Bool, Option, Str,
// container, struct/variant) and whose result has no `let` to own it — so the
// RC pass never drops it and it leaks (the diagnosed live≈allocs 1:1).
//
// Strategy: walk each statement list, and for every hoistable sub-expression
// position materialise the value into a fresh `let __anf_N = <expr>` emitted
// immediately before the using statement, replacing the sub-expression with an
// Ident referencing __anf_N.  The RC pass then sees a droppable `let` (Call /
// BinOp / UnaryOp / constructor / StringInterp / Lambda all satisfy
// is_droppable_init) and inserts the scope-end Drop.  This is plain A-normal-form
// applied only to fresh-owned subexprs; it does NOT introduce backward-liveness
// (the #134 risk) — it reuses the existing forward scope-end-drop.
//
// HARD RULES (a violation = UAF or changed behaviour):
//   R1 ONLY materialise FRESH-OWNED compounds: BinOp / UnaryOp / non-borrow Call /
//      StructLit / NamedVariantConstruct / ListLit / TupleLit / RangeExpr /
//      StringInterp / Lambda.  NEVER Ident / FieldAccess / IndexExpr /
//      borrow-returning Call (is_borrow_returning_call) — those are BORROWS;
//      materialise+drop would UAF.  Literals are skipped (no heap to reclaim) but
//      they are harmless if bound; we skip them for cleanliness.
//   R2 DO NOT hoist past a short-circuit / branch boundary.  The RIGHT operand of
//      `&&` / `||` and the per-branch values of if/match are evaluated
//      conditionally; their temporaries are materialised INSIDE a self-contained
//      scope (a Block tail, or the branch body block), never lifted to the outer
//      statement list.
//   R3 LOOP conditions materialise + drop PER ITERATION.  `while c`'s `c` is
//      re-evaluated each round; its temporaries are wrapped in a Block so the
//      scope-end Drop runs every iteration (lifting them to before the loop would
//      evaluate once and leak each round).
//   R4 EVALUATION ORDER preserved: multiple operands materialise left→right, and a
//      child's own nested hoists precede the child's own materialisation.
//   R5 ESCAPE handled downstream: a materialised binding that later escapes is
//      Clone'd by clone-all-escape and its `let` is scope-dropped — no special
//      casing here.

fn anf_normalize(program: HProgram, externs: Set<Str>) -> HProgram {
    // Per-program monotonic temp counter (single-element mutable cell, same idiom
    // as perceus's gensym).  Identical across runs of the same source, so it does
    // not perturb double-bootstrap byte-equivalence.
    let mut counter: List<Int> = [0]
    let mut new_decls: List<HDecl> = []
    for d in program.decls {
        new_decls.push(anf_decl(d, externs, counter))
    }
    HProgram {
        decls: new_decls,
        derived_impls: program.derived_impls,
        boxed_vars: program.boxed_vars
    }
}

fn fresh_anf_tmp(mut counter: List<Int>) -> Str {
    let n = match counter.get(0) { some(v) => v, none => 0 }
    counter.set(0, n + 1)
    "__anf_${n + 1}"
}

fn anf_decl(decl: HDecl, externs: Set<Str>, mut counter: List<Int>) -> HDecl {
    match decl {
        HDecl::Fn { name, def_id, type_params, params, return_type, effects, body, is_pub, trait_bounds, span } => {
            HDecl::Fn {
                name: name, def_id: def_id, type_params: type_params,
                params: params, return_type: return_type, effects: effects,
                body: anf_fn_body(body, externs, counter), is_pub: is_pub,
                trait_bounds: trait_bounds, span: span
            }
        },
        HDecl::Impl { target_type, type_params, trait_name, methods, assoc_types, span } => {
            let mut new_methods: List<HDecl> = []
            for m in methods { new_methods.push(anf_decl(m, externs, counter)) }
            HDecl::Impl {
                target_type: target_type, type_params: type_params,
                trait_name: trait_name, methods: new_methods,
                assoc_types: assoc_types, span: span
            }
        },
        HDecl::Test { description, body, span } => {
            HDecl::Test { description: description, body: anf_fn_body(body, externs, counter), span: span }
        },
        HDecl::Const { name, def_id, ty, init, is_pub, span } => {
            // Const init is in escape position with no enclosing statement list to
            // hoist into; normalise its nested subexprs into a Block tail if any
            // materialisation is needed.
            HDecl::Const { name: name, def_id: def_id, ty: ty,
                init: anf_value_in_own_scope(init, externs, counter), is_pub: is_pub, span: span }
        },
        HDecl::ModBlock { name, decls: mod_decls, is_pub, span } => {
            let mut new_mod: List<HDecl> = []
            for md in mod_decls { new_mod.push(anf_decl(md, externs, counter)) }
            HDecl::ModBlock { name: name, decls: new_mod, is_pub: is_pub, span: span }
        },
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

// A function/lambda body: a Block (or a single tail expr) in escape position.
fn anf_fn_body(body: HExpr, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    anf_block_expr(body, externs, counter)
}

// Whether an expression is a FRESH-OWNED compound that should be materialised when
// it sits in a hoistable (non-binding) position (R1).  A borrow-returning Call is
// excluded — its result aliases a live reference, so binding+dropping it would UAF.
fn anf_should_materialize(expr: HExpr, externs: Set<Str>) -> Bool {
    // B-104 D1 rule ② (Unit) + rule ① (extern, audit #139), both TYPE-level:
    //   ② a Unit-typed expression has no value semantics (checker-guaranteed; JS
    //     backend yields undefined).  At the LLVM ABI a Unit-typed builtin call
    //     may accidentally return a live pointer (the receiver-returning
    //     mutators — `return list;` etc., classification table below), so
    //     binding + scope-end-dropping it would free the caller's container.
    //     Never materialise Unit.
    //   ① a value whose type IS an extern handle, or transitively CONTAINS one
    //     (List<LLVMTypeRef>, LLVMValueRef?, …), must never be materialised —
    //     the materialised `let __anf` would be scope-end-dropped, and dropping
    //     it ring_drops a raw foreign pointer (garbage header read / foreign
    //     free → heap corruption).
    // Leave both inline: borrowed by the consumer, never dropped (the pre-D1
    // status quo for these values — crash-free).
    let ty = hexpr_type(expr)
    if is_rc_excluded_type(ty, externs) {
        return false
    }
    if type_contains_extern_handle(ty, externs) {
        return false
    }
    // B-104 D1 Stage 2 — UNKNOWN-OWNERSHIP guard (audit #149): an expression
    // whose HIR type is an unresolved TypeVar must never be materialised.  The
    // type-level Unit exclusion (rule ②) cannot see through it: an UNANNOTATED
    // Ring fn's return type is over-generalised to a free var (checker hole,
    // audit #149 — `let x: Str = tp([1])` type-checks), so a call like `tp(a)`
    // whose body tail is a receiver-returning Unit builtin (`xs.push(v)` —
    // moved verbatim, un-dup'd, because Unit is rc-excluded) hands back the
    // LIVE RECEIVER pointer typed as a TypeVar.  Materialise + scope-end-drop
    // would double-free the caller's container (ASan-proven: `let r = tp(a)`
    // UAF on the pre-guard compiler).  Ownership of a TypeVar-typed value is
    // unknowable here → leak-direction: not materialised, not droppable (see
    // the same guard in is_droppable_init).  Clone-on-escape stays allowed
    // (an extra dup on a live pointer only pins — crash-free).
    if is_unresolved_var_type(ty) {
        return false
    }
    match expr {
        // Arithmetic / comparison BinOps box a FRESH result (gen_int_binop /
        // gen_*_binop → box_int/box_bool/box_float).  But `&&` / `||` (BinOp::And /
        // Or) DO NOT: gen_and/gen_or emit a phi that yields the RHS operand VERBATIM
        // on the short-circuit-taken path (`a && b` returns b's own box when a is
        // true).  That box may be a BORROW (e.g. `obj.is_mutable`), so materialising
        // the `&&`/`||` and scope-dropping it would free a value owned elsewhere →
        // UAF (ASan: register_impl_method freeing parse_param's is_mutable Bool).
        // Therefore NEVER materialise And/Or — only the arithmetic/comparison
        // BinOps, whose result is genuinely fresh.
        HExpr::BinOp { op, .. } => match op { BinOp::And => false, BinOp::Or => false, _ => true },
        HExpr::UnaryOp { .. } => true,
        HExpr::Call { callee, .. } => is_borrow_returning_call(callee) == false,
        HExpr::StructLit { .. } => true,
        HExpr::NamedVariantConstruct { .. } => true,
        HExpr::ListLit { .. } => true,
        HExpr::TupleLit { .. } => true,
        HExpr::RangeExpr { .. } => true,
        HExpr::StringInterp { .. } => true,
        HExpr::Lambda { .. } => true,
        // B-104 task-1: scalar literals are NOT free — uniform-BOXED (B-080 unboxing
        // not done), so every IntLit / StrLit / BoolLit / FloatLit is a FRESH heap box
        // (gen_int_lit → box_int, gen_str_lit → ring_str_new, etc.).  A literal in an
        // operand position (`f(5)`, `code: E0301` as arg, `acc + 1`'s `1`, an interp
        // piece) is borrowed by the consumer and never dropped → leak (the residual
        // tid=0 INT / tid=3 STR / tid=2 BOOL bulk).  Materialise + scope-end-drop them.
        //
        // ⚠️ &&-RHS PHI-ALIAS SAFETY (same trap as And/Or, parse_param is_mutable UAF):
        // gen_and/gen_or yield the RHS operand box VERBATIM on the short-circuit-taken
        // edge.  If a materialised literal box became that phi result, scope-dropping
        // the __anf binding AND the && result would double-free.  This is STRUCTURALLY
        // prevented WITHOUT a special case here: a literal only reaches
        // anf_should_materialize via anf_operand, but the &&/|| RHS TOP expression is
        // normalised by anf_cond_in_own_scope → anf_expr (NOT anf_operand), and a bare
        // literal passes through anf_expr unchanged with zero hoists → it stays INLINE,
        // never materialised (`a && true` remains `a && true`).  Likewise if/match/block
        // branch TAILS go through anf_tail_value → anf_expr (no top-level materialise),
        // so a literal that becomes a branch phi result is never bound either.  The only
        // materialisation site is a genuine eager operand (call arg / arith operand /
        // condition / interp piece), whose box is consumed by the operation, not aliased
        // back out as the enclosing expression's value.  R5 escape (a materialised
        // literal that later escapes, e.g. `let x = f(5)` where 5 is the only arg path)
        // is handled by clone-all-escape exactly as for any other fresh-owned binding.
        HExpr::IntLit { .. } => true,
        HExpr::FloatLit { .. } => true,
        HExpr::StrLit { .. } => true,
        HExpr::BoolLit { .. } => true,
        // B-104 D1 rule ③: IndexExpr refined by RECEIVER type.  `s[i]` on a Str
        // lowers to ring_str_get, which allocates a NEW 1-char string
        // (ring_runtime.cpp: ring_alloc + placement-new — verified) — a FRESH
        // owned value, NOT a borrow into the receiver.  Before this rule it rode
        // the blanket IndexExpr borrow classification: never materialised (leak
        // in every operand position — the lexer's per-char `src[i]` flood, a
        // dominant tid=3 STR share) and Clone-wrapped on escape (the dup
        // escaped, the original 1-char string leaked).  List/Map indexing
        // (ring_list_get / ring_map_get / ring_map_int_get) returns the element
        // pointer WITHOUT a dup — a true borrow — and keeps the conservative
        // path (generic/TypeVar receivers too).
        HExpr::IndexExpr { receiver, .. } => is_str_index(receiver),
        // NEVER materialise: Ident / FieldAccess / non-Str IndexExpr (borrows),
        // control-flow (Block/If/Match — handled structurally), EffectOp /
        // HandleExpr / TryCatch / Clone.
        _ => false,
    }
}

// B-104 D1 rule ③ helper: whether an IndexExpr's receiver is a Str, making the
// index read a FRESH single-char string (ring_str_get allocates) rather than a
// borrowed element pointer.  Conservative on anything but a literal StrType
// (TypeVar / generic receivers stay classified as borrows — crash-free leak).
fn is_str_index(receiver: HExpr) -> Bool {
    match hexpr_type(receiver) {
        Type::StrType => true,
        _ => false,
    }
}

// B-104 D1 Stage 2 — UNKNOWN-OWNERSHIP type (audit #149): an unresolved TypeVar
// (or an ErrorType from checker recovery) gives no ownership information — the
// value could be the Unit ABI accident (a live receiver pointer moved verbatim
// because Unit is rc-excluded), which a drop would double-free.  Such values are
// excluded from materialisation and droppability (leak direction); Clone on
// escape stays allowed (a dup only pins).  Monomorphic call sites are zonked to
// concrete types and unaffected; the leak cost is confined to generic-context
// temporaries and the #149 over-generalised unannotated-fn calls.
fn is_unresolved_var_type(ty: Type) -> Bool {
    match ty {
        Type::TypeVar { .. } => true,
        Type::ErrorType => true,
        _ => false,
    }
}

// Materialise `expr` (already normalised) into a fresh `let __anf_N = expr`
// appended to `hoists`, returning an Ident referencing it.  Caller guarantees
// anf_should_materialize(expr) — i.e. fresh-owned, droppable.
fn anf_materialize(expr: HExpr, mut hoists: List<HStmt>, mut counter: List<Int>) -> HExpr {
    let tmp = fresh_anf_tmp(counter)
    let t = hexpr_type(expr)
    let e = hexpr_effects(expr)
    let s = hexpr_span(expr)
    hoists.push(HStmt::Let { name: tmp, name_span: synthetic_span(),
        def_id: none, ty: t, init: expr, span: synthetic_span() })
    HExpr::Ident { name: tmp, resolved_name: none, def_id: none,
        dict_closure_dicts: none, ty: t, effects: e, span: s }
}

// Normalise a sub-expression that sits in a CONSUMING operand position — one where
// the value is read/unboxed and the operation produces a FRESH result that CANNOT
// alias the operand (arith/compare BinOp operand, UnaryOp operand, if/while
// condition, index expression, interpolation piece).  Here materialise+scope-drop
// is SOUND: the fresh-owned box is consumed by the op (box_int/box_bool/unbox/
// stringify) and never aliased back out as the enclosing expression's value, so the
// caller's scope-end Drop is balanced.  Recurse, then materialise if fresh-owned
// (R1/R4).
//
// ⚠️ NOT for CALL / EFFECTOP arguments or a MATCH SCRUTINEE — see anf_arg.  Those
// positions can ALIAS the operand into the result (a callee that returns an arg
// verbatim, e.g. `list.fold(init, …)` returns `init` unchanged on an empty list →
// the result box IS the arg box; a match arm that returns the scrutinee), so
// materialising+dropping the arg double-frees the box the result binding also owns.
fn anf_operand(expr: HExpr, mut hoists: List<HStmt>, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    let normalized = anf_expr(expr, hoists, externs, counter)
    if anf_should_materialize(normalized, externs) {
        anf_materialize(normalized, hoists, counter)
    } else {
        normalized
    }
}

// Normalise a sub-expression in a CONSERVATIVE arg-aliasing position: recurse into
// its own nested CONSUMING operands (which still hoist + materialise normally), but
// NEVER materialise the top-level expression itself.  The SOLE remaining user
// (B-104 D1 Stage 2 — W2 reclaimed the match scrutinee, Stage 2 reclaimed
// EffectOp args via the handler-tail Clone-wrap balance) is:
//   * a `fold`-family CALL arg — fold returns `init` verbatim on an empty list with
//     a moved result (is_arg_returning_call; list_fold.ring heap-corruption
//     regression).  Materialising + scope-dropping it would double-free the box
//     the result binding also moves.  Residual crash-free leak; the principled
//     exit is a runtime dup-on-empty-return (see audit #150).
fn anf_arg(expr: HExpr, mut hoists: List<HStmt>, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    anf_expr(expr, hoists, externs, counter)
}

// A Block (or non-block single expr) used as a function/branch/loop body or value.
// Normalises its statement list and tail in place; no hoisting escapes the block.
fn anf_block_expr(body: HExpr, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    match body {
        HExpr::Block { stmts, tail, ty, effects, span } => {
            let new_stmts = anf_stmt_list(stmts, externs, counter)
            let new_tail = match tail {
                // The tail is in escape position; its OWN nested subexprs are
                // hoisted into a trailing fragment appended to this block (the
                // hoists precede the tail value, preserving order + scope).
                some(t) => {
                    let mut tail_hoists: List<HStmt> = []
                    let nt = anf_tail_value(t, tail_hoists, externs, counter)
                    if tail_hoists.len() == 0 {
                        (new_stmts, some(nt))
                    } else {
                        let mut merged = new_stmts.concat([])
                        for h in tail_hoists { merged.push(h) }
                        (merged, some(nt))
                    }
                },
                none => (new_stmts, none),
            }
            HExpr::Block { stmts: new_tail.0, tail: new_tail.1, ty: ty, effects: effects, span: span }
        },
        // Single-expression body (no block): treat as a tail value in its own
        // scope (materialised temps wrap into a Block so they are scope-dropped).
        _ => anf_value_in_own_scope(body, externs, counter),
    }
}

// A value expression that has NO enclosing statement list to hoist into (a const
// init, a single-expr body).  If normalising it produces hoists, wrap them in a
// fresh Block whose tail is the value — the temps are then scope-end-dropped by
// the RC pass.  The value itself is NOT materialised (it is the escaping result).
fn anf_value_in_own_scope(expr: HExpr, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    let mut hoists: List<HStmt> = []
    let nv = anf_tail_value(expr, hoists, externs, counter)
    if hoists.len() == 0 {
        nv
    } else {
        HExpr::Block { stmts: hoists, tail: some(nv),
            ty: hexpr_type(expr), effects: hexpr_effects(expr), span: hexpr_span(expr) }
    }
}

// Normalise an expression in TAIL / escape position (a block tail, a let init, an
// assign/return value): recurse into its subexprs (which DO hoist into `hoists`),
// but DO NOT materialise the expression itself — it escapes into the owning slot
// and the RC pass handles that binding directly.  Control-flow tails (if/match/
// block) recurse into their branches structurally (R2).
fn anf_tail_value(expr: HExpr, mut hoists: List<HStmt>, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    anf_expr(expr, hoists, externs, counter)
}

// Normalise a statement list, returning a new list with __anf_ hoists inserted
// before each statement that needs them.
fn anf_stmt_list(stmts: List<HStmt>, externs: Set<Str>, mut counter: List<Int>) -> List<HStmt> {
    let mut out: List<HStmt> = []
    for s in stmts {
        for ns in anf_stmt(s, externs, counter) { out.push(ns) }
    }
    out
}

// Normalise a single statement, returning [hoisted lets..., transformed stmt].
fn anf_stmt(stmt: HStmt, externs: Set<Str>, mut counter: List<Int>) -> List<HStmt> {
    match stmt {
        HStmt::Let { name, name_span, def_id, ty, init, span } => {
            let mut hoists: List<HStmt> = []
            let new_init = anf_tail_value(init, hoists, externs, counter)
            hoists.push(HStmt::Let { name: name, name_span: name_span, def_id: def_id, ty: ty, init: new_init, span: span })
            hoists
        },
        HStmt::Var { name, name_span, def_id, ty, init, span } => {
            let mut hoists: List<HStmt> = []
            let new_init = anf_tail_value(init, hoists, externs, counter)
            hoists.push(HStmt::Var { name: name, name_span: name_span, def_id: def_id, ty: ty, init: new_init, span: span })
            hoists
        },
        HStmt::Assign { target, value, span } => {
            let mut hoists: List<HStmt> = []
            // The target is a write destination (lvalue) — recurse to normalise any
            // index/receiver subexprs, but it is not a value to materialise.
            let new_target = anf_lvalue(target, hoists, externs, counter)
            let new_value = anf_tail_value(value, hoists, externs, counter)
            hoists.push(HStmt::Assign { target: new_target, value: new_value, span: span })
            hoists
        },
        HStmt::ExprStmt { expr, span } => {
            let mut hoists: List<HStmt> = []
            // Statement position: the value is DISCARDED — the textbook "parent
            // drops it" fresh-owned temporary (B-104 D1 Stage 2).  A non-Unit
            // fresh result (`xs.pop()`, `compute()` for side effects) previously
            // had no owner and leaked.  Materialise the top expression
            // (anf_operand): `let __anf = xs.pop()` → scope-end drop reclaims it.
            // Zero churn for the common cases: Unit-typed calls (print / push /
            // insert — rule ②) and borrow-returning calls fail
            // anf_should_materialize and stay plain statements; control-flow
            // statements (if/match/block) are normalised structurally as before
            // (their discarded branch values stay borrows — residual).  A
            // NeverType call (panic/exit) materialises harmlessly (the drop is
            // unreachable).
            let new_expr = anf_operand(expr, hoists, externs, counter)
            hoists.push(HStmt::ExprStmt { expr: new_expr, span: span })
            hoists
        },
        HStmt::Return { value, span } => {
            match value {
                some(v) => {
                    let mut hoists: List<HStmt> = []
                    let new_v = anf_tail_value(v, hoists, externs, counter)
                    hoists.push(HStmt::Return { value: some(new_v), span: span })
                    hoists
                },
                none => [HStmt::Return { value: none, span: span }],
            }
        },
        HStmt::While { condition, body, span } => {
            // R3: the condition is re-evaluated each iteration.  Materialised temps
            // from the condition must be dropped PER ITERATION, so they wrap into a
            // Block whose tail is the condition (the Block is re-run each round, and
            // the RC pass scope-end-drops its temps each round).  They must NOT be
            // hoisted before the loop.
            let new_cond = anf_cond_in_own_scope(condition, externs, counter)
            let new_body = anf_block_expr(body, externs, counter)
            [HStmt::While { condition: new_cond, body: new_body, span: span }]
        },
        HStmt::ForIn { binding, binding_span, def_id, destructure, iterable, body, iterable_type_name, iter_type_name, span } => {
            // The iterable is evaluated ONCE before the loop → its temps may hoist
            // before the ForIn statement.  The body is its own per-iteration scope.
            //
            // B-104 D1 Stage 2 — ITERABLE position: a fresh-owned iterable
            // (`for e in m.entries()`, `for x in xs.filter(p)`, `for v in
            // make_list()`) was read by the loop and never dropped.  Materialise
            // it: `let __anf = m.entries(); for e in __anf` — the loop binding
            // borrows __anf's elements (B-098 read-borrow), element escapes are
            // Clone-wrapped, and __anf is scope-end-dropped AFTER the loop (a
            // `return` inside the body drops the full owned set incl. __anf).
            // Same Clone-wrap balance as the W2 scrutinee.
            //
            // EXCEPTION — a literal RangeExpr iterable stays INLINE: emit_for_in
            // pattern-matches the RangeExpr form structurally to lower a direct
            // counting loop (no range struct) with its own per-iteration counter
            // + bound drops (B-104b).  Materialising it would reroute through
            // the heavier range-var path for zero RC gain (the direct lowering
            // already drops the bound boxes).
            let mut hoists: List<HStmt> = []
            let new_iter = match iterable {
                HExpr::RangeExpr { .. } => anf_expr(iterable, hoists, externs, counter),
                _ => anf_operand(iterable, hoists, externs, counter),
            }
            let new_body = anf_block_expr(body, externs, counter)
            hoists.push(HStmt::ForIn {
                binding: binding, binding_span: binding_span, def_id: def_id,
                destructure: destructure, iterable: new_iter, body: new_body,
                iterable_type_name: iterable_type_name, iter_type_name: iter_type_name, span: span
            })
            hoists
        },
        HStmt::LetDestructure { pattern, bindings, init, span } => {
            // B-104 D1 Stage 2 — DESTRUCTURE INIT position: `let (a, b) = f()` /
            // `let (a, b) = (x, y)`.  The destructure only PROJECTS borrows out
            // of the init value (codegen emit_let_destructure: ring_list_get
            // loads, no dup; bindings are excluded from the owned set), so a
            // fresh init had NO owner and leaked (the TUPLE-typeid residual).
            // Materialise it: `let __anf = f(); let (a, b) = __anf` — the
            // bindings borrow __anf's slots, escapes of them Clone-wrap, and
            // __anf is scope-end-dropped.  Paired with the rc_stmt change that
            // processes the init as a BORROW (rc_expr) instead of rc_escape —
            // see rc_stmt's LetDestructure arm.
            let mut hoists: List<HStmt> = []
            let new_init = anf_operand(init, hoists, externs, counter)
            hoists.push(HStmt::LetDestructure { pattern: pattern, bindings: bindings, init: new_init, span: span })
            hoists
        },
        HStmt::IfLet { pattern, expr, then_block, else_block, span } => {
            // Scrutinee evaluated once → hoist before the IfLet.  Branch blocks are
            // their own scopes (R2).
            //
            // B-104 D1 Stage 2 — IF-LET SCRUTINEE position (W2 extension): a
            // fresh-owned scrutinee (`if let some(v) = m.get(k)`) was read by the
            // pattern test and never dropped.  Materialise it (anf_operand) —
            // identical reasoning to the W2 MatchExpr scrutinee: pattern bindings
            // PROJECT borrows of __anf (excluded from owned, never dropped), any
            // escape of a binding/projection is Clone-wrapped, and __anf's
            // scope-end Drop (after both branches) releases the original —
            // dup-before-drop balanced.  Borrow scrutinees (Ident/field/index)
            // fail anf_should_materialize and stay inline.
            let mut hoists: List<HStmt> = []
            let new_expr = anf_operand(expr, hoists, externs, counter)
            let new_then = anf_block_expr(then_block, externs, counter)
            let new_else = match else_block {
                some(eb) => some(anf_block_expr(eb, externs, counter)),
                none => none,
            }
            hoists.push(HStmt::IfLet { pattern: pattern, expr: new_expr, then_block: new_then, else_block: new_else, span: span })
            hoists
        },
        HStmt::Break { span } => [HStmt::Break { span: span }],
        HStmt::Continue { span } => [HStmt::Continue { span: span }],
        // Drop / Dup are not present in the input HIR to the ANF pass (perceus runs
        // after); pass through idempotently if ever seen.
        HStmt::Drop { .. } => [stmt],
        HStmt::Dup { .. } => [stmt],
    }
}

// A while/if/match condition that is evaluated potentially repeatedly (loop cond)
// or in a position where its temps must be self-contained: normalise it, and if
// any temps are produced, wrap them in a Block whose tail is the condition value
// so they are scope-end-dropped at each evaluation (R3).
fn anf_cond_in_own_scope(cond: HExpr, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    let mut hoists: List<HStmt> = []
    let nc = anf_expr(cond, hoists, externs, counter)
    if hoists.len() == 0 {
        nc
    } else {
        HExpr::Block { stmts: hoists, tail: some(nc),
            ty: hexpr_type(cond), effects: hexpr_effects(cond), span: hexpr_span(cond) }
    }
}

// Normalise an lvalue (Assign target): descend into receiver/index subexprs but
// never materialise — a write destination is a place, not an owned value.
fn anf_lvalue(expr: HExpr, mut hoists: List<HStmt>, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    match expr {
        HExpr::FieldAccess { receiver, field, ty, effects, span } => {
            HExpr::FieldAccess { receiver: anf_lvalue(receiver, hoists, externs, counter),
                field: field, ty: ty, effects: effects, span: span }
        },
        HExpr::IndexExpr { receiver, index, ty, effects, span } => {
            // The index expression IS a read operand — it can be materialised.
            HExpr::IndexExpr { receiver: anf_lvalue(receiver, hoists, externs, counter),
                index: anf_operand(index, hoists, externs, counter),
                ty: ty, effects: effects, span: span }
        },
        // Ident lvalue (plain variable) — nothing to normalise.
        _ => expr,
    }
}

// The core expression normaliser.  Recurses into every sub-expression; hoistable
// operand positions go through anf_operand (which may materialise), tail/escape
// positions through anf_tail_value/anf_expr (no top-level materialisation), and
// control-flow branches are normalised structurally (no hoisting across the
// boundary — R2).  `hoists` accumulates `let __anf_N` statements emitted before
// the enclosing statement.
fn anf_expr(expr: HExpr, mut hoists: List<HStmt>, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    match expr {
        // Leaves — nothing to normalise.
        HExpr::IntLit { .. } => expr,
        HExpr::FloatLit { .. } => expr,
        HExpr::StrLit { .. } => expr,
        HExpr::BoolLit { .. } => expr,
        HExpr::Ident { .. } => expr,

        HExpr::BinOp { op, left, right, eq_dispatch, ord_dispatch, ty, effects, span } => {
            match op {
                // R2: `&&` / `||` short-circuit.  The LEFT operand is always
                // evaluated → its temps hoist normally.  The RIGHT operand is
                // evaluated conditionally → its temps must NOT hoist past the
                // boundary; they wrap into a self-contained Block (lazy + scoped).
                BinOp::And => {
                    let new_left = anf_operand(left, hoists, externs, counter)
                    let new_right = anf_cond_in_own_scope(right, externs, counter)
                    HExpr::BinOp { op: op, left: new_left, right: new_right,
                        eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
                        ty: ty, effects: effects, span: span }
                },
                BinOp::Or => {
                    let new_left = anf_operand(left, hoists, externs, counter)
                    let new_right = anf_cond_in_own_scope(right, externs, counter)
                    HExpr::BinOp { op: op, left: new_left, right: new_right,
                        eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
                        ty: ty, effects: effects, span: span }
                },
                // Eager arithmetic/comparison: both operands always evaluated
                // left→right → materialise fresh-owned operands (R4).
                _ => {
                    let new_left = anf_operand(left, hoists, externs, counter)
                    let new_right = anf_operand(right, hoists, externs, counter)
                    HExpr::BinOp { op: op, left: new_left, right: new_right,
                        eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
                        ty: ty, effects: effects, span: span }
                },
            }
        },

        HExpr::UnaryOp { op, operand, ty, effects, span } => {
            HExpr::UnaryOp { op: op, operand: anf_operand(operand, hoists, externs, counter),
                ty: ty, effects: effects, span: span }
        },

        HExpr::Call { callee, args, type_args, resolved_dicts, dict_dispatch, ty, effects, span } => {
            // Callee is a borrow read (FieldAccess receiver / Ident) — normalise its
            // subexprs but it is not itself a materialisable value.
            let new_callee = anf_callee(callee, hoists, externs, counter)
            // B-104 W1: args are BORROW-passed (the callee never drops them).  A
            // fresh-owned arg (`f(some(x))`, `f(xs.get(i))`, `f(a+b)`, `f(5)`) is
            // otherwise read by the callee and never dropped → the big residual
            // arg-position leak (OPTION / boxed-INT bulk).  Materialise + scope-end-
            // drop it (anf_operand) so it is reclaimed — SOUND because every Ring
            // function return-clones its tail (clone-all-escape) so it never hands
            // back an un-dup'd arg, and owned/borrow builtins are likewise safe (a
            // borrow-returning result is Clone-wrapped at the binding, balancing the
            // materialised arg's drop — see is_arg_returning_call).
            //
            // EXCEPTION — a callee that returns an arg VERBATIM with a MOVED result
            // (`fold`, per is_arg_returning_call): materialising its args would
            // double-free the arg box the result binding also moves.  Keep those args
            // UN-materialised borrows (anf_arg, recurse-only) — residual crash-free
            // leak, the cost of no full return-mode analysis.
            let arg_returning = is_arg_returning_call(new_callee)
            let mut new_args: List<HExpr> = []
            for a in args {
                if arg_returning {
                    new_args.push(anf_arg(a, hoists, externs, counter))
                } else {
                    new_args.push(anf_operand(a, hoists, externs, counter))
                }
            }
            HExpr::Call { callee: new_callee, args: new_args, type_args: type_args,
                resolved_dicts: resolved_dicts, dict_dispatch: dict_dispatch,
                ty: ty, effects: effects, span: span }
        },

        HExpr::FieldAccess { receiver, field, ty, effects, span } => {
            // B-104 D1 Stage 2 — RECEIVER position: a FRESH-OWNED receiver
            // (`f(x).method()`, `make().field`, `s.char_at(i).unwrap_or("")`'s
            // char_at Option — the lexer per-char leak) was read in place and
            // never dropped.  Materialise it (anf_operand): `let __anf = f(x);
            // __anf.method()` — scope-end-dropped like any owned binding.
            //
            // SOUNDNESS (why a projection/method result never dangles):
            //   * The projection (FieldAccess/IndexExpr) and every borrow-
            //     returning method result (is_borrow_returning_call) are OWNER-
            //     BEARING — any escape of them is Clone-wrapped by rc_escape, so
            //     a binding/sink owns an independent dup before __anf's scope-end
            //     drop runs.  Non-escaping uses are transient borrows consumed
            //     within the statement, strictly before the scope-end drop.
            //   * A borrow tail of a DROPPING block (cond wrappers: while-cond /
            //     guards / &&-RHS) is Clone-wrapped by the rc_block_inner
            //     tail-escape invariant — the one position where a borrow of the
            //     materialised receiver outlives the block's own drops.
            //   * Fresh receivers of Unit-typed mutators (`f(x).push(v)`) are
            //     reclaimed (the receiver-returning ABI result is excluded by
            //     rule ② everywhere).  `fold` returns an ARG, never the receiver,
            //     so receiver materialisation is independent of
            //     is_arg_returning_call.
            //   * Borrow receivers (Ident / FieldAccess chains / non-Str index /
            //     borrow-returning calls) fail anf_should_materialize and stay
            //     in-place reads — unchanged.
            // Evaluation order preserved: the receiver's hoist precedes the
            // args' hoists (anf_callee runs before the args loop in the Call arm).
            HExpr::FieldAccess { receiver: anf_operand(receiver, hoists, externs, counter),
                field: field, ty: ty, effects: effects, span: span }
        },

        HExpr::IndexExpr { receiver, index, ty, effects, span } => {
            // Read: receiver follows the same Stage 2 receiver-position rule as
            // FieldAccess above (`f(x)[0]` materialises f(x); the element read
            // borrows __anf, Clone-wrapped on escape, dropped at scope end);
            // index is a read operand.
            HExpr::IndexExpr { receiver: anf_operand(receiver, hoists, externs, counter),
                index: anf_operand(index, hoists, externs, counter),
                ty: ty, effects: effects, span: span }
        },

        HExpr::StructLit { name, type_args, fields, spread, ty, effects, span } => {
            // Each field value escapes into the struct → tail/escape position; its
            // OWN nested subexprs hoist, but the field value itself is not
            // materialised (it is stored directly into the struct by the RC pass).
            let mut new_fields: List<HStructFieldInit> = []
            for f in fields {
                new_fields.push(HStructFieldInit { name: f.name, value: anf_tail_value(f.value, hoists, externs, counter) })
            }
            let new_spread = match spread {
                some(s) => some(anf_borrow(s, hoists, externs, counter)),
                none => none,
            }
            HExpr::StructLit { name: name, type_args: type_args, fields: new_fields,
                spread: new_spread, ty: ty, effects: effects, span: span }
        },

        HExpr::NamedVariantConstruct { enum_name, variant_name, fields, spread, ty, effects, span } => {
            let mut new_fields: List<HStructFieldInit> = []
            for f in fields {
                new_fields.push(HStructFieldInit { name: f.name, value: anf_tail_value(f.value, hoists, externs, counter) })
            }
            let new_spread = match spread {
                some(s) => some(anf_borrow(s, hoists, externs, counter)),
                none => none,
            }
            HExpr::NamedVariantConstruct { enum_name: enum_name, variant_name: variant_name,
                fields: new_fields, spread: new_spread, ty: ty, effects: effects, span: span }
        },

        HExpr::ListLit { elements, ty, effects, span } => {
            let mut new_elems: List<HExpr> = []
            for e in elements { new_elems.push(anf_tail_value(e, hoists, externs, counter)) }
            HExpr::ListLit { elements: new_elems, ty: ty, effects: effects, span: span }
        },

        HExpr::TupleLit { elements, ty, effects, span } => {
            let mut new_elems: List<HExpr> = []
            for e in elements { new_elems.push(anf_tail_value(e, hoists, externs, counter)) }
            HExpr::TupleLit { elements: new_elems, ty: ty, effects: effects, span: span }
        },

        HExpr::RangeExpr { start, end, inclusive, ty, effects, span } => {
            HExpr::RangeExpr { start: anf_tail_value(start, hoists, externs, counter),
                end: anf_tail_value(end, hoists, externs, counter),
                inclusive: inclusive, ty: ty, effects: effects, span: span }
        },

        HExpr::StringInterp { parts, ty, effects, span } => {
            // Interpolated expressions are read (stringified) operands — materialise
            // each fresh-owned piece so it is reclaimed (the boxed temps that feed
            // string building are a notable Str-leak source).
            let mut new_parts: List<HStringInterpPart> = []
            for p in parts {
                match p {
                    HStringInterpPart::Expression(e) =>
                        new_parts.push(HStringInterpPart::Expression(anf_operand(e, hoists, externs, counter))),
                    HStringInterpPart::Literal(s) =>
                        new_parts.push(HStringInterpPart::Literal(s)),
                }
            }
            HExpr::StringInterp { parts: new_parts, ty: ty, effects: effects, span: span }
        },

        HExpr::Block { stmts, tail, ty, effects, span } => {
            // A nested block expression: it is its own scope (R2) — normalise its
            // statements/tail in place; nothing escapes to the outer `hoists`.
            anf_block_expr(expr, externs, counter)
        },

        HExpr::IfExpr { condition, then_branch, else_branch, ty, effects, span } => {
            // Condition is ALWAYS evaluated → its temps hoist into the enclosing
            // statement list (R4).  Each branch is its own scope (R2) — branch
            // values are materialised inside the branch block, never lifted out.
            let new_cond = anf_operand(condition, hoists, externs, counter)
            let new_then = anf_block_expr(then_branch, externs, counter)
            let new_else = match else_branch {
                some(eb) => some(anf_block_expr(eb, externs, counter)),
                none => none,
            }
            HExpr::IfExpr { condition: new_cond, then_branch: new_then,
                else_branch: new_else, ty: ty, effects: effects, span: span }
        },

        HExpr::MatchExpr { scrutinee, arms, ty, effects, span } => {
            // B-104 W2: materialise a FRESH-OWNED scrutinee (`match map.get(k) {…}`,
            // `match find(…) {…}` — the dominant residual OPTION leak: fresh Option
            // temporaries read once by the match and never dropped).  anf_operand
            // hoists `let __anf = <scrutinee>` before the enclosing statement, so the
            // RC pass scope-end-drops it.  Only fresh-owned scrutinees materialise
            // (anf_should_materialize): an Ident / FieldAccess / IndexExpr scrutinee is
            // a borrow and stays inline.
            //
            // SOUND WITHOUT match-arm return-value analysis — the earlier `_ => scrut`
            // double-free fear is already neutralised by clone-all-escape.  When the
            // match is in escape position, EACH arm tail is rc_escape'd individually:
            // an arm that returns the scrutinee (`x => x`), a pattern binding (`some(v)
            // => v`, a borrow projection of the scrutinee's interior), or any owner-
            // bearing projection is Clone-wrapped (ring_dup) → the result binding owns
            // a FRESH dup, and the scrutinee's scope-end Drop releases the original —
            // balanced (rc bumped before either drop, drop order-independent).  When
            // the match is NOT in escape position (statement / borrow arg), arm tails
            // are borrows and nothing else takes ownership, so the scrutinee's single
            // scope-end Drop is still balanced.  Same Clone-wrap balance that makes
            // W1's unwrap_or arg safe.  Unlike `fold` (W1 is_arg_returning_call), a
            // match never MOVES the scrutinee out un-dup'd — arm tails always route
            // through rc_escape, which Clones owner-bearing returns.  ASan-verified
            // (real_program matches + self-compile).
            // Arm bodies + guards are their own scopes (R2).
            let new_scrutinee = anf_operand(scrutinee, hoists, externs, counter)
            let mut new_arms: List<HMatchArm> = []
            for arm in arms {
                let new_guard = match arm.guard {
                    some(g) => some(anf_cond_in_own_scope(g, externs, counter)),
                    none => none,
                }
                let new_body = anf_block_expr(arm.body, externs, counter)
                new_arms.push(HMatchArm { pattern: arm.pattern, guard: new_guard, body: new_body, span: arm.span })
            }
            HExpr::MatchExpr { scrutinee: new_scrutinee, arms: new_arms, ty: ty, effects: effects, span: span }
        },

        HExpr::TryCatch { body, arms, ty, effects, span } => {
            // body + catch arms are their own scopes (R2); abort-path RC is out of
            // scope (B-002).
            let new_body = anf_block_expr(body, externs, counter)
            let mut new_arms: List<HMatchArm> = []
            for arm in arms {
                let new_body_arm = anf_block_expr(arm.body, externs, counter)
                new_arms.push(HMatchArm { pattern: arm.pattern, guard: arm.guard, body: new_body_arm, span: arm.span })
            }
            HExpr::TryCatch { body: new_body, arms: new_arms, ty: ty, effects: effects, span: span }
        },

        HExpr::HandleExpr { body, handlers, ty, effects, span } => {
            let new_body = anf_block_expr(body, externs, counter)
            let mut new_handlers: List<HEffectHandler> = []
            for h in handlers {
                let h_body = anf_block_expr(h.body, externs, counter)
                new_handlers.push(HEffectHandler {
                    effect_name: h.effect_name, op_name: h.op_name,
                    params: h.params, resume_name: h.resume_name, body: h_body
                })
            }
            HExpr::HandleExpr { body: new_body, handlers: new_handlers, ty: ty, effects: effects, span: span }
        },

        HExpr::Lambda { params, return_type, body, ty, effects, span } => {
            // The lambda body is its own function scope.  Captures are dup'd by
            // gen_lambda; perceus handles the body.  Normalise the body in place.
            HExpr::Lambda { params: params, return_type: return_type,
                body: anf_block_expr(body, externs, counter),
                ty: ty, effects: effects, span: span }
        },

        HExpr::EffectOp { effect_name, op_name, args, ty, effects, span } => {
            // B-104 D1 Stage 2 — EFFECT-OP ARG position (closes the W1-era
            // conservative hold-out).  Args are BORROW-passed to the handler
            // closure (gen_effect_op → gen_closure_call; closure params are
            // never dropped by the callee), so a fresh-owned arg had no owner
            // and leaked.  Materialise + scope-end-drop is SOUND here, unlike
            // the old fear of "handler returns an arg verbatim":
            //   * a TAIL-RESUMPTIVE handler arm is transformed with
            //     rc_block_root(escape=true) — an arm returning its parameter
            //     (`Echo.echo(s) => s`) has the tail Clone-wrapped at the
            //     escape, so the op's result is an independent dup, balancing
            //     the materialised arg's scope-end drop (the same Clone-wrap
            //     balance as W1's unwrap_or and the W2 scrutinee).  A handler
            //     STORING an arg likewise Clones at the escape.
            //   * an ABORT op (fail.raise → ring_raise, longjmp) never returns:
            //     the materialised __anf's scope-end drop is skipped by the
            //     longjmp → leak, not UAF — identical to the pre-existing
            //     abort-path posture (B-002); the catch arm's projections of
            //     the raised value stay valid (the owner binding is simply
            //     never released).
            let mut new_args: List<HExpr> = []
            for a in args { new_args.push(anf_operand(a, hoists, externs, counter)) }
            HExpr::EffectOp { effect_name: effect_name, op_name: op_name, args: new_args,
                ty: ty, effects: effects, span: span }
        },

        // Clone is inserted by perceus (after ANF); never present in input.
        HExpr::Clone { .. } => expr,
    }
}

// Normalise a callee expression (the function/method being called): an Ident or a
// FieldAccess (method receiver).  Its subexprs are normalised but the callee
// itself is a borrow read — never materialised.
fn anf_callee(callee: HExpr, mut hoists: List<HStmt>, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    anf_borrow(callee, hoists, externs, counter)
}

// Normalise an expression on the residual NO-MATERIALISE path: recurse into its
// subexprs (which still hoist their own fresh operands), but NEVER materialise
// the top expression.  Since B-104 D1 Stage 2 (receiver positions now go through
// anf_operand — see the FieldAccess/IndexExpr arms) only two positions remain:
//   * the CALLEE expression itself (an Ident or the method FieldAccess — never a
//     materialisable form; a hypothetical Call-callee `get_fn()(x)` would be a
//     residual leak, kept conservative);
//   * a STRUCT/VARIANT SPREAD source: codegen copies the source's field pointers
//     RAW (no dup) into the new struct — materialising a fresh spread source
//     would scope-end-drop it, deep-freeing the fields the new struct now holds
//     → UAF.  Spread sources must stay un-owned reads (leak-on-spread, the
//     documented L1 posture).
fn anf_borrow(expr: HExpr, mut hoists: List<HStmt>, externs: Set<Str>, mut counter: List<Int>) -> HExpr {
    anf_expr(expr, hoists, externs, counter)
}

fn transform_decls(decls: List<HDecl>, boxed: Set<Int>, externs: Set<Str>) -> List<HDecl> {
    let mut result: List<HDecl> = []
    for d in decls {
        result.push(transform_decl(d, boxed, externs))
    }
    result
}

fn transform_decl(decl: HDecl, boxed: Set<Int>, externs: Set<Str>) -> HDecl {
    match decl {
        HDecl::Fn { name, def_id, type_params, params, return_type, effects, body, is_pub, trait_bounds, span } => {
            let new_body = transform_fn_body(params, body, boxed, externs)
            HDecl::Fn {
                name: name, def_id: def_id, type_params: type_params,
                params: params, return_type: return_type, effects: effects,
                body: new_body, is_pub: is_pub, trait_bounds: trait_bounds, span: span
            }
        },
        HDecl::Impl { target_type, type_params, trait_name, methods, assoc_types, span } => {
            let new_methods = transform_decls(methods, boxed, externs)
            HDecl::Impl {
                target_type: target_type, type_params: type_params,
                trait_name: trait_name, methods: new_methods,
                assoc_types: assoc_types, span: span
            }
        },
        HDecl::Test { description, body, span } => {
            // Transform test bodies as parameterless functions
            let new_body = transform_fn_body([], body, boxed, externs)
            HDecl::Test { description: description, body: new_body, span: span }
        },
        HDecl::Const { name, def_id, ty, init, is_pub, span } => {
            // B-098: the const owns its value → the initialiser is in escape
            // position, with an empty enclosing owned scope (no locals at top level).
            let owned: List<Str> = []
            let mut gensym: List<Int> = [0]
            let new_init = rc_escape(init, owned, boxed, externs, gensym)
            HDecl::Const { name: name, def_id: def_id, ty: ty, init: new_init, is_pub: is_pub, span: span }
        },
        HDecl::ModBlock { name, decls: mod_decls, is_pub, span } => {
            HDecl::ModBlock { name: name, decls: transform_decls(mod_decls, boxed, externs), is_pub: is_pub, span: span }
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
// B-098: L1 borrow-inference engine (clone-all-escape model)
// Reference: Koka Perceus (POPL'21) borrowing extension, conservative variant.
//
// Replaces the L0 always-own + backward-liveness + branch-balancing model.  The
// new model (design.md §7.11):
//   1. READS BORROW — a read (Ident / field / index / container .get) does NOT
//      ring_dup; codegen returns the bare (borrowed) pointer.
//   2. ESCAPE = CLONE-OR-MOVE — at an escape point (a sink that takes ownership:
//      container push, struct/variant field, list/tuple element, return /
//      function tail, let initialiser, closure capture) the escaping value is:
//        * wrapped in HExpr::Clone if it has an INDEPENDENT OWNER (Ident binding /
//          FieldAccess / IndexExpr / container .get — the source still owns its
//          reference), giving the sink its own owned reference; or
//        * left as-is (MOVE) if it is a FRESH TEMPORARY (call result / literal /
//          struct/variant construction / binop / closure / fresh container), the
//          sink becoming the sole owner.
//   3. SCOPE-END-DROP-ONCE — every owned local binding is dropped exactly once at
//      the end of the block that defines it (the normal fall-through path).  An
//      explicit `return` clones its value (if owner-bearing) and then drops every
//      owned local in scope; the block-end drops on that path are unreachable
//      (return diverges), so there is no double-free.  NO per-path branch
//      balancing — branches only READ outer locals (borrow), so the outer local
//      drops exactly once at the outer block end regardless of which branch ran.
//      This is what eliminates the #134 loop/conditional-move double-free at the
//      root: a binding is never consumed per-path, so there is no imbalance to
//      "balance" with spurious drops.
//   4. ALL PARAMETERS BORROW — the callee never drops a parameter; a parameter
//      that escapes is cloned (the caller retains ownership).  move-parameter
//      inference (§7.3) is a pure optimisation, deferred.
//   5. NO last-use → move (deferred to L3 reuse): even a last-use owner-bearing
//      escape is cloned then scope-end-dropped.  More churn than a perfect
//      analysis, but fewer dups than always-own (reads ≫ escapes) and crash-free.
//
// `owned` (List<Str>): the owned local bindings currently in scope, in definition
// order (outermost block first).  Threaded by VALUE (each block passes a fresh
// concat down) so there is no aliasing across siblings.  A `return` drops the
// full `owned` set it receives.
// ============================================================

fn transform_fn_body(params: List<HParam>, body: HExpr, boxed: Set<Int>, externs: Set<Str>) -> HExpr {
    // All parameters BORROW (point 4): the function entry owns nothing — params
    // belong to the caller.  So the function body's enclosing owned set starts
    // empty.  rc_block then inserts scope-end drops for body-local bindings and
    // return-path drops, and clones escapes.  The function body is a tail/escape
    // position: its value is the return value (the caller takes ownership).
    let owned: List<Str> = []
    // Per-function hoist-temp counter (single-element mutable cell).  Per-function
    // scope guarantees the `__rc_scope_N` names are unique within each function's
    // flat named_values map.
    let mut gensym: List<Int> = [0]
    rc_block_root(body, true, owned, boxed, externs, gensym)
}

// hexpr_effects is imported from hir

// ============================================================
// Owner classification (clone-all-escape)
// ============================================================
//
// A value "has an independent owner" — i.e. the source still holds a reference
// after this value is produced — exactly when it is a READ of an existing owned
// location: an Ident binding, a FieldAccess / IndexExpr projection, or a
// container-element read (.get).  These all alias a reference owned elsewhere,
// so escaping them needs a Clone (the runtime read returns a BORROW after the
// always-own dup is reverted).  Everything else is a FRESH TEMPORARY (call
// result, literal, struct/variant construction, binop, range, fresh container,
// closure, string-interp, .values()/.entries() which build owned containers):
// it has no other owner, so the sink moves it in (no clone — cloning would leak).
fn is_owner_bearing(expr: HExpr) -> Bool {
    match expr {
        HExpr::Ident { .. } => true,
        HExpr::FieldAccess { .. } => true,
        // B-104 D1 rule ③: `s[i]` on a Str is NOT owner-bearing — ring_str_get
        // returns a FRESH 1-char string (new ring_alloc, verified), so an escape
        // MOVES it (the sink becomes sole owner; Clone-wrapping would dup the
        // fresh string and leak the original, the pre-rule behaviour).  List/Map
        // indexing returns a borrowed element pointer → owner-bearing (escape
        // Clones) as before.
        HExpr::IndexExpr { receiver, .. } => is_str_index(receiver) == false,
        HExpr::Call { callee, .. } => is_borrow_returning_call(callee),
        _ => false,
    }
}

// A method call whose result is a BORROW of (an inner reference of) its receiver
// or an argument, returned WITHOUT a dup by the runtime — so escaping it needs a
// Clone, AND scope-end-dropping its binding would free a reference owned elsewhere.
//
// ═════════════════════════════════════════════════════════════════════════════
// B-103 COMPLETE ring_runtime.cpp RETURN-MODE CLASSIFICATION (2026-06-11)
// ═════════════════════════════════════════════════════════════════════════════
// Total enumeration of every extern "C" function in ring_runtime.cpp by return
// mode, with the source evidence (does the body alloc/dup before returning?).
// This table is THE drop-decision foundation for the B-104 D1 total drop pass:
// a temporary is droppable iff its producer is FRESH; a BORROW producer's result
// must never be dropped un-Cloned.  Four modes:
//   FRESH    — returns a pointer freshly ring_alloc'd (or with element/payload
//              ownership transferred/dup'd in).  Caller solely owns it.
//   BORROW   — returns a pointer INTO an argument/receiver (or the arg itself)
//              without a dup.  Caller owns nothing.
//   SCALAR   — returns i64/double/void: no RC meaning.
//   NULL/NEVER — returns nullptr (ring_drop(null) is a no-op → RC-inert) or
//              never returns (exit/panic/longjmp).
//
// ── BORROW returners (every one MUST be covered by this predicate, by
//    is_owner_bearing's Ident/FieldAccess/IndexExpr arms, or — for the
//    Unit-typed receiver-returning mutators — by the D1 rule ② type-level
//    Unit exclusion) ─────────────────────────────────────────────────────────
//   ring_Option_unwrap        .unwrap          → Some payload slot (no dup).
//   ring_Option_unwrap_or     .unwrap_or       → payload slot, or the `default`
//                                                ARGUMENT verbatim on None.
//   ring_Option_unwrap_or_else .unwrap_or_else → payload slot, or the closure's
//                                                result forwarded.
//   ring_Option_to_fail       .to_fail         → payload slot (None raises).
//   ring_list_get             list[i] / tuple .0 / for-in   → element ptr, no dup
//                             (HIR: IndexExpr / tuple FieldAccess — covered by
//                              is_owner_bearing's IndexExpr/FieldAccess arms, NOT
//                              by a field name here).
//   ring_map_get / ring_map_int_get   m[k]     → value ptr, no dup (HIR: IndexExpr).
//   RECEIVER-RETURNING MUTATORS (B-103 Wave A → B-104 D1 rule ② re-mechanised):
//   each returns its RECEIVER (arg 0) verbatim — `return list;` / `return map;`
//   / `return set;` / `return sb;` — no dup.  Ring-level type is Unit, but at
//   the LLVM ABI the result IS the live container, so a `let x = xs.push(v)`
//   binding scope-end-dropped would free the caller's container → UAF.
//   B-103 guarded this by LISTING the 9 field names below in this predicate
//   (Clone-wrap balanced the drop) — at a leak-side cost: a USER method sharing
//   a listed name but returning a real fresh value got Clone-wrapped (leak),
//   and a fn-tail mutator result's Clone dup-pinned the receiver.  D1 rule ②
//   (2026-06-11 user decision) replaces the name grain with the TYPE-level
//   Unit rule: every one of these calls is Unit-typed (all 13 std declarations
//   verified `-> Unit`: List.push/extend/clear/set, Map.insert/remove/clear,
//   Set.insert/remove/clear, SB.add/line/add_int), and Unit-typed values are
//   excluded from Clone (rc_escape), Drop/owned (is_droppable_init) and
//   materialisation (anf_should_materialize) — so the binding holds the raw
//   receiver pointer and never drops it: same UAF protection, zero churn, and
//   user methods with these names are no longer misclassified.  The names are
//   therefore REMOVED from the predicate; the ABI evidence stays recorded here
//   (D1's total pass must keep treating their results as non-droppable, which
//   the Unit type rule does for every position).
//   Residual (accepted, see worker_feedback): a Unit value flowing into an RC
//   SINK (`[xs.push(v)]` — a List<Unit>) would store the receiver un-dup'd and
//   the sink's drop would free it; pathological, not expressible in real code
//   paths today.  The principled long-term fix is codegen emitting null for
//   Unit-typed values instead of the receiver-return ABI accident.
//     .push    ring_list_push                  → `return list;`
//     .set     ring_list_set                   → `return list;`
//     .insert  ring_map_set / ring_map_int_set → `return map;`
//              (Set.insert → ring_set_add / ring_set_int_add → `return set;`)
//     .remove  ring_map_delete / ring_map_int_delete / ring_set_delete /
//              ring_set_int_delete             → `return map/set;`
//     .add     ring_set_add / ring_set_int_add / ring_sb_add → `return set/sb;`
//     .clear   ring_list_clear / ring_map_clear / ring_map_int_clear /
//              ring_set_clear / ring_set_int_clear → `return receiver;`
//     .extend  ring_list_extend                → `return list;` (the OTHER list's
//              elements are dup'd inside the runtime — B-102 layer 5)
//     .line / .add_int  ring_sb_line / ring_sb_add_int → `return sb;`
//              (currently unmapped in method_to_runtime — native panic-stub, see
//              audit-report — but std/str.ring declares them; classified now so
//              the mapping fix cannot reopen a UAF.)
//   ring_catch_get_error — returns the raised error ptr held by the frame
//              (codegen-internal: catch lowering only; never an HIR call).
//
// ── FRESH returners (safe to drop; is_droppable_init(Call)=true reclaims) ─────
//   Str ops (alloc a new std::string block): ring_str_new / from_cstr / concat /
//     slice / split (fresh list of fresh strs) / join / replace / trim /
//     trim_start / trim_end / to_upper / to_lower / pad_start / pad_end / repeat
//     / ring_int_to_str / float_to_str / bool_to_str / ring_str_get (str[i]
//     allocs a NEW 1-char string — FRESH; classified per-receiver by D1 rule ③:
//     is_owner_bearing / anf_should_materialize special-case Str-receiver
//     IndexExpr as fresh, see is_str_index) / ring_list_join /
//     ring_json_stringify / ring_cwd / ring_read_file / ring_path_join / resolve
//     / dirname / basename / extname.
//   Option builders (fresh 2-slot block; payload dup'd or ownership-transferred):
//     ring_list_get_opt / ring_map_get_opt / ring_map_int_get_opt (dup payload),
//     ring_list_first / last / find (dup payload — B-103), ring_list_find_index /
//     ring_str_char_at / char_code_at / index_of / last_index_of / ring_parse_int
//     / parse_float (fresh boxed payload), ring_list_pop / shift (payload
//     OWNERSHIP TRANSFERRED out of the vector — vec erases its ref, no dup
//     needed), ring_Option_map (wraps the closure's owned result).
//   Container builders: ring_list_new / map_new / map_int_new / set_new /
//     set_int_new / sb_new / ring_args / ring_map_keys (fresh strs) /
//     map_int_keys (fresh boxes) / ring_map_values / entries / map_int_values /
//     entries (dup values — B-098/B-103) / ring_set_to_list / set_int_to_list
//     (fresh strs/boxes) / ring_set_from_list / set_int_from_list (inline-value
//     copies) / ring_set_union / intersect / difference (+ _int variants; inline
//     values, no RC sharing) / ring_set_clone / set_int_clone (inline values) /
//     ring_list_clone / map_clone / map_int_clone (dup elements/values — B-103 /
//     #135) / ring_list_map (owns closure results) / ring_list_filter / concat /
//     slice / reverse / sort / sort_default / flat_map / ring_map_from /
//     map_int_from (dup shared elements/values — B-103 Wave A: these copied
//     source-owned pointers into the fresh container WITHOUT a dup, so dropping
//     both source and result deep-dropped the same elements → latent double-free,
//     masked only while the leak régime never dropped the source) / ring_sb_to_str.
//   Boxers (codegen-internal): ring_box_int / box_float / box_bool, the Eq/Ord
//     dict closure shims ring_cl_eq_* / cl_ne_* / cl_cmp_* (fresh boxed results),
//     ring_get_builtin_dict (fresh TUPLE dict of fresh closures), ring_file_exists
//     (fresh bool box), ring_alloc itself, ring_catch_push (codegen-internal).
//   ring_try — returns the body/catch closure's result (owned by Ring-fn
//     convention).  HIR surface = TryCatch, conservatively excluded from
//     is_droppable_init (abort-path aliasing, B-002).
//
// ── SCALAR returners (i64/double — no RC meaning) ─────────────────────────────
//   ring_unbox_int / unbox_float / unbox_bool (codegen-internal; HIR never sees
//   an "unbox call" — unboxing is emitted inside arith/compare/cond lowering),
//   ring_str_len / eq / lt / contains / starts_with / ends_with / is_empty,
//   ring_list_len / contains / index_of / is_empty / any / all,
//   ring_map_has / len, ring_map_int_has / len, ring_set_has / len,
//   ring_set_int_has / len, ring_sb_len, ring_Option_is_some / is_none,
//   ring_catch_setjmp (codegen-internal).
//
// ── NULL / NEVER returners (RC-inert: ring_drop(null) is a no-op) ─────────────
//   null:  ring_print / eprintln / write_file / delete_file / assert /
//          ring_list_for_each / map_for_each / map_int_for_each / set_for_each /
//          set_int_for_each.
//   never: ring_panic / exit / match_fail / ring_raise / __ring_raise_fail
//          (longjmp/exit).
//   void:  ring_dup / drop / register_drop / register_never_drop / runtime_init /
//          ring_catch_pop (codegen-internal plumbing).
//
// ── Static (not extern, runtime-internal only) ────────────────────────────────
//   ring_enum_some / enum_none (FRESH; HIR surface = variant-ctor call, whose
//   args are sink positions — is_variant_constructor_call), ring_make_closure /
//   make_eq_dict / make_ord_dict (FRESH, dict plumbing), drop_* destructors.
//
// ── Out-of-table: non-RC extern pointers (llvm_ffi.ring) ──────────────────────
//   The 59 LLVM-C API externs return OPAQUE FOREIGN handles that are NOT
//   ring_alloc'd — neither FRESH nor BORROW: ring_dup/ring_drop on them reads a
//   garbage header → corruption.  They need full RC EXCLUSION (never Clone,
//   never drop), which is a TYPE-level property (ExternType), not a name-list
//   entry here.  Dormant today (codegen_llvm only executes when the native
//   compiler itself runs --target=llvm — B-099 scope); flagged as a hard D1
//   prerequisite in worker_feedback + audit-report.
// ═════════════════════════════════════════════════════════════════════════════
//
// NOTE: `.get()` is NOT here — list.get / map.get build a FRESH owned Option
// (ring_*_get_opt, which ring_dup's the element into the Option), so their result
// is a fresh owned temporary, not a borrow.  `.first` / `.last` (B-103: now
// ring_dup in ring_list_first/last) and `.values()` / `.entries()` / `.keys()` /
// `.pop` / `.shift` likewise build FRESH owned containers — not borrows.
//
// Safety asymmetry: mis-listing a fresh-temp call here only LEAKS (an extra dup
// whose source leaks); OMITTING a genuine borrow-returner CRASHES (UAF when the
// escaped borrow is scope-end-dropped).  So this list errs toward inclusion.
// Known leak-side cost of the name-grain match: a USER method that happens to
// share a listed name and returns a real fresh value gets Clone-wrapped on
// escape → its result leaks one refcount (crash-free; the cost class of a user
// method named `unwrap`).  B-104 D1 rule ② removed the 9 receiver-returning
// mutator names from this list (push/set/insert/remove/add/clear/extend/line/
// add_int — their UAF protection is now the TYPE-level Unit exclusion, see the
// classification table above), shrinking that cost to the 4 Option projections.
//
// ⚠️ THE PREDICATE ITSELF NOW LIVES IN hir.ring (B-104 D1 Stage 2): the LLVM
// codegen's condition-box drops (emit_while / match-guard post-unbox,
// is_fresh_owned_bool_value) need the same classification, and cross-stage
// contracts belong in hir.ring.  THIS TABLE REMAINS THE EVIDENCE RECORD —
// update it together with any membership change in hir.ring's
// is_borrow_returning_call / is_arg_returning_call.

// B-104 W1 (arg materialise): a call whose result may be ONE OF ITS ARGUMENTS
// returned VERBATIM (no dup) AND whose result is NOT Clone-wrapped on escape
// (callee ∉ is_borrow_returning_call → is_owner_bearing(Call) is false → the
// binding MOVES the result).  For such a callee, MATERIALISING an argument into a
// `let __anf` and scope-end-dropping it would double-free: on the arg-returning
// path the result IS the arg box, the result binding also owns it (move), so both
// drop the same allocation (list_fold.ring empty-list heap corruption).  Args to
// these callees must therefore stay UN-materialised borrows (anf_arg, recurse-only)
// — a residual crash-free leak, the cost of not having full callee return-mode
// analysis.
//
// Membership is NARROW by design.  An arg-returning callee that IS borrow-returning
// (e.g. `Option.unwrap_or` returns the `default` ARGUMENT on None) does NOT belong
// here: its result is Clone-wrapped on escape (is_owner_bearing(Call)=true via
// is_borrow_returning_call), and that dup exactly balances the materialised arg's
// scope-end drop — so materialising unwrap_or's arg is SOUND, no double-free.  Only
// `fold` qualifies: it returns `init` verbatim on an empty list AND its result is
// MOVED (it cannot join is_borrow_returning_call — on the common non-empty path it
// returns the closure's FRESH owned accumulator, which Clone-wrapping would leak).
//
// Safety asymmetry (mirrors is_borrow_returning_call, opposite direction): OMITTING
// a genuine return-arg-and-move callee → a materialised arg double-frees → CRASH.
// Mis-INCLUDING a callee → its args stay borrows → LEAK (crash-free).  So this list
// errs toward INCLUSION.  ASan (real_program ×3 + self-compile) is the completeness
// net: a double-free pinpoints a missed callee, which is then added here.
//
// B-103 COMPLETENESS AUDIT (2026-06-11, full ring_runtime.cpp enumeration — see
// the classification table above is_borrow_returning_call): `fold` remains the
// SOLE member.  Every other runtime function that returns an argument verbatim
// falls in one of two exempt classes:
//   1. Option projections (`unwrap_or` returns `default`; `unwrap_or_else`
//      forwards the closure result) — ∈ is_borrow_returning_call, so the result
//      is Clone-wrapped on escape; that dup balances a materialised arg's drop.
//   2. Receiver-returning mutators (push/set/insert/remove/add/clear/extend/
//      line/add_int return ARG 0) — exempt on TWO grounds: the returned
//      "argument" is the RECEIVER, which is part of the FieldAccess callee,
//      not of `args`, so anf never materialises it; and their results are
//      Unit-typed, so D1 rule ② excludes them from Clone/Drop/owned/materialise
//      at every position (B-104; previously the B-103 name listing in
//      is_borrow_returning_call provided the equivalent Clone-wrap balance).
//      Their VALUE args are sink positions (sink_arg_indices → rc_escape
//      Clone), which independently balances a materialised arg's drop.
// Ring-level functions can never join this list: clone-all-escape Clone-wraps a
// returned borrowed param at the return/tail escape position, so every Ring fn
// returns OWNED (the B-103 "no fixpoint needed" theorem, backlog B-103).
//
// ⚠️ Predicate relocated to hir.ring alongside is_borrow_returning_call (shared
// with the codegen condition-box drops); this comment block is its evidence.

// ─────────────────────────────────────────────────────────────────────────────
// B-101 DEAD ROAD (Wave A,证伪 2026-06-05) — DO NOT re-introduce a function-level
// drop-WHITELIST for the substitution family.  Recorded here so the trap is not
// re-dug.
//
// The tempting fix for the apply_subst-family LEAK (§7.11-correction-#2: "Call
// result conservatively not dropped") is a DUAL of is_borrow_returning_call: a
// whitelist of calls whose result is a FRESH, UNSHARED owned value, safe to
// scope-end-drop.  Wave A proved this whitelist must be EMPTY:
//   - apply_subst / apply_subst_map (env.ring): scalar `=> t` arms and the
//     unresolved-TypeVar `if root == id { t }` arm return the INPUT verbatim
//     (alias); StructType `{ fields: fields }` / EnumType `{ variants: variants }`
//     reuse the input's substructure (alias); ErrorType `=> t` aliases.
//   - apply_subst_row / apply_subst_effect(_map): `_ => e` passes the input
//     Effect through (alias of an element).
//   - zonk_type / zonk_row: wrap apply_subst + label_vars, same passthroughs.
// Type tree is a deliberately-shared IMMUTABLE DAG, so NO function-level grain can
// certify "every arm fresh".  Mis-listing → drop of live shared state → UAF/CRASH;
// omitting → leak.
//
// B-102 R-clean (2026-06-07) — the substitution aliasing is resolved NOT by a
// call-level whitelist but by clone-all-escape itself: each place that stores an
// EXISTING Type substructure into a freshly-built Type is an escape position, so
// rc_escape Clone-wraps it (ring_dup).  A scalar `=> t` return aliases the
// borrowed param `t`, but `t` is in TAIL (escape) position → rc_escape Clones it,
// so the caller's `let x = apply_subst(...)` owns a fresh dup, balanced by the
// scope-end drop_T.  StructType `{ fields: fields }` Clone-wraps `fields` (a
// borrowed List<StructField>): the new Type owns its own shallow reference,
// released by the recursive drop_T symmetrically.  No function-level escape
// analysis, no never-drop special case — Type is ordinary RC'd data again.
//
// B-103 (2026-06-07) — the ban above still holds (no per-call FRESH-vs-aliased
// whitelist), but is_droppable_init's Call arm now returns `true` UNIVERSALLY, not
// just for borrow-returners.  This is sound WITHOUT a whitelist precisely because
// of the clone-all-escape reasoning above: every apply_subst-family return value
// reaches its caller's `let x = ...` already Clone-wrapped (the aliased arm's value
// is in tail/escape position → rc_escape Clones it), so `x` owns a FRESH dup,
// safely released by the scope-end drop_T.  The flood of 167 `let x = apply_subst`
// bindings is thereby reclaimed (G-a memory gate) with no function-grain analysis.
// ─────────────────────────────────────────────────────────────────────────────

// Wrap an escaping expression: clone it iff it has an independent owner; the
// inner expression is processed in VALUE (borrow) position so its own reads do
// not clone.  Carries inner's type/effects/span on the Clone node.
fn rc_escape(expr: HExpr, owned: List<Str>, boxed: Set<Int>, externs: Set<Str>, mut gensym: List<Int>) -> HExpr {
    // B-102 R-clean: Type-DAG values participate in normal clone-all-escape RC —
    // an escaping owner-bearing Type substructure (e.g. apply_subst's
    // `Type::StructType { ..., fields: fields }`, where `fields` is a borrowed
    // List<StructField> from the input) is Clone-wrapped (ring_dup) so the new
    // parent Type owns its own (shallow) reference, symmetric with the recursive
    // drop_T that releases it.  (A1's never-drop special case is removed.)
    //
    // B-104 D1 rule ① (audit #139) + rule ② (Unit), both TYPE-level:
    //   ① a DIRECT extern-handle value never Clones — ring_dup would WRITE a
    //     refcount into foreign (non-ring_alloc) memory.  It escapes as a MOVE
    //     (the sink stores the raw handle; no holder ever drops it —
    //     extern-typed/extern-containing bindings are excluded from the owned
    //     set and drop_T skips extern-typed fields).  DIRECT-type test only: a
    //     CONTAINER of extern handles (List<LLVMTypeRef>, LLVMValueRef?) has a
    //     real RC header, so its shallow Clone stays allowed/safe — only its
    //     DROP is excluded (type_contains_extern_handle in is_droppable_init).
    //   ② a Unit-typed value never Clones — Unit has no value semantics, and at
    //     the LLVM ABI a Unit-typed mutator call result IS the receiver
    //     (`return list;`), so Cloning it ring_dup-pins the caller's container
    //     (the B-103 leak-side cost this rule eliminates).  MOVE instead; the
    //     binding/sink is RC-inert because Unit is excluded from droppability
    //     and materialisation everywhere (is_rc_excluded_type).
    if is_owner_bearing(expr) && is_rc_excluded_type(hexpr_type(expr), externs) == false {
        let inner = rc_expr(expr, false, owned, boxed, externs, gensym)
        HExpr::Clone {
            inner: inner,
            ty: hexpr_type(expr),
            effects: hexpr_effects(expr),
            span: hexpr_span(expr)
        }
    } else {
        // Fresh temporary: move (no clone).  Recurse so nested escape positions
        // inside it (struct fields, list elements, container-sink args, branch
        // bodies, etc.) are still handled.
        rc_expr(expr, true, owned, boxed, externs, gensym)
    }
}

// ============================================================
// Block transform (the unit that owns and drops local bindings)
// ============================================================
//
// `escape`: whether the block's VALUE escapes into an owned slot (function tail,
//   let initialiser block, escape-position if/match arm).  When true the tail is
//   cloned if owner-bearing.  When false the value is a borrow (statement /
//   condition / call-arg position).
//
// Scope-end-drop-once: bindings defined directly by this block's statements are
// dropped at the block's end (fall-through path).  To run those drops AFTER the
// tail value is computed (so a returned/used local is not freed before use), the
// tail is hoisted into a fresh `let __rc_scope_N`, then the locals drop, then the
// hoist temp becomes the new tail.  A diverging block (ends in return/break/
// continue) skips the block-end drops: they are unreachable, and a `return`
// inside has already dropped the full owned set.

fn rc_block_root(body: HExpr, escape: Bool, owned: List<Str>, boxed: Set<Int>, externs: Set<Str>, mut gensym: List<Int>) -> HExpr {
    match body {
        HExpr::Block { stmts, tail, ty, effects, span } => {
            let res = rc_block_inner(stmts, tail, escape, owned, boxed, externs, gensym)
            HExpr::Block { stmts: res.0, tail: res.1, ty: ty, effects: effects, span: span }
        },
        _ => {
            // Non-block body (single expression): it is the tail in escape (return)
            // position.  No block-local bindings to drop.
            rc_escape_or_value(body, escape, owned, boxed, externs, gensym)
        },
    }
}

// Process a block's statement list + tail.  Returns (new_stmts, new_tail).
fn rc_block_inner(stmts: List<HStmt>, tail: HExpr?, escape: Bool, owned: List<Str>, boxed: Set<Int>, externs: Set<Str>, mut gensym: List<Int>) -> (List<HStmt>, HExpr?) {
    // Bindings defined directly by these statements (not nested loop/branch scopes).
    let block_locals = direct_block_locals(stmts, externs)

    // The owned set visible to each statement = enclosing owned ++ the bindings of
    // THIS block declared BEFORE that statement.  This must be built INCREMENTALLY
    // (not the full block_locals up front): a binding only becomes visible from its
    // `let` onward.  Codegen lowers every same-named local to one shared function-
    // entry alloca, so a `return` placed in an EARLIER statement that drops a
    // not-yet-declared name would free that alloca's stale/garbage contents — and,
    // when an outer block-local name collides with an inner-branch local of the same
    // name (e.g. two `let mut result` in disjoint `parse_type_expr` arms), the outer
    // declaration would be dropped in a branch where it was never constructed
    // (native self-compile UAF in resolve_type_expr's parsed TypeExpr, B-102 layer 3).
    // Names already in `owned` (a shadowing inner binding) are NOT re-added: the one
    // shared alloca must be dropped exactly once per control-flow path.
    //
    // NB: `concat` builds a FRESH list — we must NOT alias the caller's `owned`
    // (List is a reference type), or pushing a this-block local would mutate the
    // enclosing block's owned set and leak the name into sibling branches' drop
    // sets (B-102 layer 4: `let a` in an `if` arm leaking into a later arm's
    // `return`, freeing the never-initialised alloca).
    let mut visible_owned = owned.concat([])
    let mut new_stmts: List<HStmt> = []
    for s in stmts {
        // A statement (or any early return inside it) sees only locals already declared.
        for ns in rc_stmt(s, visible_owned, boxed, externs, gensym) { new_stmts.push(ns) }
        // After processing, this statement's own droppable binding (if any, and not
        // already owned by an enclosing scope) becomes visible to later statements.
        for n in stmt_droppable_locals(s, externs) {
            if visible_owned.contains(n) == false { visible_owned.push(n) }
        }
    }

    // This block's OWN fresh bindings (dropped at block end, fall-through path).
    // A block-local that shadows an enclosing owned name (same flat alloca) is NOT
    // re-dropped here — the enclosing scope owns that drop; re-dropping would free
    // the one shared alloca twice (B-102 layer-3 over-free).  Computed BEFORE the
    // tail so the tail's escape mode can depend on it (below).
    let mut own_block_locals: List<Str> = []
    for n in block_locals {
        if owned.contains(n) == false { own_block_locals.push(n) }
    }

    // B-104 D1 (Stage 2) — DROPPING-BLOCK TAIL-ESCAPE INVARIANT: a block that
    // emits scope-end drops must hand its parent an OWNED tail value, even in a
    // borrow (escape=false) position.  The block-end machinery evaluates the tail
    // FIRST (hoisted into __rc_scope_N), then runs the local drops, then yields
    // the hoisted value — so a tail that is (or, through control-flow arms,
    // yields) a BORROW of one of the dropped locals would dangle the moment the
    // drops run, and the parent (e.g. a while-condition's ring_unbox_bool) reads
    // freed memory.  Processing the tail in ESCAPE position Clone-wraps every
    // owner-bearing tail (rc_escape; control-flow tails inherit escape down to
    // their arm tails), so the hoisted value owns an independent reference that
    // survives the local drops.  ASan-proven hole this closes (pre-existing since
    // W2): `while match make(i) { some(p) => p.flag, none => false }` — the
    // materialised scrutinee `__anf = make(i)` is dropped at the cond-block end,
    // freeing the solely-owned payload whose `.flag` box the taken arm just
    // returned → heap-use-after-free in ring_unbox_bool.  Cost: in a true borrow
    // position the Clone'd tail dup has no consumer and leaks (bounded, one per
    // block evaluation, only when the block has droppable locals AND the tail is
    // owner-bearing) — crash-free direction, mirroring clone-all-escape's bias.
    // A no-drop block keeps borrow tails verbatim (zero churn, nothing freed).
    let tail_escape = if own_block_locals.len() > 0 { true } else { escape }

    // The tail sees every block-local (all `let`s precede the tail).
    let new_tail = match tail {
        some(t) => some(rc_escape_or_value(t, tail_escape, visible_owned, boxed, externs, gensym)),
        none => none,
    }
    if own_block_locals.len() == 0 {
        ((new_stmts, new_tail))
    } else if block_diverges(new_stmts, new_tail) {
        // Diverging block: a return/break/continue already handled cleanup; the
        // block-end drops are unreachable.  Do not emit them (would be dead code
        // / double-free on the diverging path).
        ((new_stmts, new_tail))
    } else {
        let drops = drops_for(own_block_locals)
        match new_tail {
            some(t) => {
                // Hoist the tail so the drops run AFTER it is evaluated.
                let tmp = fresh_scope_tmp(gensym)
                let tt = hexpr_type(t)
                let te = hexpr_effects(t)
                let ts = hexpr_span(t)
                new_stmts.push(HStmt::Let { name: tmp, name_span: synthetic_span(),
                    def_id: none, ty: tt, init: t, span: synthetic_span() })
                for d in drops { new_stmts.push(d) }
                let tmp_tail = HExpr::Ident { name: tmp, resolved_name: none, def_id: none,
                    dict_closure_dicts: none, ty: tt, effects: te, span: ts }
                ((new_stmts, some(tmp_tail)))
            },
            none => {
                // No tail value: drops simply run at block end.
                for d in drops { new_stmts.push(d) }
                ((new_stmts, none))
            },
        }
    }
}

// Dispatch an expression that is itself the tail/value of a block or branch.
// In escape position, owner-bearing exprs clone; in value position they borrow.
fn rc_escape_or_value(expr: HExpr, escape: Bool, owned: List<Str>, boxed: Set<Int>, externs: Set<Str>, mut gensym: List<Int>) -> HExpr {
    if escape {
        rc_escape(expr, owned, boxed, externs, gensym)
    } else {
        rc_expr(expr, false, owned, boxed, externs, gensym)
    }
}

// Fresh hoist-temp name generator.  `gensym` is a single-element mutable List
// cell threaded through the pass (Ring has no module-level mutable global); the
// counter is monotonic for one compilation and identical across runs of the same
// source, so double-bootstrap byte-equivalence is preserved.  The reserved
// `__rc_scope_` prefix never collides with a user binding.
fn fresh_scope_tmp(mut gensym: List<Int>) -> Str {
    let n = match gensym.get(0) { some(v) => v, none => 0 }
    gensym.set(0, n + 1)
    "__rc_scope_${n + 1}"
}

// Direct (non-nested) OWNED-AND-DROPPABLE bindings introduced by a statement
// list.  A `let`/`var` is scope-end-dropped only when its initialiser is
// GUARANTEED to be a fresh, unshared owned value:
//   * a fresh constructor (struct / variant / list / tuple / range / lambda /
//     literal / string-interp) — allocates a new object this scope solely owns; or
//   * an owner-bearing read (Ident / field / index / .unwrap…) — rc_escape wraps
//     it in a fresh Clone, which this scope solely owns.
// A Call / EffectOp result is NOT dropped: a callee may legitimately return a
// value that SHARES substructure with caller-visible state (the compiler's HIR /
// inference graphs are DAGs, not trees — e.g. an inference helper returning an
// InferResult whose `.subst` aliases the threaded UnionFind, or pass-through HIR
// nodes), so a scope-end drop of such a binding would free still-live shared
// state (observed as native self-compile UAF, B-098 GATE 1).  Leaking these
// bindings is crash-free and still far below always-own (reads no longer dup);
// tightening them to precise ownership is L3 reuse / B-096 scope.  Other binders
// (LetDestructure / for-in / match-if-let patterns) project BORROWS and are never
// dropped (handled by their exclusion from `owned`).
fn direct_block_locals(stmts: List<HStmt>, externs: Set<Str>) -> List<Str> {
    let mut out: List<Str> = []
    for s in stmts {
        for n in stmt_droppable_locals(s, externs) {
            if out.contains(n) == false { out.push(n) }
        }
    }
    out
}

// The droppable owned local(s) a SINGLE statement introduces (0 or 1).  Same
// classification as direct_block_locals, factored out so rc_block_inner can grow
// the visible-owned set incrementally (a binding is only droppable from its `let`
// onward — see rc_block_inner).
fn stmt_droppable_locals(s: HStmt, externs: Set<Str>) -> List<Str> {
    match s {
        HStmt::Let { name, init, .. } => {
            // B-102 R-clean: Type-DAG bindings participate in normal RC — a
            // droppable Type binding is scope-end-dropped (recursive drop_T), and
            // its owner-bearing init was Clone-wrapped at the escape site, so the
            // drop releases the binding's own (dup'd) reference.  (A1's
            // is_type_dag_type suppression is removed.)
            if rc_name_skippable(name) == false && is_droppable_init(init, externs) { [name] } else { [] }
        },
        HStmt::Var { name, init, .. } => {
            if rc_name_skippable(name) == false && is_droppable_init(init, externs) { [name] } else { [] }
        },
        _ => [],
    }
}

// Whether a `let`/`var` initialiser yields a fresh, solely-owned value safe to
// scope-end-drop (see direct_block_locals).  Classified on the ORIGINAL (pre-
// rc_escape) init, since rc_escape is a pure function of it: an owner-bearing
// init becomes a fresh Clone (droppable); a fresh constructor stays itself
// (droppable); a Call/EffectOp result may alias shared state (NOT droppable);
// Block/If/Match are conservatively NOT droppable (their value may be a Call
// result on some path).
fn is_droppable_init(init: HExpr, externs: Set<Str>) -> Bool {
    // B-104 D1 rule ② (Unit) + rule ① (extern, audit #139), both TYPE-level:
    //   ② a Unit-typed binding is never dropped: Unit has no value semantics
    //     (checker-guaranteed), and at the LLVM ABI a Unit-typed builtin call
    //     may accidentally return a live pointer — the receiver-returning
    //     mutators (`let x = xs.push(v)` → result IS the caller's container,
    //     `return list;`), so dropping it would free a live container → UAF.
    //     This TYPE-level rule replaces the B-103 name-grain listing of the 9
    //     mutator field names in is_borrow_returning_call (push/set/insert/
    //     remove/add/clear/extend/line/add_int — all declared `-> Unit` in std,
    //     verified per declaration), eliminating its leak-side cost: a USER
    //     method that shares a listed name but returns a real value is no
    //     longer Clone-wrapped (its result now moves + drops normally), and a
    //     fn-tail mutator result no longer dup-pins the receiver.
    //   ① a binding whose type IS an extern handle (`let b =
    //     LLVMCreateBuilder(...)`) must never be scope-end-dropped — ring_drop
    //     on a raw foreign pointer reads a garbage header / frees foreign
    //     memory.  A binding whose type transitively CONTAINS an extern handle
    //     (`let saved = ctx.current_fn` : LLVMValueRef?, `let pts:
    //     List<LLVMTypeRef> = []`, a struct with handle fields) must not be
    //     dropped either: its DEEP drop (drop_option / drop_list / drop_T field
    //     recursion at the runtime level) would reach the foreign pointer.
    //     Both leak instead — crash-free direction; foreign handles are owned
    //     by the foreign API (LLVMContextDispose et al.), not by Ring RC.
    let ty = hexpr_type(init)
    if is_rc_excluded_type(ty, externs) {
        return false
    }
    if type_contains_extern_handle(ty, externs) {
        return false
    }
    // B-104 D1 Stage 2 — UNKNOWN-OWNERSHIP guard (audit #149, mirrors
    // anf_should_materialize): a binding whose type is an unresolved TypeVar is
    // never scope-end-dropped.  The #149 checker hole over-generalises an
    // unannotated fn's return to a free var, so `let r = tp(a)` (where tp's
    // body tail is a receiver-returning Unit builtin, moved verbatim un-dup'd)
    // binds the LIVE container typed as a TypeVar — dropping r double-frees it
    // (ASan-proven on the pre-guard compiler).  Leak direction; concrete
    // (zonked) types are unaffected.
    if is_unresolved_var_type(ty) {
        return false
    }
    match init {
        // Owner-bearing reads → rc_escape wraps in a fresh Clone.
        //
        // B-101 element-read-projection UAF audit: a `let x = list[i]` / `let x =
        // m[k]` / `let x = obj.field` binds an element/field READ.  The runtime read
        // (ring_list_get / ring_map_get / struct-GEP) returns a BORROW (no dup —
        // B-098).  Naively scope-end-dropping x would free the container's element
        // → UAF.  But these are owner-bearing, so rc_stmt's rc_escape wraps the init
        // in HExpr::Clone (gen_clone → ring_dup): the binding then owns an
        // INDEPENDENT dup'd reference, NOT the container's element.  The scope-end
        // Drop releases that dup (rc N+1 → N); the container's own reference (and its
        // later element drop) is untouched.  Balanced — NO UAF, NO leak.  (This is
        // why is_droppable_init and is_owner_bearing agree on these arms: every
        // droppable-as-owner-bearing init is Clone-wrapped before it is dropped.)
        //
        // B-104 D1 rule ③: a Str-receiver IndexExpr (`let c = s[i]`) is droppable
        // on the OTHER ground — it is a FRESH 1-char string (ring_str_get
        // allocates; not owner-bearing, so rc_escape MOVES it into the binding),
        // released by the same scope-end Drop.  Both IndexExpr cases are
        // droppable; they differ only in whether the init was Clone-wrapped.
        HExpr::Ident { .. } => true,
        HExpr::FieldAccess { .. } => true,
        HExpr::IndexExpr { .. } => true,
        // Fresh constructors / literals → newly allocated, solely owned.
        HExpr::StructLit { .. } => true,
        HExpr::NamedVariantConstruct { .. } => true,
        HExpr::ListLit { .. } => true,
        HExpr::TupleLit { .. } => true,
        HExpr::RangeExpr { .. } => true,
        HExpr::Lambda { .. } => true,
        HExpr::StringInterp { .. } => true,
        HExpr::IntLit { .. } => true,
        HExpr::FloatLit { .. } => true,
        HExpr::StrLit { .. } => true,
        HExpr::BoolLit { .. } => true,
        HExpr::Clone { .. } => true,
        // B-103: every Call result is droppable.  Two sub-cases, both safe:
        //   (a) BORROW-returning call (.unwrap / .unwrap_or / .unwrap_or_else /
        //       .to_fail, per is_borrow_returning_call): is_owner_bearing(Call) is
        //       also true, so rc_stmt's rc_escape wraps the init in HExpr::Clone
        //       (ring_dup) — the binding owns a fresh dup, and the scope-end Drop
        //       releases that dup, NOT the borrowed source.  Balanced.
        //   (b) OWNED-returning call (apply_subst & the 167-site substitution flood,
        //       map_new, list_clone, .get/.first/.last/.values/.entries, string
        //       ops, ctor calls, …): the result is a fresh, solely-owned value moved
        //       into the binding; the scope-end Drop releases it (rc N→N-1).  This is
        //       what finally RECLAIMS the apply_subst transients (G-a memory gate).
        // PRE-CONDITION: the borrow-leaf classification in is_borrow_returning_call
        // (+ the owned-container-constructor dups in ring_runtime.cpp: list_first/
        // last, map_int_values/entries — B-103) must be COMPLETE, else a missed
        // borrow leaf would be scope-end-dropped → UAF.  ASan (real_program ×3 +
        // self-compile) is the completeness safety net: an over-free pinpoints the
        // missed leaf, which is then added to is_borrow_returning_call.
        HExpr::Call { .. } => true,
        // B-104: arithmetic/comparison BinOp + UnaryOp results are FRESH owned
        // (builtin arith/compare/negate box a new value via box_int/box_bool/
        // box_float; user operator overloads lower to Call, covered above) — never a
        // borrow, so safe to scope-end-drop.  Reclaims the boxed Int/Bool arithmetic
        // flood (diag: tid=0 INT 86M + tid=2 BOOL 43M live).
        //
        // EXCEPTION — `&&` / `||` (BinOp::And / Or) are NOT fresh: gen_and/gen_or
        // emit a phi whose short-circuit-taken edge is the RHS operand VERBATIM
        // (`a && b` yields b's own box when a is true).  That box may be a BORROW
        // (e.g. a `let x = a && obj.is_mutable` binding aliases obj.is_mutable on the
        // taken path), so scope-end-dropping such a binding would over-free a value
        // owned elsewhere → UAF.  Conservatively NOT droppable (leak, crash-free) —
        // mirrors anf_should_materialize's And/Or exclusion.
        HExpr::BinOp { op, .. } => match op { BinOp::And => false, BinOp::Or => false, _ => true },
        HExpr::UnaryOp { .. } => true,
        // B-104 W3a: control-flow value (If / Match / Block) is droppable IFF every
        // value-producing branch yields a droppable owned value.  Each branch / arm /
        // block tail is in ESCAPE position (rc_block_root/rc_block_inner thread escape
        // down), so rc_escape already makes an owner-bearing tail (Ident / field /
        // borrow-call) a fresh Clone and a fresh tail (constructor / Call / arith) a
        // move — both OWNED.  So `let x = if/match/block` binds an owned value,
        // balanced by the scope-end Drop — same reasoning as the Call arm (B-103),
        // reclaiming the `let x = if c {…} else {…}` / `let x = match …` residual.
        //
        // ⚠️ BUT NOT a blanket true — branch values are MIXED-ownership.  A branch
        // whose tail is `&&` / `||` (BinOp And/Or) yields the RHS box VERBATIM, which
        // may be a BORROW (`if c { a && obj.field } else { d }` → obj.field on the
        // taken edge); rc_escape MOVES it (And/Or ∉ is_owner_bearing) rather than
        // Cloning, so scope-end-dropping x would over-free obj.field → UAF.  Likewise
        // an EffectOp / TryCatch / HandleExpr tail can alias.  So we RECURSE: the
        // control-flow value is droppable only if each non-diverging branch tail is
        // itself is_droppable_init (And/Or tail → false → whole node not dropped).  A
        // DIVERGING branch (return/break/continue) yields no value to the binding, so
        // it never constrains droppability.  (This IS the "branch-value analysis"; it
        // bottoms out on the same per-expr classification, recursively.)
        HExpr::IfExpr { then_branch, else_branch, .. } => {
            match else_branch {
                // No else → the if is statement-typed (Unit value), not a fresh owned
                // value worth dropping; conservatively not droppable.
                none => false,
                some(eb) => is_droppable_branch_value(then_branch, externs) && is_droppable_branch_value(eb, externs),
            }
        },
        HExpr::MatchExpr { arms, .. } => {
            let mut all = arms.len() > 0
            for arm in arms {
                if is_droppable_branch_value(arm.body, externs) == false { all = false }
            }
            all
        },
        HExpr::Block { tail, .. } => {
            match tail { some(t) => is_droppable_init(t, externs), none => false }
        },
        // EffectOp / HandleExpr / TryCatch: value may alias resumed/handler state or
        // sit on an abort path (B-002) — conservatively NOT dropped (leak, crash-free).
        _ => false,
    }
}

// Whether a branch / arm body (a Block, or a bare single-expr body) yields a
// DROPPABLE owned value.  A diverging branch (return/break/continue) yields no
// value to the enclosing binding, so it never vetoes droppability.  Otherwise the
// branch value is its tail expression, classified by is_droppable_init (recursing
// through nested control flow; an And/Or or EffectOp tail → not droppable).
fn is_droppable_branch_value(body: HExpr, externs: Set<Str>) -> Bool {
    if expr_diverges(body) {
        true
    } else {
        match body {
            HExpr::Block { tail, .. } => match tail { some(t) => is_droppable_init(t, externs), none => false },
            _ => is_droppable_init(body, externs),
        }
    }
}

// Build a Drop stmt list for a name list (skipping `_`), in the given order.
fn drops_for(names: List<Str>) -> List<HStmt> {
    let mut out: List<HStmt> = []
    for n in names {
        if rc_name_skippable(n) == false {
            out.push(HStmt::Drop { name: n, ty: Type::UnitType, span: synthetic_span() })
        }
    }
    out
}

// Whether a transformed statement list + tail diverges (ends in return/break/
// continue on every path), so block-end drops would be unreachable.
fn block_diverges(stmts: List<HStmt>, tail: HExpr?) -> Bool {
    let mut any = false
    for s in stmts { if stmt_diverges(s) { any = true } }
    if any { return true }
    match tail {
        some(t) => expr_diverges(t),
        none => false,
    }
}

// B-104 W4 — scalar mut-var reassignment: classify whether an Assign target is a
// plain (non-auto-boxed) mut variable holding a SCALAR (Int/Bool/Float).  Such a
// reassignment leaks the old boxed scalar today (L0/L1 convention: the old value is
// overwritten and never dropped — the diagnosed INT① mut-counter leak, `i = i + 1`).
//
// Dropping the old box on reassignment is SOUND only for scalars: they have value
// semantics with NO interior aliasing, and at the Assign statement no transient
// borrow of the variable is live (scalar borrows do not span statements; every
// cross-statement holder dup'd the box via clone-all-escape's escape→Clone).  So the
// old box is either rc=1 (freed — the leak we reclaim) or rc>1 (decremented, sharers
// stay valid).  ring_box_int allocates fresh (no interning) and INT/BOOL/FLOAT are
// not never-drop, so the drop is real and safe.  Returns the binding name to drop
// (the source `name` — codegen keys named_values and the scope-end drops by it, and
// emit_assign's store resolves to the same alloca via its `name` fallback), or none.
//
// Excluded (out of W4 scope, conservatively left to leak):
//   - auto-boxed mut cells (def_id ∈ boxed, B-091): the write stores into cell.value
//     and the alloca holds the SHARED cell pointer — dropping it would free the cell
//     other holders still reference.
//   - non-scalar lvalues (struct/list/string/Option, FieldAccess/IndexExpr targets):
//     interior borrows may alias the old value; needs stronger analysis (later wave).
fn scalar_reassign_drop_name(target: HExpr, boxed: Set<Int>) -> Str? {
    match target {
        HExpr::Ident { name, def_id, ty, .. } => {
            let not_boxed = match def_id {
                some(did) => boxed.contains(did) == false,
                none => true,
            }
            if not_boxed && is_scalar_type(ty) {
                some(name)
            } else {
                none
            }
        },
        _ => none,
    }
}

fn is_scalar_type(ty: Type) -> Bool {
    match ty {
        Type::IntType => true,
        Type::FloatType => true,
        Type::BoolType => true,
        _ => false,
    }
}

// ============================================================
// Statement transform
// ============================================================

fn rc_stmt(stmt: HStmt, owned: List<Str>, boxed: Set<Int>, externs: Set<Str>, mut gensym: List<Int>) -> List<HStmt> {
    match stmt {
        HStmt::Let { name, name_span, def_id, ty, init, span } => {
            // The binding takes ownership of its initialiser → escape position.
            let new_init = rc_escape(init, owned, boxed, externs, gensym)
            [HStmt::Let { name: name, name_span: name_span, def_id: def_id, ty: ty, init: new_init, span: span }]
        },
        HStmt::Var { name, name_span, def_id, ty, init, span } => {
            let new_init = rc_escape(init, owned, boxed, externs, gensym)
            [HStmt::Var { name: name, name_span: name_span, def_id: def_id, ty: ty, init: new_init, span: span }]
        },
        HStmt::Assign { target, value, span } => {
            // The R-value escapes into the assigned location (it takes ownership).
            // The L-value (target) is a write destination — not rc-transformed.
            let new_value = rc_escape(value, owned, boxed, externs, gensym)
            // B-104 W4: a plain mut var holding a SCALAR (Int/Bool/Float) — drop the
            // old boxed scalar before overwriting (reclaims the INT① mut-counter leak,
            // `i = i + 1`).  Order is critical: materialise the (already-escaped) RHS
            // FIRST — it may read the old target (`x = x + 1`) — THEN drop the old
            // value, THEN store the temp.  Dropping first would UAF the RHS read.
            // Non-scalar / auto-boxed targets keep the leak-on-overwrite behaviour
            // (see scalar_reassign_drop_name for the soundness argument).
            match scalar_reassign_drop_name(target, boxed) {
                some(dname) => {
                    let tmp = fresh_scope_tmp(gensym)
                    let vt = hexpr_type(value)
                    let tmp_id = HExpr::Ident {
                        name: tmp, resolved_name: none, def_id: none,
                        dict_closure_dicts: none, ty: vt,
                        effects: hexpr_effects(value), span: hexpr_span(value)
                    }
                    [
                        HStmt::Let { name: tmp, name_span: synthetic_span(), def_id: none,
                            ty: vt, init: new_value, span: synthetic_span() },
                        HStmt::Drop { name: dname, ty: Type::UnitType, span: synthetic_span() },
                        HStmt::Assign { target: target, value: tmp_id, span: span },
                    ]
                },
                none => [HStmt::Assign { target: target, value: new_value, span: span }],
            }
        },
        HStmt::ExprStmt { expr, span } => {
            // Statement position: the value is discarded (borrow / fresh-temp that
            // leaks if unowned — acceptable; usually a Unit-returning call).
            let new_expr = rc_expr(expr, false, owned, boxed, externs, gensym)
            [HStmt::ExprStmt { expr: new_expr, span: span }]
        },
        HStmt::Return { value, span } => {
            match value {
                some(v) => {
                    // Clone the returned value if owner-bearing (the caller takes
                    // ownership; the source local is then dropped below), then drop
                    // every owned local in scope.  Order matters: the Clone bumps
                    // the rc, so the subsequent drops leave the returned object with
                    // the caller's reference.  Diverges → block-end drops unreachable.
                    let new_v = rc_escape(v, owned, boxed, externs, gensym)
                    let mut out: List<HStmt> = []
                    // Hoist the (cloned) return value so the drops run AFTER it.
                    let tmp = fresh_scope_tmp(gensym)
                    let tt = hexpr_type(v)
                    let te = hexpr_effects(v)
                    let ts = hexpr_span(v)
                    out.push(HStmt::Let { name: tmp, name_span: synthetic_span(),
                        def_id: none, ty: tt, init: new_v, span: synthetic_span() })
                    for d in drops_for(owned) { out.push(d) }
                    let tmp_id = HExpr::Ident { name: tmp, resolved_name: none, def_id: none,
                        dict_closure_dicts: none, ty: tt, effects: te, span: ts }
                    out.push(HStmt::Return { value: some(tmp_id), span: span })
                    out
                },
                none => {
                    // void return — drop all owned locals in scope.
                    let mut out: List<HStmt> = []
                    for d in drops_for(owned) { out.push(d) }
                    out.push(HStmt::Return { value: none, span: span })
                    out
                },
            }
        },
        HStmt::While { condition, body, span } => {
            // Condition is a borrow (boolean test).  The body is its own scope: its
            // bindings drop per-iteration at the body's block end.  No loop-carried
            // dup is needed — reads borrow, escapes clone, so the loop neither
            // consumes nor leaks outer locals (this is what kills the #134
            // conditional-loop double-free at the root).
            let new_cond = rc_expr(condition, false, owned, boxed, externs, gensym)
            let new_body = rc_block_root(body, false, owned, boxed, externs, gensym)
            [HStmt::While { condition: new_cond, body: new_body, span: span }]
        },
        HStmt::ForIn { binding, binding_span, def_id, destructure, iterable, body, iterable_type_name, iter_type_name, span } => {
            // The iterable is read once (borrow).  The for-binding (and any
            // destructure names) alias a BORROWED container element each iteration
            // (codegen's ring_list_get no longer dups — B-098 read-borrow), so they
            // are NOT owned and must NOT be scope-end-dropped (dropping would free
            // the container's element → UAF / double-free with the container drop).
            // If a loop value escapes, rc_escape clones it like any other borrow.
            let new_iter = rc_expr(iterable, false, owned, boxed, externs, gensym)
            let new_body = rc_block_root(body, false, owned, boxed, externs, gensym)
            [HStmt::ForIn {
                binding: binding, binding_span: binding_span, def_id: def_id,
                destructure: destructure, iterable: new_iter,
                body: new_body, iterable_type_name: iterable_type_name,
                iter_type_name: iter_type_name, span: span
            }]
        },
        HStmt::Break { span } => [HStmt::Break { span: span }],
        HStmt::Continue { span } => [HStmt::Continue { span: span }],
        HStmt::LetDestructure { pattern, bindings, init, span } => {
            // B-104 D1 Stage 2: the destructure does NOT take ownership of the
            // init — codegen (emit_let_destructure) PROJECTS each element via
            // ring_list_get (a borrow load, no dup) into the binding allocas,
            // and the bindings are excluded from the owned set (never dropped).
            // So the init is a BORROW read, not an escape.  The previous
            // rc_escape here Clone-wrapped an owner-bearing init (`let (a, b) =
            // pair`), producing an anonymous dup nobody dropped — a refcount
            // pin that leaked the tuple on every destructure of a named value.
            // Fresh inits are materialised by the ANF pass (`let __anf = f();
            // let (a, b) = __anf`) so the borrow source is an owned, scope-end-
            // dropped binding; binding escapes are Clone-wrapped as usual
            // (dup-before-drop balance, same as the W2 scrutinee).
            let new_init = rc_expr(init, false, owned, boxed, externs, gensym)
            [HStmt::LetDestructure { pattern: pattern, bindings: bindings, init: new_init, span: span }]
        },
        HStmt::IfLet { pattern, expr, then_block, else_block, span } => {
            // Scrutinee is a borrow.  Pattern bindings PROJECT borrows from the
            // scrutinee (codegen loads them without a dup), so they are NOT owned
            // and are excluded from the branch's owned set — no scope-end drop, no
            // double-free with the scrutinee.  No branch balancing.
            let new_expr = rc_expr(expr, false, owned, boxed, externs, gensym)
            let new_then = rc_block_root(then_block, false, owned, boxed, externs, gensym)
            let new_else = match else_block {
                some(eb) => some(rc_block_root(eb, false, owned, boxed, externs, gensym)),
                none => none,
            }
            [HStmt::IfLet { pattern: pattern, expr: new_expr, then_block: new_then, else_block: new_else, span: span }]
        },
        // Drop / Dup are inserted by this pass; pass through if seen (idempotent).
        HStmt::Drop { .. } => [stmt],
        HStmt::Dup { .. } => [stmt],
    }
}

// ============================================================
// Expression transform
//   escape = whether THIS expression's value escapes into an owned slot.
//   owned  = owned local bindings in scope (for nested return drops).
// ============================================================

fn rc_expr(expr: HExpr, escape: Bool, owned: List<Str>, boxed: Set<Int>, externs: Set<Str>, mut gensym: List<Int>) -> HExpr {
    match expr {
        // Leaves: nothing to transform.  Owner-bearing leaves (Ident) are cloned
        // by rc_escape at the escape site, never here (here = value position).
        HExpr::Ident { .. } => expr,
        HExpr::IntLit { .. } => expr,
        HExpr::FloatLit { .. } => expr,
        HExpr::StrLit { .. } => expr,
        HExpr::BoolLit { .. } => expr,

        HExpr::BinOp { op, left, right, eq_dispatch, ord_dispatch, ty, effects, span } => {
            // Operands are borrows (read for the operation; comparison/arith does
            // not take ownership).
            HExpr::BinOp { op: op, left: rc_expr(left, false, owned, boxed, externs, gensym),
                right: rc_expr(right, false, owned, boxed, externs, gensym),
                eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
                ty: ty, effects: effects, span: span }
        },

        HExpr::UnaryOp { op, operand, ty, effects, span } => {
            HExpr::UnaryOp { op: op, operand: rc_expr(operand, false, owned, boxed, externs, gensym),
                ty: ty, effects: effects, span: span }
        },

        HExpr::Call { callee, args, type_args, resolved_dicts, dict_dispatch, ty, effects, span } => {
            // Callee is a borrow.  Arguments BORROW by default (the callee does not
            // drop them — point 4) EXCEPT two ownership-taking sinks:
            //   1. a known container-sink (push/insert/set): the value escapes into
            //      the container (it must co-own with the container);
            //   2. an ENUM VARIANT CONSTRUCTOR call (`some(x)` / `ok(v)` / `err(e)` /
            //      a user `Variant(payload)` written in call syntax): the runtime
            //      constructor (`ring_enum_some` / `gen_named_variant_construct`)
            //      STORES the argument pointer WITHOUT a dup, exactly like a
            //      StructLit/NamedVariantConstruct field store.  So every value arg
            //      escapes and must be Clone'd if owner-bearing — otherwise the
            //      argument's own scope-end drop frees the payload the new enum holds
            //      (the native prelude `match find_std_dir() { some(std_dir) => … }`
            //      UAF, B-101).  The literal-syntax forms already escape their fields
            //      (StructLit / NamedVariantConstruct arms below); this closes the
            //      call-syntax gap so both lower identically.
            let new_callee = rc_expr(callee, false, owned, boxed, externs, gensym)
            let ctor_sink = is_variant_constructor_call(callee, ty)
            let sink = sink_arg_indices(callee, args.len())
            let mut new_args: List<HExpr> = []
            let mut i = 0
            for a in args {
                let new_a = if ctor_sink || list_contains_int(sink, i) {
                    rc_escape(a, owned, boxed, externs, gensym)
                } else {
                    rc_expr(a, false, owned, boxed, externs, gensym)
                }
                new_args.push(new_a)
                i = i + 1
            }
            HExpr::Call { callee: new_callee, args: new_args, type_args: type_args,
                resolved_dicts: resolved_dicts, dict_dispatch: dict_dispatch,
                ty: ty, effects: effects, span: span }
        },

        HExpr::FieldAccess { receiver, field, ty, effects, span } => {
            // Read: receiver is a borrow.  (If this field access itself escapes,
            // rc_escape wraps the whole node in Clone before we get here in value
            // position — so here the result is just a borrow.)
            HExpr::FieldAccess { receiver: rc_expr(receiver, false, owned, boxed, externs, gensym),
                field: field, ty: ty, effects: effects, span: span }
        },

        HExpr::StructLit { name, type_args, fields, spread, ty, effects, span } => {
            // Each field value escapes into the new struct (the struct owns it).
            let mut new_fields: List<HStructFieldInit> = []
            for f in fields {
                new_fields.push(HStructFieldInit { name: f.name, value: rc_escape(f.value, owned, boxed, externs, gensym) })
            }
            // Spread copies the source struct's field pointers into the new struct
            // (codegen does a raw field-pointer copy without dup), so the spread
            // source is read as a borrow here; correctness of spread + RC is an
            // existing-scope concern (leak-on-spread acceptable at L1).
            let new_spread = match spread {
                some(s) => some(rc_expr(s, false, owned, boxed, externs, gensym)),
                none => none,
            }
            HExpr::StructLit { name: name, type_args: type_args, fields: new_fields,
                spread: new_spread, ty: ty, effects: effects, span: span }
        },

        HExpr::NamedVariantConstruct { enum_name, variant_name, fields, spread, ty, effects, span } => {
            let mut new_fields: List<HStructFieldInit> = []
            for f in fields {
                new_fields.push(HStructFieldInit { name: f.name, value: rc_escape(f.value, owned, boxed, externs, gensym) })
            }
            let new_spread = match spread {
                some(s) => some(rc_expr(s, false, owned, boxed, externs, gensym)),
                none => none,
            }
            HExpr::NamedVariantConstruct { enum_name: enum_name, variant_name: variant_name,
                fields: new_fields, spread: new_spread, ty: ty, effects: effects, span: span }
        },

        HExpr::Block { stmts, tail, ty, effects, span } => {
            // A nested block: it owns its own bindings (dropped at its block end)
            // and its value carries this expression's escape position.
            let res = rc_block_inner(stmts, tail, escape, owned, boxed, externs, gensym)
            HExpr::Block { stmts: res.0, tail: res.1, ty: ty, effects: effects, span: span }
        },

        HExpr::IfExpr { condition, then_branch, else_branch, ty, effects, span } => {
            // Condition borrows.  Branches inherit this expression's escape
            // position; each branch is its own scope (block-end drops its locals).
            // No branch balancing: outer locals are only read (borrow) in branches,
            // so they drop once at the OUTER block end regardless of branch taken.
            let new_cond = rc_expr(condition, false, owned, boxed, externs, gensym)
            let new_then = rc_block_root(then_branch, escape, owned, boxed, externs, gensym)
            let new_else = match else_branch {
                some(eb) => some(rc_block_root(eb, escape, owned, boxed, externs, gensym)),
                none => none,
            }
            HExpr::IfExpr { condition: new_cond, then_branch: new_then,
                else_branch: new_else, ty: ty, effects: effects, span: span }
        },

        HExpr::MatchExpr { scrutinee, arms, ty, effects, span } => {
            // Scrutinee borrows.  Each arm body inherits escape.  Arm pattern
            // bindings PROJECT borrows from the scrutinee (loaded without a dup),
            // so they are NOT owned — excluded from the arm's owned set (no
            // scope-end drop, no double-free with the scrutinee).  No balancing:
            // outer owned locals are only read in arms, dropping once at the
            // OUTER block end regardless of which arm runs.
            let new_scrutinee = rc_expr(scrutinee, false, owned, boxed, externs, gensym)
            let mut new_arms: List<HMatchArm> = []
            for arm in arms {
                // Guard borrows (boolean test).
                let new_guard = match arm.guard {
                    some(g) => some(rc_expr(g, false, owned, boxed, externs, gensym)),
                    none => none,
                }
                let new_body = rc_block_root(arm.body, escape, owned, boxed, externs, gensym)
                new_arms.push(HMatchArm { pattern: arm.pattern, guard: new_guard, body: new_body, span: arm.span })
            }
            HExpr::MatchExpr { scrutinee: new_scrutinee, arms: new_arms, ty: ty, effects: effects, span: span }
        },

        HExpr::StringInterp { parts, ty, effects, span } => {
            // Interpolated parts are read (stringified) — borrows.
            let mut new_parts: List<HStringInterpPart> = []
            for p in parts {
                match p {
                    HStringInterpPart::Expression(e) =>
                        new_parts.push(HStringInterpPart::Expression(rc_expr(e, false, owned, boxed, externs, gensym))),
                    HStringInterpPart::Literal(s) =>
                        new_parts.push(HStringInterpPart::Literal(s)),
                }
            }
            HExpr::StringInterp { parts: new_parts, ty: ty, effects: effects, span: span }
        },

        HExpr::TryCatch { body, arms, ty, effects, span } => {
            // body + catch arms inherit escape; each is its own scope.  abort-path
            // RC (longjmp) is out of B-098 scope (B-002 drop-aware unwind); on the
            // normal path the body/arm blocks drop their own locals.
            let new_body = rc_block_root(body, escape, owned, boxed, externs, gensym)
            let mut new_arms: List<HMatchArm> = []
            for arm in arms {
                // catch-arm pattern bindings project borrows from the caught error
                // value — not owned, excluded from the arm's owned set.
                let new_body_arm = rc_block_root(arm.body, escape, owned, boxed, externs, gensym)
                new_arms.push(HMatchArm { pattern: arm.pattern, guard: arm.guard, body: new_body_arm, span: arm.span })
            }
            HExpr::TryCatch { body: new_body, arms: new_arms, ty: ty, effects: effects, span: span }
        },

        HExpr::HandleExpr { body, handlers, ty, effects, span } => {
            // body inherits escape.  Each handler arm becomes a closure at codegen
            // (gen_handle_expr → build_handler_evidence).  B-098 closure model:
            // captures are owned and DUP'd at construction by gen_lambda (not in
            // the body), so perceus only needs to transform the body in its own
            // scope.  The evidence struct + arm closures are intentionally leaked at
            // L0/L1 (B-096 收口), so the construction dup simply leaks with the env.
            let new_body = rc_block_root(body, escape, owned, boxed, externs, gensym)
            let mut new_handlers: List<HEffectHandler> = []
            for h in handlers {
                // Handler arm body is its own (closure) scope — no outer owned
                // locals are in scope inside (captures are accessed through the env,
                // not `owned`).  The arm body's value is the resume/abort value →
                // escape position.
                let h_body = rc_block_root(h.body, true, [], boxed, externs, gensym)
                new_handlers.push(HEffectHandler {
                    effect_name: h.effect_name, op_name: h.op_name,
                    params: h.params, resume_name: h.resume_name, body: h_body
                })
            }
            HExpr::HandleExpr { body: new_body, handlers: new_handlers, ty: ty, effects: effects, span: span }
        },

        HExpr::Lambda { params, return_type, body, ty, effects, span } => {
            // Conservative closure model (B-098 all-owned captures): every captured
            // outer owned local is DUP'd at CONSTRUCTION by gen_lambda (the env
            // takes its own reference), released when the env dies (B-084
            // drop_closure_env).  leak-free + crash-free: binding rc=1 → capture dup
            // → 2 → env drop → 1 → binding scope-end drop → 0.  Perceus therefore
            // does NOT touch captures here; it only transforms the lambda body in
            // its own fresh function scope (params borrow, tail = return = escape,
            // no enclosing owned locals — captures come through the env).
            let new_body = rc_block_root(body, true, [], boxed, externs, gensym)
            HExpr::Lambda { params: params, return_type: return_type, body: new_body,
                ty: ty, effects: effects, span: span }
        },

        HExpr::EffectOp { effect_name, op_name, args, ty, effects, span } => {
            // Effect-op args: treat like ordinary call args — borrow (the handler
            // closure receives them; full effect-arg ownership is B-096 scope).
            let mut new_args: List<HExpr> = []
            for a in args { new_args.push(rc_expr(a, false, owned, boxed, externs, gensym)) }
            HExpr::EffectOp { effect_name: effect_name, op_name: op_name, args: new_args,
                ty: ty, effects: effects, span: span }
        },

        HExpr::RangeExpr { start, end, inclusive, ty, effects, span } => {
            // Range stores start/end into a fresh range struct → they escape.
            HExpr::RangeExpr { start: rc_escape(start, owned, boxed, externs, gensym),
                end: rc_escape(end, owned, boxed, externs, gensym),
                inclusive: inclusive, ty: ty, effects: effects, span: span }
        },

        HExpr::ListLit { elements, ty, effects, span } => {
            // Each element escapes into the new list (the list owns it).
            let mut new_elems: List<HExpr> = []
            for e in elements { new_elems.push(rc_escape(e, owned, boxed, externs, gensym)) }
            HExpr::ListLit { elements: new_elems, ty: ty, effects: effects, span: span }
        },

        HExpr::TupleLit { elements, ty, effects, span } => {
            let mut new_elems: List<HExpr> = []
            for e in elements { new_elems.push(rc_escape(e, owned, boxed, externs, gensym)) }
            HExpr::TupleLit { elements: new_elems, ty: ty, effects: effects, span: span }
        },

        HExpr::IndexExpr { receiver, index, ty, effects, span } => {
            // Read: receiver + index are borrows.  (Escape wrapping of the whole
            // index result happens in rc_escape before reaching value position.)
            HExpr::IndexExpr { receiver: rc_expr(receiver, false, owned, boxed, externs, gensym),
                index: rc_expr(index, false, owned, boxed, externs, gensym),
                ty: ty, effects: effects, span: span }
        },

        // Clone should not appear in the input HIR (this pass inserts it); pass
        // through idempotently if seen.
        HExpr::Clone { .. } => expr,
    }
}

// ============================================================
// Container-sink argument detection
// ============================================================
//
// A method call whose VALUE argument escapes into the receiver container (the
// container takes co-ownership): list.push / .insert / .add / .set / map.set /
// .insert / set.add / .insert, string-builder .append etc.  Returns the arg
// indices (0-based, receiver excluded — args here are the non-self arguments)
// that are sink (owned) positions.  Anything not listed is a borrow.
fn sink_arg_indices(callee: HExpr, arg_count: Int) -> List<Int> {
    match callee {
        HExpr::FieldAccess { field, .. } => {
            if field == "push" || field == "add" || field == "append" || field == "push_back" {
                // single value argument at index 0
                if arg_count >= 1 { [0] } else { [] }
            } else if field == "insert" {
                // List.insert(idx, val) → value at 1; Set.insert(val) → value at 0;
                // Map has set/insert(key,val) → value at 1.  Conservatively mark
                // the LAST argument (the value) as the sink.
                if arg_count >= 1 { [arg_count - 1] } else { [] }
            } else if field == "set" {
                // List.set(idx, val) / Map.set(key, val) → value is last arg.
                if arg_count >= 1 { [arg_count - 1] } else { [] }
            } else {
                []
            }
        },
        _ => [],
    }
}

// Whether a Call is an enum VARIANT CONSTRUCTOR written in call syntax
// (`some(x)`, `ok(v)`, `err(e)`, or a user `Variant(payload)`).  Such a call
// lowers to `ring_enum_some` / a `gen_named_variant_construct`-style store that
// takes the argument BY OWNERSHIP without a dup — so its value args are escape
// (sink) positions, like StructLit / NamedVariantConstruct fields.
//
// Detection (no enum-registry access in perceus): the callee is a BARE Ident
// (not a method / FieldAccess) whose `resolved_name` is the variant's JS name
// `${Enum}_${variant}` (set by infer when the call name resolves through
// `variant_to_enum`), AND the call's result type is that EnumType.  Requiring
// resolved_name to start with the result enum's `${name}_` distinguishes a
// constructor from an ordinary function that merely returns an enum (whose
// callee resolved_name is its own mangled fn name, not `${Enum}_…`).
//
// Safety asymmetry (mirrors sink_arg_indices): a false POSITIVE only adds an
// extra Clone on an already-owned arg → a leak (crash-free); a false NEGATIVE
// (missing a real constructor) leaves the arg un-cloned → UAF.  The predicate
// therefore errs toward inclusion for enum-returning bare-Ident calls.
fn is_variant_constructor_call(callee: HExpr, result_ty: Type) -> Bool {
    match callee {
        HExpr::Ident { resolved_name, .. } => match resolved_name {
            some(rn) => match result_ty {
                Type::EnumType { name, .. } => rn.starts_with("${name}_"),
                _ => false,
            },
            none => false,
        },
        _ => false,
    }
}

fn list_contains_int(xs: List<Int>, x: Int) -> Bool {
    for v in xs { if v == x { return true } }
    false
}

// ============================================================
// Divergence analysis (#134, retained for B-098): a control path that
// unconditionally transfers away — return / break / continue — never reaches the
// enclosing block end.  Such a path is EXEMPT from scope-end drops: a `return`
// has already dropped the full owned set, and break/continue exit the iteration,
// so prepending block-end drops on the diverging path would be dead code (and on
// the return path would double-free what the return already released).
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
