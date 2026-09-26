sig Greeter {
    fn greet(name: Str) -> Str
    fn farewell(name: Str) -> Str
}

pub sig Storage {
    fn save(key: Str, data: Str) -> Unit
    fn load(key: Str) -> Str
}

fn greet(name: Str) -> Str {
    "Hello, ${name}!"
}

fn main() {
    assert(greet("world") == "Hello, world!", "sig basic")
    print("sig_basic: all tests passed")
}
