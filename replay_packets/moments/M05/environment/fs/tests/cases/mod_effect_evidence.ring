// Regression test: mod-qualified effect names must sanitize :: to $
// in evidence_param_name / default_evidence_name to produce valid JS identifiers.
// Without the fix, `const __ring_default_ev_fx::Greeter = ...` is a JS SyntaxError.

mod fx {
    pub effect Greeter {
        fn greet(name: Str) -> Str {
            "Hello, ${name}"
        }
    }

    pub fn use_greeter() -> Str {
        Greeter.greet("World")
    }
}

fn main() {
    let result = fx::use_greeter()
    assert(result == "Hello, World", "default handler should work")
    print("mod effect evidence: ok")
}
