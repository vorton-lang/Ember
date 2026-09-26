// Test: delegate forwarding with mut self trait methods
trait Counter {
    fn increment(mut self)
    fn count(self) -> Int
}

struct SimpleCounter {
    pub value: Int
}

impl Counter for SimpleCounter {
    fn increment(mut self) {
        self.value = self.value + 1
    }
    fn count(self) -> Int {
        self.value
    }
}

struct WrappedCounter {
    pub inner: SimpleCounter
}

impl WrappedCounter {
    delegate inner: Counter
}

fn main() {
    let mut w = WrappedCounter { inner: SimpleCounter { value: 0 } }
    w.increment()
    w.increment()
    assert(w.count() == 2, "delegate mut self forwarding")
    print("ok")
}
