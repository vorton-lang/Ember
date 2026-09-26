// Negative test: delegate trait that field type doesn't implement

trait Describable {
    fn describe(self) -> Str
}

struct User {
    name: Str
}

// Note: User does NOT implement Describable

struct Admin {
    base: User,
    level: Int,
}

impl Admin {
    delegate base: Describable
}

fn main() {}
