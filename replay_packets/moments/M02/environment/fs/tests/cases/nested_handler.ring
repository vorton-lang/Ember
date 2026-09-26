// M13: Nested handle/with — inner + outer handlers for the same effect
fn main() {
    let result = handle {
        let inner = handle {
            io.read("inner-file")
        } with {
            io.read(path) => "inner-${path}",
        }
        let outer = io.read("outer-file")
        "${inner}-${outer}"
    } with {
        io.read(path) => "outer-${path}",
    }
    print(result)
}
