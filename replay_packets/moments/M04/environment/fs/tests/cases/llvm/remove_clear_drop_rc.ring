// B-104 D1 rule ④ regression: runtime REMOVE / CLEAR drops the owned contents.
//
// THE CHANGE THIS PINS: ring_map_delete / ring_map_int_delete drop the removed
// value; ring_list_clear / ring_map_clear / ring_map_int_clear drop every
// element/value before clearing (the container owns +1 per stored value via the
// .insert/.push sink dups — drop_map/drop_list settle that account at
// end-of-life, but remove/clear previously just erased the pointers → leak).
// ring_set_clear / ring_set_int_clear are audited NO-OPs RC-wise: set elements
// are value-inlined (std::string / int64 copies, no RC pointer stored — the
// #135 ring_set_clone conclusion).  Set.clear is NOT exercised here: the LLVM
// method_to_runtime has no "Set"/"clear" mapping (pre-existing native
// panic-stub, found by this case's first run — see audit-report); JS-side
// behaviour is covered by tests/cases/collection_clear.ring.
//
// THE UAF RISK THIS PINS (rc>1 sharing): a `let saved = m[k]` / `xs[i]`
// escape-Clone co-owns the value (rc 2); the remove/clear drop must DECREMENT,
// not free — the JS oracle pins saved's surviving content, ASan the liveness.
// Containers must stay alive and reusable after clear (insert/push again).

fn map_remove_shared() -> Str {
    let mut m = map_from([("a", "va"), ("b", "vb")])
    let saved = m["a"]          // escape-Clone dup (rc 2)
    m.remove("a")               // drop decrements rc 2→1 — saved survives
    m.remove("ghost")           // miss: no-op, nothing to drop
    "${saved} len=${m.len()} hasA=${m.contains_key("a")} b=${m["b"]}"
}

fn map_remove_unshared() -> Str {
    let mut m = map_from([("x", "vx"), ("y", "vy")])
    m.remove("x")               // unshared value (rc=1) → freed: the reclaimed leak
    "len=${m.len()} y=${m["y"]}"
}

fn map_int_remove_shared() -> Str {
    let mut m = map_from([(1, "one"), (2, "two")])
    let saved = m[1]
    m.remove(1)                 // int-keyed: ring_map_int_delete path
    "${saved} len=${m.len()} two=${m[2]}"
}

fn list_clear_shared() -> Str {
    let mut xs = ["p", "q", "r"]
    let saved = xs[2]           // escape-Clone dup (rc 2)
    xs.clear()                  // drops all three elements; saved survives (rc 2→1)
    xs.push("s")                // list reusable after clear
    "${saved} len=${xs.len()} s=${xs[0]}"
}

fn map_clear_shared() -> Str {
    let mut m = map_from([("x", "vx"), ("y", "vy")])
    let saved = m["y"]
    m.clear()                   // drops both values; saved survives
    m.insert("z", "vz")         // map reusable after clear
    "${saved} len=${m.len()} z=${m["z"]}"
}

fn map_int_clear_shared() -> Str {
    let mut m = map_from([(7, "seven"), (8, "eight")])
    let saved = m[7]
    m.clear()
    "${saved} len=${m.len()}"
}

fn clear_in_loop() -> Str {
    // Unbounded reclaim: fill + clear repeatedly — pre-fix every element leaked;
    // ASan must stay clean across all the drops.
    let mut xs: List<Str> = []
    let mut m = map_new()
    for i in 0..50 {
        xs.push("e${i}")
        xs.push("f${i}")
        xs.clear()
        m.insert("k", "v${i}")
        m.remove("k")
    }
    "xs=${xs.len()} m=${m.len()}"
}

fn main() {
    print("map_rm: ${map_remove_shared()}")        // map_rm: va len=1 hasA=false b=vb
    print("map_rm2: ${map_remove_unshared()}")     // map_rm2: len=1 y=vy
    print("mi_rm: ${map_int_remove_shared()}")     // mi_rm: one len=1 two=two
    print("list_clear: ${list_clear_shared()}")    // list_clear: r len=1 s=s
    print("map_clear: ${map_clear_shared()}")      // map_clear: vy len=1 z=vz
    print("mi_clear: ${map_int_clear_shared()}")   // mi_clear: seven len=0
    print("loop: ${clear_in_loop()}")              // loop: xs=0 m=0
    print("done")
}
