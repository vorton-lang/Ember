import { createRequire as __cr } from "node:module";
const __require = __cr(import.meta.url);
try { Object.assign(globalThis, __require('../llvm-addon/build/Release/llvm_addon.node')); } catch(e) {}
// === Ring-lang Runtime ===
class __EffectAbort {
  constructor(effect, value) {
    this.effect = effect;
    this.value = value;
  }
}

function Cell(value) { return { value }; }
function Cell_get(self, __ring_ev_mut) { return self.value; }
function Cell_set(self, val, __ring_ev_mut) { self.value = val; }
function Cell_update(self, f, __ring_ev_mut) { self.value = f(self.value); }

function __ring_raise_fail(msg) {
  throw new __EffectAbort("fail", msg);
}

function __match_fail(value) {
  throw new Error("Non-exhaustive match: " + JSON.stringify(value));
}

function print(value) {
  console.log(value);
}

function assert(cond, msg) {
  if (!cond) {
    throw new Error("Assertion failed" + (msg ? ": " + msg : ""));
  }
}

function panic(msg) {
  throw new Error("panic: " + msg);
}

function exit(code) {
  process.exit(code);
}

const __ring_ev_io = { read: (p) => __require("fs").readFileSync(p, "utf-8"), write: (p, d) => __require("fs").writeFileSync(p, d, "utf-8") };

function Option_is_some(self) { return self._tag === "some"; }
function Option_is_none(self) { return self._tag === "none"; }
function Option_unwrap_or(self, def) { return self._tag === "some" ? self._0 : def; }
function Option_unwrap(self) { if (self._tag === "some") return self._0; throw new Error("panic: called unwrap on none"); }

function Str_len(self) { return self.length; }
function Str_contains(self, s) { return self.includes(s); }
function Str_starts_with(self, s) { return self.startsWith(s); }
function Str_ends_with(self, s) { return self.endsWith(s); }
function Str_slice(self, start, end) { return self.slice(start, end); }
function Str_trim(self) { return self.trim(); }
function Str_to_upper(self) { return self.toUpperCase(); }
function Str_to_lower(self) { return self.toLowerCase(); }
function Str_replace(self, old_str, new_str) { return self.replaceAll(old_str, new_str); }
function Str_split(self, sep) { return self.split(sep); }
function Str_char_at(self, i) { return i >= 0 && i < self.length ? { _tag: "some", _0: self[i] } : { _tag: "none" }; }
function Str_index_of(self, s) { var i = self.indexOf(s); return i >= 0 ? { _tag: "some", _0: i } : { _tag: "none" }; }

function Str_pad_start(self, length, fill) { return self.padStart(length, fill); }
function Str_pad_end(self, length, fill) { return self.padEnd(length, fill); }
function Str_repeat(self, count) { return self.repeat(count); }
function Str_char_code_at(self, i) { var c = self.charCodeAt(i); return isNaN(c) ? { _tag: "none" } : { _tag: "some", _0: c }; }
function Str_trim_start(self) { return self.trimStart(); }
function Str_trim_end(self) { return self.trimEnd(); }
function Str_is_empty(self) { return self.length === 0; }
function Str_last_index_of(self, s) { var i = self.lastIndexOf(s); return i >= 0 ? { _tag: "some", _0: i } : { _tag: "none" }; }

function Int_to_str(self) { return String(self); }
function Float_to_str(self) { return String(self); }
function parse_int(s) { var n = parseInt(s, 10); return isNaN(n) ? { _tag: "none" } : { _tag: "some", _0: n }; }
function parse_float(s) { var n = parseFloat(s); return isNaN(n) ? { _tag: "none" } : { _tag: "some", _0: n }; }

