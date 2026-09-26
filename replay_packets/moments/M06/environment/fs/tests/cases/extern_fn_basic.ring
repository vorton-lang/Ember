// Test: extern fn declarations — basic usage
// Declare external JS functions and call them

extern fn parseInt(s: Str) -> Int
extern fn parseFloat(s: Str) -> Float

fn main() {
    let x = parseInt("42")
    let y = parseFloat("3.14")
    print(x)
    print(y)
}

// expect: 42
// expect: 3.14
