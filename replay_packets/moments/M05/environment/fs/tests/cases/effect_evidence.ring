// Evidence passing: handler provides mock io.read implementation
fn read_config() -> Str {
    io.read("config.toml")
}

fn main() {
    let data = handle {
        read_config()
    } with {
        io.read(path) => "mock-data",
    }
    print(data)
}
