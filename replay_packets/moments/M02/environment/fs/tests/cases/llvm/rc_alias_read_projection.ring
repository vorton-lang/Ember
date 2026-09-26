// B-101 regression: alias-aware ownership for element-READ projections.
//
// The clone-all-escape borrow model (B-098) makes container element / field reads
// return a BORROW (ring_list_get / ring_map_get / struct-GEP do NOT dup). When such
// a read is bound to a `let`, the binding is owner-bearing, so Perceus's rc_escape
// wraps the initialiser in HExpr::Clone (gen_clone -> ring_dup): the binding owns an
// INDEPENDENT dup'd reference, and its scope-end Drop releases that dup WITHOUT
// touching the container's own element. The container's later element drop is then
// balanced. A *wrong* implementation that treated the bound read as a bare borrow
// and still scope-end-dropped it (or, conversely, dropped the container's element
// twice) would over-free -> native abort/garbage; a wrong implementation that
// cloned-but-never-dropped would leak (no crash, but wasteful). The JS backend is
// the oracle; the native run must match it byte-for-byte AND not crash.
//
// This pins the exact code shapes flagged by the B-101 diagnostics:
//   - `let x = list[i]`         (IndexExpr read, then x used + dropped)
//   - `let x = m[k]`            (Map IndexExpr read)
//   - `let x = obj.field`       (FieldAccess read)
//   - the read binding ESCAPING again (returned / pushed into another container)
//   - element reads inside a loop that drops per-iteration
//   - `.get()` fresh-owned Option (must NOT be double-freed with the container)

struct Box {
    label: Str,
    value: Int
}

// A read binding that escapes (returned): list[i] -> Clone -> caller owns it; the
// source list still owns its element and is dropped at scope end.
fn first_label(boxes: List<Box>) -> Str {
    let b = boxes[0]          // IndexExpr read = borrow; rc_escape clones into b
    let l = b.label           // FieldAccess read = borrow; cloned into l
    l                         // l escapes (return) -> cloned again, scope drops l + b
}

// Map element read bound + re-stored into another container (double escape).
fn collect_values(m: Map<Str, Str>, keys: List<Str>) -> List<Str> {
    let mut out: List<Str> = []
    for k in keys {
        let v = m[k]          // Map IndexExpr read = borrow; cloned into v
        out.push(v)           // v escapes into out -> cloned; scope drops v per-iter
    }
    out
}

// `.get()` returns a FRESH owned Option (ring_*_get_opt dups the element in). It is
// currently NOT scope-end-dropped (leak-safe, B-101 whitelist excludes it pending
// L3) — but it must NEVER be double-freed against the container.
fn safe_first(xs: List<Int>) -> Int {
    match xs.get(0) {
        some(v) => v,
        none => -1
    }
}

fn main() {
    let boxes = [
        Box { label: "alpha", value: 1 },
        Box { label: "beta", value: 2 }
    ]
    print(first_label(boxes))                 // alpha

    let mut m: Map<Str, Str> = map_new()
    m.insert("a", "apple")
    m.insert("b", "banana")
    let vals = collect_values(m, ["a", "b"])
    print(vals.join(","))                     // apple,banana

    let nums = [10, 20, 30]
    print("first=${safe_first(nums)}")        // first=10

    // String element read bound then dropped.
    let s = "hello"
    let c = s[1]                              // Str index read
    print("c=${c}")                           // c=e

    // Nested: read an element, read its field, in a loop dropping per-iteration.
    let mut total = 0
    for b in boxes {
        let lbl = b.label                     // FieldAccess read, cloned + dropped
        total = total + lbl.len()
    }
    print("total=${total}")                   // total=9  (alpha=5 + beta=4)
}
