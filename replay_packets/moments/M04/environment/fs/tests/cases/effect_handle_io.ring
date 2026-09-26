// Phase 2 target: handle/with for io effect with resume
// Tests: io mock via handler, resume continuation
fn main() {
    let msg = handle {
        let data = io.read("config.toml")
        "got: ${data}"
    } with {
        io.read(path) => "mock-data",
    }
    print(msg)
}
