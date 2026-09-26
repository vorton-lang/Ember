// Test: Cell.update method — callback-style mutation

fn main() {
    let c = Cell(10)

    // Basic update
    c.update(fn(x) { x + 5 })
    assert(c.get() == 15, "update adds 5")

    // Multiple updates
    c.update(fn(x) { x * 2 })
    assert(c.get() == 30, "update doubles")

    // Update with captured variable
    let factor = 3
    c.update(fn(x) { x * factor })
    assert(c.get() == 90, "update with captured var")

    // Cell of Str
    let s = Cell("hello")
    s.update(fn(x) { "${x} world" })
    assert(s.get() == "hello world", "cell str update")

    print("cell_update: all tests passed")
}
