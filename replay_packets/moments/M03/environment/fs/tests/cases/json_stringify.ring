// Test: json_stringify — converts values to JSON strings

struct Point { x: Int, y: Int }

enum Color { Red, Blue }

fn main() {
    // Primitives
    assert(json_stringify(42) == "42", "int")
    assert(json_stringify("hello") == "\"hello\"", "string")
    assert(json_stringify(true) == "true", "bool")

    // List
    let xs = [1, 2, 3]
    assert(json_stringify(xs) == "[1,2,3]", "list")

    // Struct (JS class with named fields)
    let p = Point { x: 1, y: 2 }
    let s = json_stringify(p)
    assert(s.contains("\"x\":1"), "struct x")
    assert(s.contains("\"y\":2"), "struct y")

    // Enum variant
    let c = Red
    let cs = json_stringify(c)
    assert(cs.contains("\"_tag\":\"Red\""), "enum tag")

    print("json_stringify: all tests passed")
}
