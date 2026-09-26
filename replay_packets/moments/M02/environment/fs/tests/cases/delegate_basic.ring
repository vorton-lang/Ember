// Basic delegate test: single trait delegation

trait Describable {
    fn describe(self) -> Str
}

struct User {
    name: Str
}

impl Describable for User {
    fn describe(self) -> Str {
        "User: ${self.name}"
    }
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
    let admin = Admin { base: User { name: "Alice" }, level: 5 }
    // Call via trait bound
    assert(print_desc(admin) == "User: Alice", "trait bound dispatch failed")
    // Call directly via UFCS
    assert(admin.describe() == "User: Alice", "direct UFCS dispatch failed")
    print("delegate_basic: all tests passed")
}
