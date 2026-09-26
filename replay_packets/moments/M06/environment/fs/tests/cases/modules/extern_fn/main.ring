use utils::{parseInt, parseFloat, parse_and_double}

fn main() {
    let x = parseInt("100")
    let y = parseFloat("2.5")
    let z = parse_and_double("21")
    print(x)
    print(y)
    print(z)
}

// expect: 100
// expect: 2.5
// expect: 42
