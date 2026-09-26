// Test: OS API (fs, path, process) via extern fn

fn main() {
    // path operations
    let base = path_basename("foo/bar/test.ring")
    assert(base == "test.ring", "basename")
    let ext = path_extname("test.ring")
    assert(ext == ".ring", "extname")
    let dir = path_dirname("/foo/bar/test.ring")
    assert(dir == "/foo/bar", "dirname")
    let joined = path_join("foo", "bar")
    assert(joined.len() > 0, "join should produce a path")

    // file I/O: write to temp file, read back, delete
    let tmp = path_join(cwd(), ".ring_test_os_api_tmp.txt")
    write_file(tmp, "hello ring")
    assert(file_exists(tmp), "file should exist after write")
    let content = read_file(tmp)
    assert(content == "hello ring", "read back content")
    delete_file(tmp)
    assert(file_exists(tmp) == false, "file should not exist after delete")

    // process
    let working_dir = cwd()
    assert(working_dir.len() > 0, "cwd should not be empty")

    print("os_api_basic: all tests passed")
}
