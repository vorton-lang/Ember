// B-101 native self-compile E2E fixture.
//
// A REAL program exercising the std surfaces most likely to expose RC over-free /
// leak bugs under the clone-all-escape borrow model: print, List (push / index /
// iterate / join), Map (insert / index / get / iterate), Str (interpolation /
// index / len). Compiled by the NATIVE ring.exe (see native_selfcompile.test.mjs)
// and run; the harness asserts EXIT 0 + this exact stdout. Element-READ projections
// bound to `let` (list[i], m[k], obj.field) are the B-101 alias-aware-ownership
// hot path: each must be Clone-balanced (no double-free with the container drop).

struct Record {
    name: Str,
    score: Int
}

fn build_records() -> List<Record> {
    let mut rs: List<Record> = []
    rs.push(Record { name: "ada", score: 90 })
    rs.push(Record { name: "bob", score: 75 })
    rs.push(Record { name: "cleo", score: 88 })
    rs
}

// Element read bound, field read bound, both escape into a fresh List.
fn names(rs: List<Record>) -> List<Str> {
    let mut out: List<Str> = []
    for r in rs {
        let nm = r.name          // FieldAccess read = borrow -> Clone into nm
        out.push(nm)             // nm escapes into out -> Clone; per-iter drop
    }
    out
}

// Map round-trip: insert, index-read (borrow -> Clone), .get (fresh owned Option).
fn score_lookup(rs: List<Record>) -> Int {
    let mut m: Map<Str, Int> = map_new()
    for r in rs {
        m.insert(r.name, r.score)
    }
    let direct = m["bob"]        // Map IndexExpr read = borrow -> Clone into direct
    let safe = match m.get("cleo") {
        some(v) => v,            // fresh owned Option payload
        none => 0
    }
    direct + safe                // 75 + 88 = 163
}

fn main() {
    let rs = build_records()

    print("count=${rs.len()}")                      // count=3

    let ns = names(rs)
    print(ns.join(","))                             // ada,bob,cleo

    // List index read bound + string interpolation.
    let top = rs[0]                                 // IndexExpr read -> Clone
    print("top=${top.name} (${top.score})")         // top=ada (90)

    print("sum=${score_lookup(rs)}")                // sum=163

    // Str element read + len.
    let word = "ring"
    print("first=${word[0]} len=${word.len()}")     // first=r len=4

    // Loop accumulating from element/field reads (per-iter Clone + drop).
    let mut total = 0
    for r in rs {
        total = total + r.score
    }
    print("total=${total}")                         // total=253
}
