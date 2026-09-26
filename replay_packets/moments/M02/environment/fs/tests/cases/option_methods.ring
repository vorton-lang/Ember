fn main() {
    let s = some(42)
    let n: Option<Int> = none

    // is_some / is_none
    assert(s.is_some(), "some is_some")
    assert(!s.is_none(), "some not is_none")
    assert(n.is_none(), "none is_none")
    assert(!n.is_some(), "none not is_some")

    // unwrap_or
    assert(s.unwrap_or(0) == 42, "some unwrap_or returns inner")
    assert(n.unwrap_or(99) == 99, "none unwrap_or returns default")

    // map
    let doubled = s.map(fn(x) { x * 2 })
    assert(doubled.unwrap_or(0) == 84, "some map applies fn")
    let none_mapped = n.map(fn(x) { x * 2 })
    assert(none_mapped.is_none(), "none map stays none")

    // and_then
    let half = s.and_then(fn(x) {
        if x % 2 == 0 {
            some(x / 2)
        } else {
            none
        }
    })
    assert(half.unwrap_or(0) == 21, "some and_then returns inner option")

    let none_chain = n.and_then(fn(x) { some(x + 1) })
    assert(none_chain.is_none(), "none and_then stays none")

    // chaining
    let result = some(10)
        .map(fn(x) { x + 5 })
        .and_then(fn(x) {
            if x > 10 {
                some(x * 2)
            } else {
                none
            }
        })
        .unwrap_or(0)
    assert(result == 30, "chained option methods")

    print("option_methods: all tests passed")
}
