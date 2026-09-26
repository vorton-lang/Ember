// B-103 → B-104 D1 rule ② regression: RECEIVER-RETURNING MUTATORS must not be
// dropped or cloned.
//
// At the LLVM ABI, ring_list_push / ring_list_set / ring_map_set / ring_map_delete
// / ring_set_add / ring_set_delete / ring_list_clear / ring_map_clear /
// ring_list_extend all `return <receiver>;` VERBATIM (no dup) — even though the
// Ring-level method type is Unit.  Binding such a call (`let r = xs.push(4)`)
// therefore binds the LIVE CONTAINER; scope-end-dropping r would deep-free the
// caller's container → native UAF / heap corruption.
//
// Mechanism history: B-103 guarded this by listing the 9 mutator field names in
// is_borrow_returning_call (the binding was Clone-wrapped, the dup balanced the
// drop).  B-104 D1 rule ② replaced the name grain with the TYPE-level Unit
// exclusion: a Unit-typed value is never Clone'd, never dropped, never owned,
// never materialised (is_rc_excluded_type) — the binding holds the raw receiver
// pointer and no drop is ever emitted for it.  Same UAF protection, no churn,
// and user methods sharing the names are no longer misclassified.
//
// Every helper binds a mutator result, lets it go out of scope, and the caller
// keeps using the container afterwards.  JS backend (mutator returns undefined)
// is the oracle; LLVM output must match byte-for-byte and not corrupt the heap.

fn bind_push(mut xs: List<Str>) -> Int {
    let r = xs.push("d")
    xs.len()
}   // r dropped here — must NOT free xs

fn bind_set(mut xs: List<Str>) -> Str {
    let r = xs.set(0, "z")
    xs[0]
}

fn bind_extend(mut xs: List<Str>, ys: List<Str>) -> Int {
    let r = xs.extend(ys)
    xs.len()
}

fn bind_clear(mut xs: List<Str>) -> Int {
    let r = xs.clear()
    xs.len()
}

fn bind_map_insert(mut m: Map<Str, Str>) -> Int {
    let r = m.insert("b", "two")
    m.len()
}

fn bind_map_remove(mut m: Map<Str, Str>) -> Int {
    let r = m.remove("b")
    m.len()
}

fn bind_map_int_insert(mut m: Map<Int, Str>) -> Int {
    let r = m.insert(2, "two")
    m.len()
}

fn bind_set_add(mut s: Set<Str>) -> Int {
    let r = s.insert("y")
    s.len()
}

fn bind_set_remove(mut s: Set<Str>) -> Int {
    let r = s.remove("y")
    s.len()
}

// Mutator call in fn-TAIL position (escape) — the result is Clone-wrapped
// (owner-bearing) and the caller discards it; must not corrupt the receiver.
fn tail_push(mut xs: List<Str>) {
    xs.push("t")
}

fn main() {
    let mut a = ["a", "b", "c"]
    print("push: ${bind_push(a)}")          // push: 4
    print("alive: ${a.len()} ${a[3]}")       // alive: 4 d

    print("set: ${bind_set(a)}")             // set: z
    print("alive2: ${a[0]}")                  // alive2: z

    let b = ["x", "y"]
    print("extend: ${bind_extend(a, b)}")    // extend: 6
    print("src: ${b.len()} ${b[0]}")          // src: 2 x

    tail_push(a)
    print("tail: ${a.len()} ${a[6]}")         // tail: 7 t

    let mut m = map_new()
    let r0 = m.insert("a", "one")
    print("mins: ${bind_map_insert(m)}")     // mins: 2
    print("mget: ${m["a"]} ${m["b"]}")        // mget: one two
    print("mrem: ${bind_map_remove(m)}")     // mrem: 1
    print("mget2: ${m["a"]}")                  // mget2: one

    let mut mi: Map<Int, Str> = map_new()
    let r1 = mi.insert(1, "one")
    print("miins: ${bind_map_int_insert(mi)}") // miins: 2
    print("miget: ${mi[1]} ${mi[2]}")           // miget: one two

    let mut s = set_new()
    let r2 = s.insert("x")
    print("sadd: ${bind_set_add(s)}")        // sadd: 2
    print("srem: ${bind_set_remove(s)}")     // srem: 1
    let hx = s.has("x")
    if hx { print("shas: yes") } else { print("shas: no") }   // shas: yes

    print("clear: ${bind_clear(a)}")          // clear: 0
    print("done")
}
