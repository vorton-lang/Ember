// Delegate multiple traits from the same field

trait Describable {
    fn describe(self) -> Str
}

trait Loggable {
    fn log_msg(self) -> Str
}

struct User {
    name: Str
}

impl Describable for User {
    fn describe(self) -> Str {
        "User: ${self.name}"
    }
}

impl Loggable for User {
    fn log_msg(self) -> Str {
        "[LOG] ${self.name}"
    }
}

struct Admin {
    base: User,
    level: Int,
}

impl Admin {
    delegate base: Describable, Loggable
}

fn show<T: Describable>(item: T) -> Str {
    item.describe()
}

fn log_it<T: Loggable>(item: T) -> Str {
    item.log_msg()
}

fn main() {
    let admin = Admin { base: User { name: "Bob" }, level: 3 }
    assert(show(admin) == "User: Bob", "Describable delegation failed")
    assert(log_it(admin) == "[LOG] Bob", "Loggable delegation failed")
    assert(admin.describe() == "User: Bob", "direct describe failed")
    assert(admin.log_msg() == "[LOG] Bob", "direct log_msg failed")
    print("delegate_multi_trait: all tests passed")
}
