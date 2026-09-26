fn pure_add(a: Int, b: Int) -> Int {
    a + b
}

fn effectful_read(path: Str) -> Str {
    io.read(path)
}

fn main() {
    let x = pure_add(1, 2)
    let y = handle { effectful_read("data") } with {
        io.read(path) => "mock-${path}"
    }
    print("${x}-${y}")
}
