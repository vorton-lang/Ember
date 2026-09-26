// Handler body with side-effects before return (implicit resume)
fn work() -> Str {
    io.read("input.txt")
}

fn main() {
    let result = handle {
        work()
    } with {
        io.read(path) => {
            print("reading: ${path}")
            "mock-result"
        },
    }
    print(result)
}
