// Default effect handler with multiple ops, all having defaults
effect Console {
    fn write(msg: Str) -> Unit {
        print(msg)
    }
    fn read_line() -> Str {
        "default-input"
    }
}

fn prompt(question: Str) -> Str {
    Console.write(question)
    Console.read_line()
}

fn main() {
    // All ops have defaults, no handle needed
    let answer = prompt("Name? ")
    assert(answer == "default-input", "default read_line")
    print("default_effect_multi_op: all tests passed")
}
