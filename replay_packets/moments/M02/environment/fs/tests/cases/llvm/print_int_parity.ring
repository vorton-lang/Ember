// B-087 gap 6 (#132): print() of non-Str arguments must stringify like JS.
// JS `print(x)` stringifies any type; LLVM's ring_print expected its argument to
// already be a Str. print(intExpr) thus diverged (LLVM printed garbage / wrong).
// Fix: LLVM print lowering inserts to_string for non-Str args (Int/Float/Bool).

fn main() {
    print(42)
    print(7 + 3)
    let x = 100
    print(x)
    print(3.5)
    print(0.1)
    print(100.0)
    print(0.001)
    print(1000000.0)
    print(0.0)
    print(-2.5)
    print(123456.789)
    print(0.0000001)
    print(true)
    print(false)
    print("str ok")
    // Float.to_str() must also be JS-parity (string interp shares ring_float_to_str)
    let f = 2.75
    print("interp ${f}")
}
