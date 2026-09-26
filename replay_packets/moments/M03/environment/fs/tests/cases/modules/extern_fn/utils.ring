// Utility module that wraps extern fn declarations

pub extern fn parseInt(s: Str) -> Int
pub extern fn parseFloat(s: Str) -> Float

pub fn parse_and_double(s: Str) -> Int {
    let n = parseInt(s)
    n * 2
}
