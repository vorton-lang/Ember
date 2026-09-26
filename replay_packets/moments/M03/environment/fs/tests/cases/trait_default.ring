trait Describable {
    fn name(self) -> Str
    fn describe(self) -> Str {
        self.name()
    }
}

struct Cat { n: Str }
impl Describable for Cat {
    fn name(self) -> Str { self.n }
}

fn show<T: Describable>(x: T) -> Str {
    x.describe()
}

fn main() {
    let c = Cat { n: "Whiskers" }
    print(show(c))
}
