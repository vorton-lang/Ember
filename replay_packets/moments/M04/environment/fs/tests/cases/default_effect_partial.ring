// Partial default: one op has default, another doesn't.
// Must still use handle...with to provide the missing op.
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
    let result = handle {
        get_data("config")
    } with {
        Storage.read_data(key) => "value_for_${key}",
        Storage.log_access(key) => print("LOG: ${key}"),
    }
    assert(result == "value_for_config", "partial default with handle")
    print("default_effect_partial: all tests passed")
}
