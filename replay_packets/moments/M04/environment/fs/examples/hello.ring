// Ring-lang: Hello World

struct Greeting {
    target: Str,
    enthusiasm: Int,
}

fn greet(g: Greeting) -> Str {
    "Hello, ${g.target}!"
}

fn main() {
    let g = Greeting { target: "Ring-lang", enthusiasm: 3 }
    print(greet(g))
}
