pub extern type List<T>

pub extern fn list_clone<T>(l: List<T>) -> List<T>

impl<T> List {
    pub extern fn len(self: List<T>) -> Int
    pub extern fn get(self: List<T>, index: Int) -> Option<T>
    pub fn first(self: List<T>) -> Option<T> {
        if self.is_empty() { return none }
        self.get(0)
    }
    pub fn last(self: List<T>) -> Option<T> {
        if self.is_empty() { return none }
        self.get(self.len() - 1)
    }
    // contains and index_of moved to impl<T: Eq> List below
    pub fn is_empty(self: List<T>) -> Bool { self.len() == 0 }
    pub extern fn push(self: List<T>, item: T) -> Unit
    pub extern fn pop(self: List<T>) -> Option<T>
    pub extern fn concat(self: List<T>, other: List<T>) -> List<T>
    pub extern fn extend(self: List<T>, other: List<T>) -> Unit
    pub extern fn slice(self: List<T>, start: Int, end: Int) -> List<T>
    pub extern fn reverse(self: List<T>) -> Unit
    pub extern fn join(self: List<T>, separator: Str) -> Str
    pub extern fn sort(self: List<T>) -> Unit
    pub extern fn shift(self: List<T>) -> Option<T>
    pub extern fn clear(self: List<T>) -> Unit
    // index_of moved to impl<T: Eq> List below
    pub extern fn set(self: List<T>, index: Int, value: T) -> Unit
}

pub struct ListIterator<T> { pub list: List<T>, pub index: Int }

impl<T> Iterator for ListIterator<T> {
    type Item = T
    fn next(mut self) -> T? {
        if self.index < self.list.len() {
            let v = self.list.get(self.index)
            self.index = self.index + 1
            v
        } else {
            none
        }
    }
}

impl<T> Iterable for List<T> {
    type Item = T
    type Iter = ListIterator<T>
    fn iter(self) -> ListIterator<T> {
        ListIterator { list: self, index: 0 }
    }
}

impl<T: Eq> List {
    pub fn contains(self: List<T>, item: T) -> Bool {
        for x in self {
            if x == item { return true }
        }
        false
    }

    pub fn index_of(self: List<T>, item: T) -> Option<Int> {
        let mut i = 0
        while i < self.len() {
            match self.get(i) {
                some(v) => if v == item { return some(i) },
                none => {}
            }
            i = i + 1
        }
        none
    }
}
