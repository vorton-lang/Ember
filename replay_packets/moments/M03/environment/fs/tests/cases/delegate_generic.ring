// Generic delegate: struct with generic field + delegate on concrete field

trait Describable {
    fn describe(self) -> Str
}

struct Inner { value: Int }

impl Describable for Inner {
    fn describe(self) -> Str { "Inner(${self.value.to_str()})" }
}

// Wrapper has a generic field T and a concrete field that gets delegated
struct Wrapper<T> { data: T, inner: Inner }

impl<T> Wrapper {
    delegate inner: Describable
}

fn main() {
    let w1 = Wrapper { data: "hello", inner: Inner { value: 1 } }
    let w2 = Wrapper { data: 42, inner: Inner { value: 99 } }

    assert(w1.describe() == "Inner(1)", "describe should delegate to inner")
    assert(w2.describe() == "Inner(99)", "describe should delegate to inner for int wrapper")

    print("delegate_generic: all tests passed")
}
