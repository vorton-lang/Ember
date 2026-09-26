struct Pair<A, B> { first: A, second: B }
enum Wrapper<T> { Val(T), Empty }
struct Point { x: Int, y: Int }
struct Line { start: Point, end: Point }

fn main() {
    // Generic struct debug
    let p = Pair { first: 1, second: 2 }
    assert(p.debug() == "Pair { first: 1, second: 2 }", "generic struct debug")

    // Mixed-type generic struct (Str debug includes quotes)
    let m = Pair { first: "hello", second: 42 }
    assert(m.debug() == "Pair { first: \"hello\", second: 42 }", "generic mixed debug")

    // Generic enum debug
    assert(Val(42).debug() == "Val(42)", "generic enum val debug")
    let w: Wrapper<Int> = Wrapper::Empty
    assert(w.debug() == "Empty", "generic enum empty debug")

    // Nested non-generic struct debug
    let line = Line { start: Point { x: 0, y: 1 }, end: Point { x: 2, y: 3 } }
    assert(line.debug() == "Line { start: Point { x: 0, y: 1 }, end: Point { x: 2, y: 3 } }", "nested struct debug")

    // Option debug
    let s = some(42)
    assert(s.debug() == "some(42)", "option some debug")
    let n: Int? = none
    assert(n.debug() == "none", "option none debug")

    // List debug
    let xs = [1, 2, 3]
    assert(xs.debug() == "[1, 2, 3]", "list debug")
    let empty = [1].filter(fn(x: Int) -> Bool { false })
    assert(empty.debug() == "[]", "empty list debug")

    print("debug_generic: all tests passed")
}
