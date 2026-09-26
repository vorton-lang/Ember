trait Container {
    type Item
    fn get(self) -> Item
    fn describe(self) -> Str
}

struct IntStore {
    val: Int
}

impl Container for IntStore {
    type Item = Int
    fn get(self) -> Int { self.val }
    fn describe(self) -> Str { "store(${self.val})" }
}

struct Wrapper {
    inner: IntStore
}

impl Wrapper {
    delegate inner: Container
}

fn main() {
    let w = Wrapper { inner: IntStore { val: 42 } }
    let v = w.get()
    assert(v == 42, "delegate get should return 42")
    let d = w.describe()
    assert(d == "store(42)", "delegate describe should work")
    // Test that get() returns Int and can be used as Int
    let sum = v + 10
    assert(sum == 52, "should be able to use delegated assoc type value as Int")
    print("delegate_assoc_type: ok")
}
