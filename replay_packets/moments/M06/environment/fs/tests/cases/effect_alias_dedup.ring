effect alias IO = {io, fail<Str>}

fn do_io() with {IO, io} {
    print("hello")
}

fn main() {
    do_io() catch { _ => {} }
    print("effect_alias_dedup: all tests passed")
}
