// Module declaring an opaque extern type plus extern fns that operate on it.
// Backed by real JS globals (parseFloat / parseInt) so the e2e test actually
// runs. Regression for B-074: extern type/fn must be importable across modules.

pub extern type FloatBox

// parseFloat: Str -> opaque numeric box (JS number)
pub extern fn parseFloat(s: Str) -> FloatBox
// parseInt coerces its arg to a string, so passing the box truncates to an Int
pub extern fn parseInt(b: FloatBox) -> Int

// A regular pub fn that uses the extern type + fns internally.
pub fn round_trip(s: Str) -> Int {
    parseInt(parseFloat(s))
}
