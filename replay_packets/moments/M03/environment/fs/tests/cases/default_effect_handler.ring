// Default effect handler: all ops have default bodies, no handle...with needed
effect Logger {
    fn log(msg: Str) -> Unit {
        print(msg)
    }
}

fn greet(name: Str) {
    Logger.log("Hello, ${name}!")
}

fn deep_call() {
    greet("deep")
}

fn main() {
    // Logger has all ops with defaults, no handle...with required
    greet("World")
    deep_call()
}
