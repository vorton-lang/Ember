// #72: handle...with partial handle should merge default op evidence
// When effect has multiple ops and some have default bodies,
// handle...with that only handles non-default ops should still
// inject the default ops into the evidence object.
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
    // Only handle read_data, rely on log_access default
    let result = handle {
        get_data("config")
    } with {
        Storage.read_data(key) => "value_for_${key}",
    }
    assert(result == "value_for_config", "partial handle with default op")
    print("audit_partial_handle_default: all tests passed")
}
