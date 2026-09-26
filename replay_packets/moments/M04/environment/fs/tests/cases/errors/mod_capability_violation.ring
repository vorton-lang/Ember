// expect-error: E0405
mod pure requires {} {
    pub fn bad() -> Unit with {io} {
        print("this should fail")
    }
}
