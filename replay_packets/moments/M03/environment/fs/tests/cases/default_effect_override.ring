// Default effect handler: explicit handle...with overrides the default
effect Logger {
    fn log(msg: Str) -> Unit {
        print("DEFAULT: ${msg}")
    }
}

fn greet(name: Str) {
    Logger.log("Hello, ${name}!")
}

fn main() {
    // Without handle: uses default
    greet("default")

    // With explicit handle: overrides the default
    handle {
        greet("override")
    } with {
        Logger.log(msg) => print("CUSTOM: ${msg}"),
    }
}
