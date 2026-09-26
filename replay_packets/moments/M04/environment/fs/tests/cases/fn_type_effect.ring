fn apply_with_io(f: fn(Int) -> Str with {io}) -> Str with {io} {
    f(42)
}

fn int_to_str(x: Int) -> Str with {io} {
    print("converting")
    x.to_str()
}

fn main() {
    let result = apply_with_io(int_to_str)
    assert(result == "42", "fn type effect annotation")
    print("fn_type_effect: all tests passed")
}
