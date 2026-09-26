// Test: delegate inside mod blocks should generate forwarding methods

trait Greetable {
    fn greet(self) -> Str
}

mod animals {
    struct Dog {
        name: Str
    }

    impl Greetable for Dog {
        fn greet(self) -> Str {
            "Woof from ${self.name}"
        }
    }

    struct DogOwner {
        dog: Dog,
        owner_name: Str,
    }

    impl DogOwner {
        delegate dog: Greetable
    }
}

fn greet_thing<T: Greetable>(t: T) -> Str {
    t.greet()
}

fn main() {
    let owner = animals::DogOwner {
        dog: animals::Dog { name: "Rex" },
        owner_name: "Alice",
    }
    // Delegate should forward greet() to the dog field
    assert(greet_thing(owner) == "Woof from Rex", "trait bound dispatch via mod delegate failed")
    assert(owner.greet() == "Woof from Rex", "UFCS via mod delegate failed")
    print("delegate_in_mod: all tests passed")
}