function List_len(self) { return self.length; }
function List_get(self, i) { return i >= 0 && i < self.length ? { _tag: "some", _0: self[i] } : { _tag: "none" }; }
function List_push(self, x) { self.push(x); }
function List_concat(self, other) { return self.concat(other); }
function List_extend(self, other) { for (var i = 0; i < other.length; i++) self.push(other[i]); }
function List_slice(self, start, end) { return self.slice(start, end); }
function List_reverse(self) { self.reverse(); }
function List_join(self, sep) { return self.join(sep); }
function List_sort(self) { self.sort(function(a, b) { return a < b ? -1 : a > b ? 1 : 0; }); }
function List_sort_by(self, cmp) { self.sort(cmp); }
function List_pop(self) { return self.length > 0 ? { _tag: "some", _0: self.pop() } : { _tag: "none" }; }
function List_shift(self) { return self.length > 0 ? { _tag: "some", _0: self.shift() } : { _tag: "none" }; }
function List_clear(self) { self.length = 0; }
function List_find_index(self, f) { var i = self.findIndex(f); return i >= 0 ? { _tag: "some", _0: i } : { _tag: "none" }; }
function List_set(self, i, v) { self[i] = v; }
function list_clone(l) { return l.slice(); }

function map_new() { return new Map(); }
function map_from(entries) { return new Map(entries); }
function map_clone(m) { return new Map(m); }
function _Map_len(self) { return self.size; }
function _Map_get(self, key) { return self.has(key) ? { _tag: "some", _0: self.get(key) } : { _tag: "none" }; }
function _Map_contains_key(self, key) { return self.has(key); }
function _Map_keys(self) { return Array.from(self.keys()); }
function _Map_values(self) { return Array.from(self.values()); }
function _Map_entries(self) { return Array.from(self.entries()); }
function _Map_insert(self, key, value) { self.set(key, value); }
function _Map_remove(self, key) { self.delete(key); }
function _Map_clear(self) { self.clear(); }

function set_new() { return new Set(); }
function set_from(items) { return new Set(items); }
function set_clone(s) { return new Set(s); }
function _Set_len(self) { return self.size; }
function _Set_to_list(self) { return Array.from(self); }
function _Set_insert(self, x) { for (var __v of self) { if (__ring_deep_eq(__v, x)) return; } self.add(x); }
function _Set_remove(self, x) { for (var __v of self) { if (__ring_deep_eq(__v, x)) { self.delete(__v); return; } } }
function _Set_union(self, other) { var r = new Set(self); for (var __v of other) { if (!__ring_set_has(r, __v)) r.add(__v); } return r; }
function _Set_intersect(self, other) { var r = new Set(); for (var __v of self) { if (__ring_set_has(other, __v)) r.add(__v); } return r; }
function _Set_difference(self, other) { var r = new Set(); for (var __v of self) { if (!__ring_set_has(other, __v)) r.add(__v); } return r; }
function _Set_clear(self) { self.clear(); }

function __ring_deep_eq(a, b) { if (a === b) return true; if (Array.isArray(a) && Array.isArray(b)) return __ring_tuple_eq(a, b); if (typeof a === "object" && a !== null && typeof b === "object" && b !== null) { var ka = Object.keys(a), kb = Object.keys(b); if (ka.length !== kb.length) return false; for (var j = 0; j < ka.length; j++) { if (!__ring_deep_eq(a[ka[j]], b[ka[j]])) return false; } return true; } return false; }
function __ring_tuple_eq(a, b) { if (a.length !== b.length) return false; for (var i = 0; i < a.length; i++) { if (!__ring_deep_eq(a[i], b[i])) return false; } return true; }
function __ring_set_has(s, x) { for (var __v of s) { if (__ring_deep_eq(__v, x)) return true; } return false; }
function __ring_index(arr, i) { if (i < 0 || i >= arr.length) throw new Error("Index out of bounds: " + i + ", length: " + arr.length); return arr[i]; }
function __ring_map_index(map, key) { if (!map.has(key)) throw new Error("Key not found: " + key); return map.get(key); }
function __ring_str_index(s, i) { if (i < 0 || i >= s.length) throw new Error("Index out of bounds: " + i + ", length: " + s.length); return s[i]; }
function string_builder() { return []; }
function StringBuilder_add(self, s) { self.push(s); }
function StringBuilder_line(self, s) { self.push(s); self.push("\n"); }
function StringBuilder_add_int(self, n) { self.push(String(n)); }
function StringBuilder_to_str(self) { return self.join(""); }
function StringBuilder_len(self) { return self.reduce(function(a, b) { return a + b.length; }, 0); }

