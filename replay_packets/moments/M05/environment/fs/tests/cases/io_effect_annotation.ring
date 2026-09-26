// Test: io effect is correctly tracked from print/assert/exit

// Function with io effect (inferred from print)
fn greet(name: Str) {
    print("hello ${name}")
}

// Function that calls greet — should also infer io
fn greet_all() {
    greet("world")
    greet("ring")
}

fn main() {
    greet_all()
    print("io_effect_annotation: all tests passed")
}
