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

use ast::{Span, Position, Pattern}
use hir::{HDecl, HStmt, HExpr, HParam, HProgram, HMatchArm,
    HStructFieldInit, HStringInterpPart, HEffectHandler,
    hexpr_type, hexpr_span, hexpr_effects, is_type_dag_type}
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
            // B-098: the const owns its value → the initialiser is in escape
            // position, with an empty enclosing owned scope (no locals at top level).
            let owned: List<Str> = []
            let mut gensym: List<Int> = [0]
            let new_init = rc_escape(init, owned, boxed, gensym)
            HDecl::Const { name: name, def_id: def_id, ty: ty, init: new_init, is_pub: is_pub, span: span }
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

fn transform_fn_body(params: List<HParam>, body: HExpr, boxed: Set<Int>) -> HExpr {
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
    rc_block_root(body, true, owned, boxed, gensym)
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
        HExpr::IndexExpr { .. } => true,
        HExpr::Call { callee, .. } => is_borrow_returning_call(callee),
        _ => false,
    }
}

// A method call whose result is a BORROW of (an inner reference of) its receiver,
// returned WITHOUT a dup by the runtime — so escaping it needs a Clone.  These
// are the extern Option projection accessors:
//   .unwrap / .to_fail / .unwrap_or_else  → return the Option payload (a borrow).
// NOTE: `.get()` is NOT here — list.get / map.get build a FRESH owned Option
// (ring_enum_some, which co-owns a dup'd element), so their result is a fresh
// temporary, not a borrow.  `.values()` / `.entries()` likewise build fresh owned
// Lists.  Ring-level accessors (.first / .last / .unwrap_or) get the Perceus
// transform on their own bodies, so their borrow-ness propagates automatically
// (their `return` goes through rc_escape) — only the extern ones are listed here.
//
// Safety asymmetry: mis-listing a fresh-temp call here only LEAKS (an extra dup
// whose source leaks); OMITTING a genuine borrow-returner CRASHES (UAF when the
// escaped borrow is scope-end-dropped).  So this list errs toward inclusion.
fn is_borrow_returning_call(callee: HExpr) -> Bool {
    match callee {
        HExpr::FieldAccess { field, .. } =>
            field == "unwrap" || field == "to_fail" || field == "unwrap_or_else",
        _ => false,
    }
}

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
// omitting → leak.  The real fix is NOT this whitelist but the Type-DAG ownership
// special case (B-101 方案 A, design §7.11): Type is INTERNED + NEVER DROPPED, so
// the substitution leak and the prelude over-free UAF are BOTH eliminated at the
// runtime/typeid level (ring_register_never_drop + is_type_dag_type below), with
// no per-call escape analysis at all.  Precise DAG-aware escape for the *other*
// shared returns (subst / UnionFind / pass-through HIR) stays B-096/L3.
// ─────────────────────────────────────────────────────────────────────────────

