enum Color {
    Red,
    Green,
    Blue,
    Yellow
}

fn is_warm(c: Color) -> Bool {
    match c {
        Red | Yellow => true,
        Green | Blue => false
    }
}

fn describe_num(x: Int) -> Str {
    match x {
        0 | 1 => "small",
        2 | 3 | 4 => "medium",
        _ => "big"
    }
}

fn describe_bool(b: Bool) -> Str {
    match b {
        true | false => "any"
    }
}

enum Shape {
    Circle(Int),
    Rect(Int, Int),
    Square(Int)
}

fn is_round(s: Shape) -> Bool {
    match s {
        Circle(_) => true,
        Rect(_, _) | Square(_) => false
    }
}

// Or-pattern with bindings: same binding name extracted from different variants
enum Value {
    IntVal(Int),
    FloatAsInt(Int)
}

fn get_int(v: Value) -> Int {
    match v {
        IntVal(n) | FloatAsInt(n) => n
    }
}

fn main() {
    // Color tests
    assert(is_warm(Red) == true, "red is warm")
    assert(is_warm(Yellow) == true, "yellow is warm")
    assert(is_warm(Green) == false, "green is cold")
    assert(is_warm(Blue) == false, "blue is cold")

    // Literal or-pattern tests
    assert(describe_num(0) == "small", "0 is small")
    assert(describe_num(1) == "small", "1 is small")
    assert(describe_num(2) == "medium", "2 is medium")
    assert(describe_num(3) == "medium", "3 is medium")
    assert(describe_num(4) == "medium", "4 is medium")
    assert(describe_num(99) == "big", "99 is big")

    // Bool or-pattern
    assert(describe_bool(true) == "any", "true is any")
    assert(describe_bool(false) == "any", "false is any")

    // Shape tests
    assert(is_round(Circle(5)) == true, "circle is round")
    assert(is_round(Rect(3, 4)) == false, "rect is not round")
    assert(is_round(Square(5)) == false, "square is not round")

    // Binding or-pattern tests
    assert(get_int(IntVal(42)) == 42, "IntVal binding")
    assert(get_int(FloatAsInt(7)) == 7, "FloatAsInt binding")

    print("or pattern: ok")
}
