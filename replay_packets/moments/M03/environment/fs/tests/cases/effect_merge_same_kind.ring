// Test: row_merge unifies type params for same-kind effects
// Previously, fail<Str> and fail<Int> would both appear in merged row
// because effects_same_kind required types_equal for fail.
// After fix, effects_match_kind is used so same-kind effects are
// deduplicated, and their type params are unified.

// A function that may fail with a string error
fn fail_str() -> Int with {fail<Str>} {
    42
}

// A function that catches the fail and produces a value
fn safe_caller() -> Int {
    let result = fail_str() catch {
        e => 0
    }
    result
}

// Test: two branches with same fail type should merge cleanly
fn branch_fail(cond: Bool) -> Int with {fail<Str>} {
    if cond {
        fail_str()
    } else {
        fail_str()
    }
}

fn main() {
    let x = safe_caller()
    assert(x == 42, "safe_caller should return 42")

    let y = branch_fail(true) catch { e => -1 }
    assert(y == 42, "branch_fail true should return 42")

    let z = branch_fail(false) catch { e => -1 }
    assert(z == 42, "branch_fail false should return 42")

    print("effect merge same kind: ok")
}
