trait Describable {
    fn name(self) -> Str
    fn describe(self) -> Str {
        "I am ${self.name()}"
    }
}

struct Cat { n: Str }

impl Describable for Cat {
    fn name(self) -> Str { self.n }
}

fn main() {
    let c = Cat { n: "Whiskers" }
    assert(c.name() == "Whiskers", "name should work")
    assert(c.describe() == "I am Whiskers", "default method UFCS should work")
    print("trait default ufcs: ok")
}
