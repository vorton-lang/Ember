struct Point { x: Int, y: Int }
struct Empty {}
enum Color { Red, Green, Blue }
enum Shape { Circle(Float), Rect(Float, Float) }

fn main() {
    // Struct debug
    let p = Point { x: 1, y: 2 }
    assert(p.debug() == "Point { x: 1, y: 2 }", "struct debug")

    // Empty struct debug
    let e = Empty {}
    assert(e.debug() == "Empty", "empty struct debug")

    // Enum unit variant debug
    assert(Color::Red.debug() == "Red", "enum unit debug")
    assert(Color::Blue.debug() == "Blue", "enum unit debug 2")

    // Enum positional variant debug
    assert(Circle(3.14).debug() == "Circle(3.14)", "enum positional debug")
    assert(Rect(1.5, 2.5).debug() == "Rect(1.5, 2.5)", "enum multi-field debug")

    // Primitive debug
    assert((42).debug() == "42", "int debug")
    assert(true.debug() == "true", "bool debug")
    assert(false.debug() == "false", "bool false debug")

    print("debug_basic: all tests passed")
}