function json_stringify(value) { return JSON.stringify(value); }

var __fs = __require("fs"), __path = __require("path");
function read_file(p) { return __fs.readFileSync(p, "utf-8"); }
function write_file(p, c) { __fs.writeFileSync(p, c, "utf-8"); }
function file_exists(p) { return __fs.existsSync(p); }
function delete_file(p) { __fs.unlinkSync(p); }
function path_join(a, b) { return __path.join(a, b); }
function path_resolve(p) { return __path.resolve(p); }
function path_dirname(p) { return __path.dirname(p); }
function path_basename(p) { return __path.basename(p); }
function path_extname(p) { return __path.extname(p); }
function argv() { return process.argv.slice(2); }
function exit_process(code) { process.exit(code); }
function eprintln(msg) { process.stderr.write(msg + "\n"); }
function cwd() { return process.cwd(); }

const __Int_Eq = { eq: function(a, b) { return a === b; }, ne: function(a, b) { return a !== b; } };
const __Float_Eq = { eq: function(a, b) { return a === b; }, ne: function(a, b) { return a !== b; } };
const __Str_Eq = { eq: function(a, b) { return a === b; }, ne: function(a, b) { return a !== b; } };
const __Bool_Eq = { eq: function(a, b) { return a === b; }, ne: function(a, b) { return a !== b; } };

function __Option_Eq_eq(a, b, __ring_T_Eq) {
  if (a._tag !== b._tag) return false;
  if (a._tag === "none") return true;
  return __ring_T_Eq.eq(a._0, b._0);
}
const __Option_Eq = { eq: __Option_Eq_eq, ne: function(a, b, __ring_T_Eq) { return !__Option_Eq_eq(a, b, __ring_T_Eq); } };

const __Int_Clone = { clone: function(a) { return a; } };
const __Float_Clone = { clone: function(a) { return a; } };
const __Str_Clone = { clone: function(a) { return a; } };
const __Bool_Clone = { clone: function(a) { return a; } };
const __List_Clone = { clone: function(a) { return a.slice(); } };
const __Map_Clone = { clone: function(a) { return new Map(a); } };
const __Set_Clone = { clone: function(a) { return new Set(a); } };

function __Option_Clone_clone(a, __ring_T_Clone) {
  return a._tag === "some" ? { _tag: "some", _0: __ring_T_Clone.clone(a._0) } : a;
}
const __Option_Clone = { clone: __Option_Clone_clone };

const __Int_Ord = { cmp: function(a, b) { return a < b ? -1 : a > b ? 1 : 0; } };
const __Float_Ord = { cmp: function(a, b) { return a < b ? -1 : a > b ? 1 : 0; } };
const __Str_Ord = { cmp: function(a, b) { return a < b ? -1 : a > b ? 1 : 0; } };
const __Bool_Ord = { cmp: function(a, b) { return a === b ? 0 : a ? 1 : -1; } };

function __Int_Debug_debug(a) { return String(a); }
const __Int_Debug = { debug: __Int_Debug_debug };
function __Float_Debug_debug(a) { return String(a); }
const __Float_Debug = { debug: __Float_Debug_debug };
function __Str_Debug_debug(a) { return '"' + a + '"'; }
const __Str_Debug = { debug: __Str_Debug_debug };
function __Bool_Debug_debug(a) { return String(a); }
const __Bool_Debug = { debug: __Bool_Debug_debug };

function __Option_Debug_debug(a, __ring_T_Debug) {
  return a._tag === "some" ? "some(" + __ring_T_Debug.debug(a._0) + ")" : "none";
}
const __Option_Debug = { debug: __Option_Debug_debug };

function __List_Debug_debug(a, __ring_T_Debug) {
  return "[" + a.map(function(x) { return __ring_T_Debug.debug(x); }).join(", ") + "]";
}
const __List_Debug = { debug: __List_Debug_debug };

