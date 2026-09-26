// Phase 2 target: handler with resume — cross-function effect propagation
// io.read in work() propagates up, handler in main() intercepts
fn work() -> Str {
    let data = io.read("input.txt")
    "processed: ${data}"
}

fn main() {
    let result = handle {
        work()
    } with {
        io.read(path) => "mock-data",
    }
    print(result)
}
