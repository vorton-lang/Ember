// Evidence propagation across 3 function call layers
fn inner() -> Str {
    io.read("deep.txt")
}

fn middle() -> Str {
    inner()
}

fn main() {
    let result = handle {
        middle()
    } with {
        io.read(path) => "propagated",
    }
    print(result)
}