function __Map_Debug_debug(a) { return "Map{...}"; }
const __Map_Debug = { debug: __Map_Debug_debug };
function __Set_Debug_debug(a) { return "Set{...}"; }
const __Set_Debug = { debug: __Set_Debug_debug };

function Option_some(_0) { return { _tag: "some", _0 }; }
const Option_none = Object.freeze({ _tag: "none" });




function List_first(self) {
  if (List_is_empty(self)) {
    return Option_none;
  }
  return List_get(self, 0);
}
function List_last(self) {
  if (List_is_empty(self)) {
    return Option_none;
  }
  return List_get(self, (List_len(self) - 1));
}
function List_is_empty(self) {
  return (List_len(self) === 0);
}

class ListIterator {
  constructor(list, index) {
    this.list = list;
    this.index = index;
  }
}

function __ListIterator_Iterator_next(self) {
  if ((self.index < List_len(self.list))) {
    const v = List_get(self.list, self.index);
    self.index = (self.index + 1);
    return v;
  } else {
    return Option_none;
  }
}
const __ListIterator_Iterator = { next: __ListIterator_Iterator_next };

function __List_Iterable_iter(self) {
  return new ListIterator(self, 0);
}
const __List_Iterable = { iter: __List_Iterable_iter };

function List_contains(self, item, __ring_T_Eq) {
  const __ring_iter_0 = __List_Iterable.iter(self);
  while (true) {
    const __ring_next_0 = __ListIterator_Iterator.next(__ring_iter_0);
    if (__ring_next_0._tag === "none") break;
    const x = __ring_next_0._0;
    if (__ring_T_Eq.eq(x, item)) {
      return true;
    }
  }
  return false;
}
function List_index_of(self, item, __ring_T_Eq) {
  let i = 0;
  while ((i < List_len(self))) {
    __ring_match0: {
      const __ring_m0 = List_get(self, i);
      if (__ring_m0._tag === "some") {
        const v = __ring_m0._0;
        if (__ring_T_Eq.eq(v, item)) {
          return Option_some(i);
        }
        break __ring_match0;
      }
      if (__ring_m0._tag === "none") {
        break __ring_match0;
      }
      __match_fail(__ring_m0);
    }
    i = (i + 1);
  }
  return Option_none;
}

class MapIterator {
  constructor(entries, index) {
    this.entries = entries;
    this.index = index;
  }
}

function __MapIterator_Iterator_next(self) {
  if ((self.index < List_len(self.entries))) {
    const v = List_get(self.entries, self.index);
    self.index = (self.index + 1);
    return v;
  } else {
    return Option_none;
  }
}
const __MapIterator_Iterator = { next: __MapIterator_Iterator_next };

function ___Map_Iterable_iter(self) {
  return new MapIterator(_Map_entries(self), 0);
}
const ___Map_Iterable = { iter: ___Map_Iterable_iter };

function _Map_is_empty(self) {
  return (_Map_len(self) === 0);
}

class SetIterator {
  constructor(items, index) {
    this.items = items;
    this.index = index;
  }
}

function __SetIterator_Iterator_next(self) {
  if ((self.index < List_len(self.items))) {
    const v = List_get(self.items, self.index);
    self.index = (self.index + 1);
    return v;
  } else {
    return Option_none;
  }
}
const __SetIterator_Iterator = { next: __SetIterator_Iterator_next };

function ___Set_Iterable_iter(self) {
  return new SetIterator(_Set_to_list(self), 0);
}
const ___Set_Iterable = { iter: ___Set_Iterable_iter };

function _Set_is_empty(self) {
  return (_Set_len(self) === 0);
}

function _Set_contains(self, item, __ring_T_Eq) {
  const items = _Set_to_list(self);
  const __ring_iter_1 = __List_Iterable.iter(items);
  while (true) {
    const __ring_next_1 = __ListIterator_Iterator.next(__ring_iter_1);
    if (__ring_next_1._tag === "none") break;
    const x = __ring_next_1._0;
    if (__ring_T_Eq.eq(x, item)) {
      return true;
    }
  }
  return false;
}
function _Set_has(self, item, __ring_T_Eq) {
  return _Set_contains(self, item, __ring_T_Eq);
}

