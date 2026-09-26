// Multiple effects handled simultaneously
fn load_or_fail() -> Str {
    let data = io.read("input.txt")
    if data == "" {
        fail.raise("empty file")
    }
    data
}

fn main() {
    let result = handle {
        load_or_fail()
    } with {
        io.read(path) => "file-content",
        fail.raise(e) => "error-handled",
    }
    print(result)
}
