// Test: delegate with traits that have default methods should work correctly
// The field type relies on the default method body (no explicit impl for it)

trait Describable {
    fn name(self) -> Str
    fn describe(self) -> Str {
        "I am ${self.name()}"
    }
}

struct User {
    user_name: Str
}

impl Describable for User {
    fn name(self) -> Str {
        self.user_name
    }
    // describe() uses default implementation
}

struct Admin {
    base: User,
    level: Int,
}

impl Admin {
    delegate base: Describable
}

fn print_desc<T: Describable>(item: T) -> Str {
    item.describe()
}

fn main() {
    let admin = Admin { base: User { user_name: "Alice" }, level: 5 }
    // name() has explicit impl, should work via UFCS forwarding
    assert(admin.name() == "Alice", "explicit method via delegate failed")
    // describe() is a default method, should work via trait dict dispatch
    assert(admin.describe() == "I am Alice", "default method via delegate failed")
    // Should also work through trait bound dispatch
    assert(print_desc(admin) == "I am Alice", "default method via trait bound failed")
    print("delegate_default_method: all tests passed")
}