function Result_Ok(_0) {
  return { _tag: "Ok", _0 };
}
function Result_Err(_0) {
  return { _tag: "Err", _0 };
}

function Result_map(self, f) {
  __ring_match1: {
    const __ring_m1 = self;
    if (__ring_m1._tag === "Ok") {
      const v = __ring_m1._0;
      return Result_Ok(f(v));
      break __ring_match1;
    }
    if (__ring_m1._tag === "Err") {
      const e = __ring_m1._0;
      return Result_Err(e);
      break __ring_match1;
    }
    __match_fail(__ring_m1);
  }
}
function Result_and_then(self, f) {
  __ring_match2: {
    const __ring_m2 = self;
    if (__ring_m2._tag === "Ok") {
      const v = __ring_m2._0;
      return f(v);
      break __ring_match2;
    }
    if (__ring_m2._tag === "Err") {
      const e = __ring_m2._0;
      return Result_Err(e);
      break __ring_match2;
    }
    __match_fail(__ring_m2);
  }
}
function Result_unwrap_or(self, _default) {
  __ring_match3: {
    const __ring_m3 = self;
    if (__ring_m3._tag === "Ok") {
      const v = __ring_m3._0;
      return v;
      break __ring_match3;
    }
    if (__ring_m3._tag === "Err") {
      return _default;
      break __ring_match3;
    }
    __match_fail(__ring_m3);
  }
}
function Result_is_ok(self) {
  __ring_match4: {
    const __ring_m4 = self;
    if (__ring_m4._tag === "Ok") {
      return true;
      break __ring_match4;
    }
    if (__ring_m4._tag === "Err") {
      return false;
      break __ring_match4;
    }
    __match_fail(__ring_m4);
  }
}
function Result_is_err(self) {
  __ring_match5: {
    const __ring_m5 = self;
    if (__ring_m5._tag === "Ok") {
      return false;
      break __ring_match5;
    }
    if (__ring_m5._tag === "Err") {
      return true;
      break __ring_match5;
    }
    __match_fail(__ring_m5);
  }
}

function to_result(f) {
  return (function() { const __ring_ev_fail = { raise: (__ring_err) => { throw new __EffectAbort("fail", __ring_err); } }; try { return Result_Ok(f()); } catch (__ring_e) { if (__ring_e instanceof __EffectAbort && __ring_e.effect === "fail") { const __ring_err = __ring_e.value; if (true) { const e = __ring_err; return Result_Err(e); } else { throw __ring_e; } } throw __ring_e; } })();
}

class Greeting {
  constructor(target, enthusiasm) {
    this.target = target;
    this.enthusiasm = enthusiasm;
  }
}

function greet(g) {
  return `Hello, ${g.target}!`;
}

function main(__ring_ev_io) {
  const g = new Greeting("Ring-lang", 3);
  return print(greet(g), __ring_ev_io);
}

function __StringBuilder_Eq_eq(self, other) {
  return true;
}
const __StringBuilder_Eq = { eq: __StringBuilder_Eq_eq, ne: function(self, other) { return !__StringBuilder_Eq_eq(self, other); } };

function __Greeting_Eq_eq(self, other) {
  return (self.target === other.target) && (self.enthusiasm === other.enthusiasm);
}
const __Greeting_Eq = { eq: __Greeting_Eq_eq, ne: function(self, other) { return !__Greeting_Eq_eq(self, other); } };

function __Result_Eq_eq(self, other, __ring_T_Eq, __ring_E_Eq) {
  if (self._tag !== other._tag) return false;
  switch (self._tag) {
    case "Ok": return __ring_T_Eq.eq(self._0, other._0);
    case "Err": return __ring_E_Eq.eq(self._0, other._0);
    default: return true;
  }
}
const __Result_Eq = { eq: __Result_Eq_eq, ne: function(self, other, __ring_T_Eq, __ring_E_Eq) { return !__Result_Eq_eq(self, other, __ring_T_Eq, __ring_E_Eq); } };

