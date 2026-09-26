// Negative test: delegate with non-existent field

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
    delegate missing_field: Describable
}

fn main() {}
