// Delegate a trait with supertrait — bound check should find impl

trait Named {
    fn name(self) -> Str
}

trait Greeter: Named {
    fn greet(self) -> Str
}

struct Person { name_val: Str }
impl Named for Person {
    fn name(self) -> Str { self.name_val }
}
impl Greeter for Person {
    fn greet(self) -> Str { "Hello, ${self.name()}!" }
}

struct Employee { person: Person }
impl Employee {
    delegate person: Greeter  // should also register Named for Employee
}

fn print_name<T: Named>(x: T) {
    print(x.name())
}

fn main() {
    let e = Employee { person: Person { name_val: "Alice" } }
    print_name(e)  // This requires Employee: Named, which comes from supertrait
    print(e.greet())
    print("delegate_supertrait_bound: all tests passed")
}
