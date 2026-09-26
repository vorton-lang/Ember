// Error: trait already implemented via hand-written impl, delegate should conflict

struct Inner { value: Int }
struct Outer { inner: Inner }

impl Eq for Inner {
    fn eq(self, other: Inner) -> Bool { self.value == other.value }
}

impl Eq for Outer {
    fn eq(self, other: Outer) -> Bool { self.inner == other.inner }
}

impl Outer {
    delegate inner: Eq  // ERROR: Eq already implemented for Outer
}

fn main() {}
