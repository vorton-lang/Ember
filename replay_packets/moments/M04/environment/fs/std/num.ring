impl Int {
    pub extern fn to_str(self: Int) -> Str
}

impl Float {
    pub extern fn to_str(self: Float) -> Str
}

pub extern fn parse_int(s: Str) -> Option<Int>
pub extern fn parse_float(s: Str) -> Option<Float>
