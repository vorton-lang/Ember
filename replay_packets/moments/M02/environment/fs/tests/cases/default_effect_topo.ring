// Test: topological ordering of default effect evidence injection.
// Effect A depends on effect B (A's default body calls B's op).
// B must be initialized before A at runtime.

effect B {
    fn b_op() -> Int { 42 }
}

effect A {
    fn a_op() -> Int { B.b_op() + 1 }
}

fn main() {
    let result = A.a_op()
    assert(result == 43, "topo order correct")
    print("default_effect_topo: ok")
}
