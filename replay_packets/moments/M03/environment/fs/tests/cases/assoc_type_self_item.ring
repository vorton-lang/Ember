// Self::Item path in trait and impl bodies
trait Container {
    type Item
    fn get(self) -> Self::Item
    fn transform(self) -> Self::Item {
        // Self::Item in default method body
        self.get()
    }
}

struct IntBox {
    val: Int
}

impl Container for IntBox {
    type Item = Int
    fn get(self) -> Self::Item { self.val }
    // transform uses default impl
}

struct StrBox {
    val: Str
}

impl Container for StrBox {
    type Item = Str
    fn get(self) -> Str { self.val }
    fn transform(self) -> Self::Item {
        // Self::Item in impl method body
        self.get()
    }
}

fn main() {
    let ib = IntBox { val: 42 }
    let v = ib.transform()
    assert(v == 42, "Self::Item in default body should resolve correctly")

    let sb = StrBox { val: "hello" }
    let sv = sb.transform()
    assert(sv == "hello", "Self::Item in impl body should resolve correctly")

    // Also test that Self::Item works in trait method return type
    let g = ib.get()
    assert(g == 42, "Self::Item in trait method signature should work")

    print("assoc_type_self_item: ok")
}
