pub extern fn print<T>(value: T) -> Unit with {io}
pub extern fn assert(cond: Bool, msg: Str) -> Unit with {io}
pub extern fn panic(msg: Str) -> Never
pub extern fn exit(code: Int) -> Unit with {io}
pub extern fn json_stringify<T>(value: T) -> Str
