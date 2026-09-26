// B-104 D1 rule ④ regression: runtime OVERWRITE drops the old slot value.
//
// THE CHANGE THIS PINS: ring_list_set / ring_map_set / ring_map_int_set now drop
// the value previously stored in the slot.  Insert side (verified, perceus
// sink_arg_indices): the value arg of .set/.insert is a sink — borrows are
// escape-Cloned (dup), fresh temps transfer ownership — so the container owns +1
// per slot (drop_list/drop_map deep-drop it at end-of-life).  Overwriting without
// a drop leaked that +1, unbounded for hot slots (the rule-④ leak class).
//
// THE UAF RISK THIS PINS (rc>1 sharing): the old value may be co-owned —
//   * `let saved = xs[i]` / `let saved = m[k]` escape-Clones the element (rc 2):
//     the overwrite drop must DECREMENT, not free — the JS oracle pins saved's
//     surviving content;
//   * self-assign `xs.set(0, xs[0])`: the sink arg arrives with its own call-site
//     dup (rc 2), so store-then-drop nets rc back to 1 with the slot still valid.
// A wrong impl (dropping an account the container never held, or drop-before-
// store) frees live values → native UAF; ASan + the JS diff catch it.

fn list_set_basic() -> Str {
    let mut xs = ["a", "b", "c"]
    xs.set(1, "B")              // old "b" unshared (rc=1) → freed: the reclaimed leak
    "${xs[0]}${xs[1]}${xs[2]} len=${xs.len()}"
}

fn list_set_shared() -> Str {
    let mut xs = ["old", "keep"]
    let saved = xs[0]           // escape-Clone dup: saved co-owns "old" (rc 2)
    xs.set(0, "new")            // overwrite drop decrements rc 2→1 — saved survives
    "${xs[0]} ${saved} ${xs[1]}"
}

fn list_set_self() -> Str {
    let mut xs = ["x", "y"]
    xs.set(0, xs[0])            // sink arg dup'd at call site (rc 2) → store + drop old → rc 1
    "${xs[0]}${xs[1]}"
}

fn map_set_overwrite() -> Str {
    let mut m = map_from([("k", "v1"), ("z", "zz")])
    m.insert("k", "v2")         // hit: old "v1" dropped (key node reused, no key account)
    m.insert("w", "ww")         // miss: plain insert, nothing to drop
    "${m["k"]} ${m["z"]} ${m["w"]} len=${m.len()}"
}

fn map_set_shared() -> Str {
    let mut m = map_from([("k", "v1")])
    let saved = m["k"]          // escape-Clone dup (rc 2)
    m.insert("k", "v2")         // overwrite drop → rc 2→1, saved survives
    "${m["k"]} ${saved}"
}

fn map_int_set_shared() -> Str {
    let mut m = map_from([(1, "one"), (2, "two")])
    let saved = m[1]            // int-keyed map (ring_map_int_set path)
    m.insert(1, "uno")
    "${m[1]} ${saved} ${m[2]} len=${m.len()}"
}

fn list_set_in_loop() -> Str {
    // Hot-slot overwrite: every iteration drops the previous value (pre-fix this
    // leaked one Str per iteration); ASan must stay clean across all 100 drops.
    let mut xs = ["seed"]
    for i in 0..100 {
        xs.set(0, "v${i}")
    }
    xs[0]
}

fn main() {
    print("list_basic: ${list_set_basic()}")     // list_basic: aBc len=3
    print("list_shared: ${list_set_shared()}")   // list_shared: new old keep
    print("list_self: ${list_set_self()}")       // list_self: xy
    print("map_set: ${map_set_overwrite()}")     // map_set: v2 zz ww len=3
    print("map_shared: ${map_set_shared()}")     // map_shared: v2 v1
    print("mi_shared: ${map_int_set_shared()}")  // mi_shared: uno one two len=2
    print("loop: ${list_set_in_loop()}")         // loop: v99
    print("done")
}