// Wrap an escaping expression: clone it iff it has an independent owner; the
// inner expression is processed in VALUE (borrow) position so its own reads do
// not clone.  Carries inner's type/effects/span on the Clone node.
fn rc_escape(expr: HExpr, owned: List<Str>, boxed: Set<Int>, mut gensym: List<Int>) -> HExpr {
    // B-101: a Type-DAG value is interned (never dup'd, never dropped) — escaping it
    // needs no Clone (the runtime no-ops ring_dup for its typeid).  Process in value
    // position so nested escapes are still handled; emit no Clone wrapper.
    if is_type_dag_type(hexpr_type(expr)) {
        rc_expr(expr, false, owned, boxed, gensym)
    } else if is_owner_bearing(expr) {
        let inner = rc_expr(expr, false, owned, boxed, gensym)
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
        rc_expr(expr, true, owned, boxed, gensym)
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

fn rc_block_root(body: HExpr, escape: Bool, owned: List<Str>, boxed: Set<Int>, mut gensym: List<Int>) -> HExpr {
    match body {
        HExpr::Block { stmts, tail, ty, effects, span } => {
            let res = rc_block_inner(stmts, tail, escape, owned, boxed, gensym)
            HExpr::Block { stmts: res.0, tail: res.1, ty: ty, effects: effects, span: span }
        },
        _ => {
            // Non-block body (single expression): it is the tail in escape (return)
            // position.  No block-local bindings to drop.
            rc_escape_or_value(body, escape, owned, boxed, gensym)
        },
    }
}

// Process a block's statement list + tail.  Returns (new_stmts, new_tail).
fn rc_block_inner(stmts: List<HStmt>, tail: HExpr?, escape: Bool, owned: List<Str>, boxed: Set<Int>, mut gensym: List<Int>) -> (List<HStmt>, HExpr?) {
    // Bindings defined directly by these statements (not nested loop/branch scopes).
    let block_locals = direct_block_locals(stmts)

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
        for ns in rc_stmt(s, visible_owned, boxed, gensym) { new_stmts.push(ns) }
        // After processing, this statement's own droppable binding (if any, and not
        // already owned by an enclosing scope) becomes visible to later statements.
        for n in stmt_droppable_locals(s) {
            if visible_owned.contains(n) == false { visible_owned.push(n) }
        }
    }

    // The tail sees every block-local (all `let`s precede the tail).
    let new_tail = match tail {
        some(t) => some(rc_escape_or_value(t, escape, visible_owned, boxed, gensym)),
        none => none,
    }

    // Scope-end drops for this block's OWN fresh bindings, on the fall-through path.
    // A block-local that shadows an enclosing owned name (same flat alloca) is NOT
    // re-dropped here — the enclosing scope owns that drop; re-dropping would free
    // the one shared alloca twice (B-102 layer-3 over-free).
    let mut own_block_locals: List<Str> = []
    for n in block_locals {
        if owned.contains(n) == false { own_block_locals.push(n) }
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
fn rc_escape_or_value(expr: HExpr, escape: Bool, owned: List<Str>, boxed: Set<Int>, mut gensym: List<Int>) -> HExpr {
    if escape {
        rc_escape(expr, owned, boxed, gensym)
    } else {
        rc_expr(expr, false, owned, boxed, gensym)
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
fn direct_block_locals(stmts: List<HStmt>) -> List<Str> {
    let mut out: List<Str> = []
    for s in stmts {
        for n in stmt_droppable_locals(s) {
            if out.contains(n) == false { out.push(n) }
        }
    }
    out
}

// The droppable owned local(s) a SINGLE statement introduces (0 or 1).  Same
// classification as direct_block_locals, factored out so rc_block_inner can grow
// the visible-owned set incrementally (a binding is only droppable from its `let`
// onward — see rc_block_inner).
fn stmt_droppable_locals(s: HStmt) -> List<Str> {
    match s {
        HStmt::Let { name, ty, init, .. } => {
            // B-101: Type-DAG bindings are interned / never-dropped (the runtime
            // marks their typeids never-drop; a Drop here would be a no-op anyway).
            // Suppressing the Drop keeps RC traffic off the immutable Type DAG.
            if rc_name_skippable(name) == false && is_type_dag_type(ty) == false && is_droppable_init(init) { [name] } else { [] }
        },
        HStmt::Var { name, ty, init, .. } => {
            if rc_name_skippable(name) == false && is_type_dag_type(ty) == false && is_droppable_init(init) { [name] } else { [] }
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
fn is_droppable_init(init: HExpr) -> Bool {
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
        // A borrow-returning method call (.unwrap…) becomes a Clone via rc_escape,
        // so its binding owns a fresh dup → droppable.  General Call results are NOT
        // dropped here (may alias shared state — see the B-101 DEAD ROAD note above:
        // the substitution-family leak is handled by Type interning, not a
        // call-level whitelist).
        HExpr::Call { callee, .. } =>
            is_borrow_returning_call(callee),
        // Call (general) / EffectOp / BinOp / UnaryOp / control-flow: may alias
        // shared state or be a non-owning scalar — conservatively not dropped.
        _ => false,
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

// ============================================================
// Statement transform
// ============================================================

fn rc_stmt(stmt: HStmt, owned: List<Str>, boxed: Set<Int>, mut gensym: List<Int>) -> List<HStmt> {
    match stmt {
        HStmt::Let { name, name_span, def_id, ty, init, span } => {
            // The binding takes ownership of its initialiser → escape position.
            let new_init = rc_escape(init, owned, boxed, gensym)
            [HStmt::Let { name: name, name_span: name_span, def_id: def_id, ty: ty, init: new_init, span: span }]
        },
        HStmt::Var { name, name_span, def_id, ty, init, span } => {
            let new_init = rc_escape(init, owned, boxed, gensym)
            [HStmt::Var { name: name, name_span: name_span, def_id: def_id, ty: ty, init: new_init, span: span }]
        },
        HStmt::Assign { target, value, span } => {
            // The R-value escapes into the assigned location (it takes ownership).
            // The L-value (target) is a write destination — not rc-transformed.
            // B-091: a write to an auto-boxed mut-cell stores into cell.value; the
            // old value is leaked (matching the field-assign convention), so we do
            // NOT drop the overwritten value here.  Reassigning a plain mut var
            // overwrites the alloca; the old value also leaks (L0/L1 convention),
            // avoiding the need to know whether the old reference is shared.
            let new_value = rc_escape(value, owned, boxed, gensym)
            [HStmt::Assign { target: target, value: new_value, span: span }]
        },
        HStmt::ExprStmt { expr, span } => {
            // Statement position: the value is discarded (borrow / fresh-temp that
            // leaks if unowned — acceptable; usually a Unit-returning call).
            let new_expr = rc_expr(expr, false, owned, boxed, gensym)
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
                    let new_v = rc_escape(v, owned, boxed, gensym)
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
            let new_cond = rc_expr(condition, false, owned, boxed, gensym)
            let new_body = rc_block_root(body, false, owned, boxed, gensym)
            [HStmt::While { condition: new_cond, body: new_body, span: span }]
        },
        HStmt::ForIn { binding, binding_span, def_id, destructure, iterable, body, iterable_type_name, iter_type_name, span } => {
            // The iterable is read once (borrow).  The for-binding (and any
            // destructure names) alias a BORROWED container element each iteration
            // (codegen's ring_list_get no longer dups — B-098 read-borrow), so they
            // are NOT owned and must NOT be scope-end-dropped (dropping would free
            // the container's element → UAF / double-free with the container drop).
            // If a loop value escapes, rc_escape clones it like any other borrow.
            let new_iter = rc_expr(iterable, false, owned, boxed, gensym)
            let new_body = rc_block_root(body, false, owned, boxed, gensym)
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
            // The destructure binds owned slots from the initialiser → escape.
            let new_init = rc_escape(init, owned, boxed, gensym)
            [HStmt::LetDestructure { pattern: pattern, bindings: bindings, init: new_init, span: span }]
        },
        HStmt::IfLet { pattern, expr, then_block, else_block, span } => {
            // Scrutinee is a borrow.  Pattern bindings PROJECT borrows from the
            // scrutinee (codegen loads them without a dup), so they are NOT owned
            // and are excluded from the branch's owned set — no scope-end drop, no
            // double-free with the scrutinee.  No branch balancing.
            let new_expr = rc_expr(expr, false, owned, boxed, gensym)
            let new_then = rc_block_root(then_block, false, owned, boxed, gensym)
            let new_else = match else_block {
                some(eb) => some(rc_block_root(eb, false, owned, boxed, gensym)),
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

fn rc_expr(expr: HExpr, escape: Bool, owned: List<Str>, boxed: Set<Int>, mut gensym: List<Int>) -> HExpr {
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
            HExpr::BinOp { op: op, left: rc_expr(left, false, owned, boxed, gensym),
                right: rc_expr(right, false, owned, boxed, gensym),
                eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
                ty: ty, effects: effects, span: span }
        },

        HExpr::UnaryOp { op, operand, ty, effects, span } => {
            HExpr::UnaryOp { op: op, operand: rc_expr(operand, false, owned, boxed, gensym),
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
            let new_callee = rc_expr(callee, false, owned, boxed, gensym)
            let ctor_sink = is_variant_constructor_call(callee, ty)
            let sink = sink_arg_indices(callee, args.len())
            let mut new_args: List<HExpr> = []
            let mut i = 0
            for a in args {
                let new_a = if ctor_sink || list_contains_int(sink, i) {
                    rc_escape(a, owned, boxed, gensym)
                } else {
                    rc_expr(a, false, owned, boxed, gensym)
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
            HExpr::FieldAccess { receiver: rc_expr(receiver, false, owned, boxed, gensym),
                field: field, ty: ty, effects: effects, span: span }
        },

        HExpr::StructLit { name, type_args, fields, spread, ty, effects, span } => {
            // Each field value escapes into the new struct (the struct owns it).
            let mut new_fields: List<HStructFieldInit> = []
            for f in fields {
                new_fields.push(HStructFieldInit { name: f.name, value: rc_escape(f.value, owned, boxed, gensym) })
            }
            // Spread copies the source struct's field pointers into the new struct
            // (codegen does a raw field-pointer copy without dup), so the spread
            // source is read as a borrow here; correctness of spread + RC is an
            // existing-scope concern (leak-on-spread acceptable at L1).
            let new_spread = match spread {
                some(s) => some(rc_expr(s, false, owned, boxed, gensym)),
                none => none,
            }
            HExpr::StructLit { name: name, type_args: type_args, fields: new_fields,
                spread: new_spread, ty: ty, effects: effects, span: span }
        },

        HExpr::NamedVariantConstruct { enum_name, variant_name, fields, spread, ty, effects, span } => {
            let mut new_fields: List<HStructFieldInit> = []
            for f in fields {
                new_fields.push(HStructFieldInit { name: f.name, value: rc_escape(f.value, owned, boxed, gensym) })
            }
            let new_spread = match spread {
                some(s) => some(rc_expr(s, false, owned, boxed, gensym)),
                none => none,
            }
            HExpr::NamedVariantConstruct { enum_name: enum_name, variant_name: variant_name,
                fields: new_fields, spread: new_spread, ty: ty, effects: effects, span: span }
        },

        HExpr::Block { stmts, tail, ty, effects, span } => {
            // A nested block: it owns its own bindings (dropped at its block end)
            // and its value carries this expression's escape position.
            let res = rc_block_inner(stmts, tail, escape, owned, boxed, gensym)
            HExpr::Block { stmts: res.0, tail: res.1, ty: ty, effects: effects, span: span }
        },

        HExpr::IfExpr { condition, then_branch, else_branch, ty, effects, span } => {
            // Condition borrows.  Branches inherit this expression's escape
            // position; each branch is its own scope (block-end drops its locals).
            // No branch balancing: outer locals are only read (borrow) in branches,
            // so they drop once at the OUTER block end regardless of branch taken.
            let new_cond = rc_expr(condition, false, owned, boxed, gensym)
            let new_then = rc_block_root(then_branch, escape, owned, boxed, gensym)
            let new_else = match else_branch {
                some(eb) => some(rc_block_root(eb, escape, owned, boxed, gensym)),
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
            let new_scrutinee = rc_expr(scrutinee, false, owned, boxed, gensym)
            let mut new_arms: List<HMatchArm> = []
            for arm in arms {
                // Guard borrows (boolean test).
                let new_guard = match arm.guard {
                    some(g) => some(rc_expr(g, false, owned, boxed, gensym)),
                    none => none,
                }
                let new_body = rc_block_root(arm.body, escape, owned, boxed, gensym)
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
                        new_parts.push(HStringInterpPart::Expression(rc_expr(e, false, owned, boxed, gensym))),
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
            let new_body = rc_block_root(body, escape, owned, boxed, gensym)
            let mut new_arms: List<HMatchArm> = []
            for arm in arms {
                // catch-arm pattern bindings project borrows from the caught error
                // value — not owned, excluded from the arm's owned set.
                let new_body_arm = rc_block_root(arm.body, escape, owned, boxed, gensym)
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
            let new_body = rc_block_root(body, escape, owned, boxed, gensym)
            let mut new_handlers: List<HEffectHandler> = []
            for h in handlers {
                // Handler arm body is its own (closure) scope — no outer owned
                // locals are in scope inside (captures are accessed through the env,
                // not `owned`).  The arm body's value is the resume/abort value →
                // escape position.
                let h_body = rc_block_root(h.body, true, [], boxed, gensym)
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
            let new_body = rc_block_root(body, true, [], boxed, gensym)
            HExpr::Lambda { params: params, return_type: return_type, body: new_body,
                ty: ty, effects: effects, span: span }
        },

        HExpr::EffectOp { effect_name, op_name, args, ty, effects, span } => {
            // Effect-op args: treat like ordinary call args — borrow (the handler
            // closure receives them; full effect-arg ownership is B-096 scope).
            let mut new_args: List<HExpr> = []
            for a in args { new_args.push(rc_expr(a, false, owned, boxed, gensym)) }
            HExpr::EffectOp { effect_name: effect_name, op_name: op_name, args: new_args,
                ty: ty, effects: effects, span: span }
        },

        HExpr::RangeExpr { start, end, inclusive, ty, effects, span } => {
            // Range stores start/end into a fresh range struct → they escape.
            HExpr::RangeExpr { start: rc_escape(start, owned, boxed, gensym),
                end: rc_escape(end, owned, boxed, gensym),
                inclusive: inclusive, ty: ty, effects: effects, span: span }
        },

        HExpr::ListLit { elements, ty, effects, span } => {
            // Each element escapes into the new list (the list owns it).
            let mut new_elems: List<HExpr> = []
            for e in elements { new_elems.push(rc_escape(e, owned, boxed, gensym)) }
            HExpr::ListLit { elements: new_elems, ty: ty, effects: effects, span: span }
        },

        HExpr::TupleLit { elements, ty, effects, span } => {
            let mut new_elems: List<HExpr> = []
            for e in elements { new_elems.push(rc_escape(e, owned, boxed, gensym)) }
            HExpr::TupleLit { elements: new_elems, ty: ty, effects: effects, span: span }
        },

        HExpr::IndexExpr { receiver, index, ty, effects, span } => {
            // Read: receiver + index are borrows.  (Escape wrapping of the whole
            // index result happens in rc_escape before reaching value position.)
            HExpr::IndexExpr { receiver: rc_expr(receiver, false, owned, boxed, gensym),
                index: rc_expr(index, false, owned, boxed, gensym),
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
