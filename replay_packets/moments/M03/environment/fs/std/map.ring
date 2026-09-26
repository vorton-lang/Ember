pub extern type Map<K, V>

pub extern fn map_new<K, V>() -> Map<K, V>
pub extern fn map_from<K, V>(entries: List<(K, V)>) -> Map<K, V>
pub extern fn map_clone<K, V>(m: Map<K, V>) -> Map<K, V>

pub struct MapIterator<K, V> { pub entries: List<(K, V)>, pub index: Int }

impl<K, V> Iterator for MapIterator<K, V> {
    type Item = (K, V)
    fn next(mut self) -> Option<(K, V)> {
        if self.index < self.entries.len() {
            let v = self.entries.get(self.index)
            self.index = self.index + 1
            v
        } else {
            none
        }
    }
}

impl<K, V> Iterable for Map<K, V> {
    type Item = (K, V)
    type Iter = MapIterator<K, V>
    fn iter(self) -> MapIterator<K, V> {
        MapIterator { entries: self.entries(), index: 0 }
    }
}

impl<K, V> Map {
    pub extern fn len(self: Map<K, V>) -> Int
    pub extern fn get(self: Map<K, V>, key: K) -> Option<V>
    pub extern fn contains_key(self: Map<K, V>, key: K) -> Bool
    pub fn is_empty(self: Map<K, V>) -> Bool { self.len() == 0 }
    pub extern fn keys(self: Map<K, V>) -> List<K>
    pub extern fn values(self: Map<K, V>) -> List<V>
    pub extern fn entries(self: Map<K, V>) -> List<(K, V)>
    pub extern fn insert(self: Map<K, V>, key: K, value: V) -> Unit
    pub extern fn remove(self: Map<K, V>, key: K) -> Unit
    pub extern fn clear(self: Map<K, V>) -> Unit
}
