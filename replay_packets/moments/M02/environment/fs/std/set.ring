pub extern type Set<T>

pub extern fn set_new<T>() -> Set<T>
pub extern fn set_from<T>(items: List<T>) -> Set<T>
pub extern fn set_clone<T>(s: Set<T>) -> Set<T>

pub struct SetIterator<T> { pub items: List<T>, pub index: Int }

impl<T> Iterator for SetIterator<T> {
    type Item = T
    fn next(mut self) -> T? {
        if self.index < self.items.len() {
            let v = self.items.get(self.index)
            self.index = self.index + 1
            v
        } else {
            none
        }
    }
}

impl<T> Iterable for Set<T> {
    type Item = T
    type Iter = SetIterator<T>
    fn iter(self) -> SetIterator<T> {
        SetIterator { items: self.to_list(), index: 0 }
    }
}

impl<T> Set {
    pub extern fn len(self: Set<T>) -> Int
    // contains moved to impl<T: Eq> Set below
    pub fn is_empty(self: Set<T>) -> Bool { self.len() == 0 }
    pub extern fn to_list(self: Set<T>) -> List<T>
    pub extern fn insert(self: Set<T>, item: T) -> Unit
    pub extern fn remove(self: Set<T>, item: T) -> Unit
    pub extern fn clear(self: Set<T>) -> Unit
    pub extern fn union(self: Set<T>, other: Set<T>) -> Set<T>
    pub extern fn intersect(self: Set<T>, other: Set<T>) -> Set<T>
    pub extern fn difference(self: Set<T>, other: Set<T>) -> Set<T>
}

impl<T: Eq> Set {
    pub fn contains(self: Set<T>, item: T) -> Bool {
        let items = self.to_list()
        for x in items {
            if x == item { return true }
        }
        false
    }

    pub fn has(self: Set<T>, item: T) -> Bool {
        self.contains(item)
    }
}
