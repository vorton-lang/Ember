// Regression: C1 — == must compile to JS === (strict equality)
fn main() {
    print(1 == 1)
    print(1 != 2)
    print(1 == 2)
    print("a" == "a")
    print("a" == "b")
}
