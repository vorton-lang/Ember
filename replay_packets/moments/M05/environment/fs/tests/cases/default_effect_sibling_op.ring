// Test: default effect handler ops can call sibling ops
// Regression test for audit #80 — evidence object TDZ safety

effect Counter {
    fn get() -> Int { 0 }
    fn increment() -> Int {
        let current = Counter.get()
        current + 1
    }
}

fn use_counter() -> Int with {Counter} {
    Counter.increment()
}

fn use_both() -> Int with {Counter} {
    let a = Counter.get()
    let b = Counter.increment()
    a + b
}

fn main() {
    // Test 1: default evidence — increment's default body calls get (sibling op)
    let result = use_counter()
    assert(result == 1, "increment should call sibling get and return 1")

    // Test 2: handle...with overriding get, increment uses default body referencing get
    let result2 = handle {
        use_counter()
    } with {
        Counter.get() => 10,
    }
    assert(result2 == 11, "increment default should call overridden get")

    // Test 3: default evidence with both ops used
    let result3 = use_both()
    assert(result3 == 1, "get=0, increment=1, sum=1")

    print("default effect sibling op: ok")
}
