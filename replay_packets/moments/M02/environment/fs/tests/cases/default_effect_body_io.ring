// Test: default effect body that calls a local function requiring io
// Verifies evidence parameters are correctly passed to default effect
// handler factory functions when the body needs effects like io.

fn log_message(msg: Str) {
    print("LOG: ${msg}")
}

effect Logger {
    fn log(msg: Str) -> Str {
        // Default body calls log_message which requires io
        log_message(msg)
        msg
    }

    fn tag() -> Str {
        // Default body directly calls print (extern fn with io effect)
        print("TAG")
        "tagged"
    }
}

fn use_logger() -> Str {
    let tag = Logger.tag()
    Logger.log("hello ${tag}")
}

fn main() {
    let result = use_logger()
    assert(result == "hello tagged", "should return the message")
    print("default effect body io: ok")
}
