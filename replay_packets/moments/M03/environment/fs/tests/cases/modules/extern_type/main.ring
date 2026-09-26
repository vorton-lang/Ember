// B-074: import an extern type + extern fns from another module.
// - FloatBox is used purely as a cross-module type annotation (opaque).
// - parseFloat / parseInt are extern fns called directly in the consumer.
use jsffi::{FloatBox, parseFloat, parseInt, round_trip}

// Extern type used in a type annotation across modules; the value just flows
// through unchanged, proving the type carries with no runtime representation.
fn passthrough(b: FloatBox) -> FloatBox {
    b
}

fn main() {
    let b = parseFloat("41.0")
    let b2 = passthrough(b)
    print(parseInt(b2) + 1)
    print(round_trip("7.9"))
}

// expect: 42
// expect: 7
