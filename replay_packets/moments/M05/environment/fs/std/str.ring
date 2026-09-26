impl Str {
    pub extern fn len(self: Str) -> Int
    pub extern fn contains(self: Str, s: Str) -> Bool
    pub extern fn starts_with(self: Str, s: Str) -> Bool
    pub extern fn ends_with(self: Str, s: Str) -> Bool
    pub extern fn slice(self: Str, start: Int, end: Int) -> Str
    pub extern fn trim(self: Str) -> Str
    pub extern fn to_upper(self: Str) -> Str
    pub extern fn to_lower(self: Str) -> Str
    pub extern fn replace(self: Str, old_str: Str, new_str: Str) -> Str
    pub extern fn split(self: Str, sep: Str) -> List<Str>
    pub extern fn char_at(self: Str, i: Int) -> Option<Str>
    pub extern fn index_of(self: Str, s: Str) -> Option<Int>

    pub extern fn pad_start(self: Str, length: Int, fill: Str) -> Str
    pub extern fn pad_end(self: Str, length: Int, fill: Str) -> Str
    pub extern fn repeat(self: Str, count: Int) -> Str
    pub extern fn char_code_at(self: Str, i: Int) -> Option<Int>

    pub extern fn trim_start(self: Str) -> Str
    pub extern fn trim_end(self: Str) -> Str
    pub extern fn is_empty(self: Str) -> Bool
    pub extern fn last_index_of(self: Str, s: Str) -> Int?
}

pub extern type StringBuilder

impl StringBuilder {
    pub extern fn add(self: StringBuilder, s: Str) -> Unit
    pub extern fn line(self: StringBuilder, s: Str) -> Unit
    pub extern fn add_int(self: StringBuilder, n: Int) -> Unit
    pub extern fn to_str(self: StringBuilder) -> Str
    pub extern fn len(self: StringBuilder) -> Int
}

pub extern fn string_builder() -> StringBuilder
