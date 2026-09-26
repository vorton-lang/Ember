sig Logger {
    fn log(msg: Str) -> Unit with {io}
    fn level() -> Str
}

sig Fallible {
    fn parse(input: Str) -> Int with {fail<Str>}
}

fn main() {
    print("sig_with_effects: all tests passed")
}
