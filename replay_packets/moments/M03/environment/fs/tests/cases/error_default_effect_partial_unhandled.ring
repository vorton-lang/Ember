// Negative test: partial default effect not handled -> E0403
effect Storage {
    fn read_data(key: Str) -> Str
    fn log_access(key: Str) -> Unit {
        print("accessed: ${key}")
    }
}

fn get_data(key: Str) -> Str {
    Storage.log_access(key)
    Storage.read_data(key)
}

fn main() {
    // Storage has read_data without default, must be handled
    let result = get_data("config")
    print(result)
}
