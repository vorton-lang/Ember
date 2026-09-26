// Test: delegate binary trait methods (e.g. Eq) should forward other.field correctly

struct Inner {
    value: Int
}

impl Eq for Inner {
    fn eq(self, other: Inner) -> Bool {
        self.value == other.value
    }
}

struct Wrapper {
    inner: Inner,
    label: Str,
}

impl Wrapper {
    delegate inner: Eq
}

fn check_eq<T: Eq>(a: T, b: T) -> Bool {
    a == b
}

fn main() {
    let a = Wrapper { inner: Inner { value: 42 }, label: "a" }
    let b = Wrapper { inner: Inner { value: 42 }, label: "b" }
    let c = Wrapper { inner: Inner { value: 99 }, label: "a" }

    // Eq compares via delegated inner field, ignoring label
    assert(check_eq(a, b) == true, "equal wrappers should be eq")
    assert(check_eq(a, c) == false, "different inner values should not be eq")
    assert(a == b, "operator == via delegate should work")
    assert((a == c) == false, "operator == negative case")
    print("delegate_eq: all tests passed")
}