function __SetIterator_Clone_clone(self, __ring_T_Clone) {
  return new SetIterator(__List_Clone.clone(self.items, __ring_T_Clone), self.index);
}
const __SetIterator_Clone = { clone: __SetIterator_Clone_clone };

function __ListIterator_Clone_clone(self, __ring_T_Clone) {
  return new ListIterator(__List_Clone.clone(self.list, __ring_T_Clone), self.index);
}
const __ListIterator_Clone = { clone: __ListIterator_Clone_clone };

function __StringBuilder_Clone_clone(self) {
  return new StringBuilder();
}
const __StringBuilder_Clone = { clone: __StringBuilder_Clone_clone };

function __Greeting_Clone_clone(self) {
  return new Greeting(self.target, self.enthusiasm);
}
const __Greeting_Clone = { clone: __Greeting_Clone_clone };

function __Result_Clone_clone(self, __ring_T_Clone, __ring_E_Clone) {
  switch (self._tag) {
    case "Ok": return Result_Ok(__ring_T_Clone.clone(self._0));
    case "Err": return Result_Err(__ring_E_Clone.clone(self._0));
    default: return self;
  }
}
const __Result_Clone = { clone: __Result_Clone_clone };

function __StringBuilder_Ord_cmp(self, other) {
  return 0;
}
const __StringBuilder_Ord = { cmp: __StringBuilder_Ord_cmp };

function __Greeting_Ord_cmp(self, other) {
  var c;
  c = (self.target < other.target ? -1 : self.target > other.target ? 1 : 0);
  if (c !== 0) return c;
  return (self.enthusiasm < other.enthusiasm ? -1 : self.enthusiasm > other.enthusiasm ? 1 : 0);
}
const __Greeting_Ord = { cmp: __Greeting_Ord_cmp };

const __Result_tag_order = { "Ok": 0, "Err": 1 };
function __Result_Ord_cmp(self, other, __ring_T_Ord, __ring_E_Ord) {
  var t1 = __Result_tag_order[self._tag];
  var t2 = __Result_tag_order[other._tag];
  if (t1 !== t2) return (t1 < t2 ? -1 : 1);
  switch (self._tag) {
    case "Ok": return __ring_T_Ord.cmp(self._0, other._0);
    case "Err": return __ring_E_Ord.cmp(self._0, other._0);
    default: return 0;
  }
}
const __Result_Ord = { cmp: __Result_Ord_cmp };

function __SetIterator_Debug_debug(self, __ring_T_Debug) {
  return "SetIterator { " + "items: " + __List_Debug.debug(self.items, __ring_T_Debug) + ", " + "index: " + String(self.index) + " }";
}
const __SetIterator_Debug = { debug: __SetIterator_Debug_debug };

function __ListIterator_Debug_debug(self, __ring_T_Debug) {
  return "ListIterator { " + "list: " + __List_Debug.debug(self.list, __ring_T_Debug) + ", " + "index: " + String(self.index) + " }";
}
const __ListIterator_Debug = { debug: __ListIterator_Debug_debug };

function __StringBuilder_Debug_debug(self) {
  return "StringBuilder";
}
const __StringBuilder_Debug = { debug: __StringBuilder_Debug_debug };

function __Greeting_Debug_debug(self) {
  return "Greeting { " + "target: " + String(self.target) + ", " + "enthusiasm: " + String(self.enthusiasm) + " }";
}
const __Greeting_Debug = { debug: __Greeting_Debug_debug };

function __Result_Debug_debug(self, __ring_T_Debug, __ring_E_Debug) {
  switch (self._tag) {
    case "Ok": return "Ok(" + __ring_T_Debug.debug(self._0) + ")";
    case "Err": return "Err(" + __ring_E_Debug.debug(self._0) + ")";
    default: return self._tag;
  }
}
const __Result_Debug = { debug: __Result_Debug_debug };

main(__ring_ev_io);