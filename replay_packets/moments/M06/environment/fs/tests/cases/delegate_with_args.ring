// Delegate trait method with extra arguments

trait Greeter {
    fn greet(self, greeting: Str) -> Str
}

struct Person {
    name: Str
}

impl Greeter for Person {
    fn greet(self, greeting: Str) -> Str {
        "${greeting}, ${self.name}!"
    }
}

struct Employee {
    person: Person,
    title: Str,
}

impl Employee {
    delegate person: Greeter
}

fn greet_all<T: Greeter>(who: T, msg: Str) -> Str {
    who.greet(msg)
}

fn main() {
    let emp = Employee { person: Person { name: "Carol" }, title: "Engineer" }
    assert(greet_all(emp, "Hello") == "Hello, Carol!", "trait bound with args failed")
    assert(emp.greet("Hi") == "Hi, Carol!", "direct call with args failed")
    print("delegate_with_args: all tests passed")
}
