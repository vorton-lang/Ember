// extern fn with effect annotation
extern fn js_print(msg: Str) -> Unit with {io}

fn main() {
    // Verify compiler accepts effect annotation on extern fn
    print("effect_annotation_extern: passed")
}
