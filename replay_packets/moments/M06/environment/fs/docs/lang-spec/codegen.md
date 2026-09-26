# JS 翻译

Ring 编译到 JavaScript。本文档定义每个 Ring 构造到 JS 的翻译契约。

## 声明翻译

### 函数

```ring
fn add(x: Int, y: Int) -> Int { x + y }
```
```javascript
function add(x, y) { return (x + y); }
```

带 trait bound 时注入 dictionary 参数，带 effect 时注入 evidence 参数。参数顺序：`(原始参数, dictionary 参数, evidence 参数)`。Evidence 参数按 effect 名字母序排列。

```ring
fn process<A: Show>(x: A) -> Str ! io { ... }
```
```javascript
function process(x, __ring_A_Show, __ring_ev_io) { ... }
```

### Struct

```ring
struct Point { x: Int, y: Int }
```
```javascript
class Point {
  constructor(x, y) { this.x = x; this.y = y; }
}
```

字段按声明顺序初始化。

### Enum

**Unit 变体：** 冻结的单例对象。

```ring
enum Color { Red, Green }
```
```javascript
const Color_Red = Object.freeze({ _tag: "Red" });
const Color_Green = Object.freeze({ _tag: "Green" });
```

**位置字段变体：** 工厂函数，字段名为 `_0`、`_1`...

```ring
enum Result<T, E> { Ok(T), Err(E) }
```
```javascript
function Result_Ok(_0) { return { _tag: "Ok", _0 }; }
function Result_Err(_0) { return { _tag: "Err", _0 }; }
```

**命名字段变体：** 工厂函数，使用字段名。

```ring
enum Shape { Circle { radius: Float }, Rect { w: Float, h: Float } }
```
```javascript
function Shape_Circle(radius) { return { _tag: "Circle", radius }; }
function Shape_Rect(w, h) { return { _tag: "Rect", w, h }; }
```

所有变体使用 `_tag` 字段作为判别器（常量 `ENUM_TAG_FIELD`）。

### Trait 实现

```ring
impl Show for Point {
    fn to_str(self: Self) -> Str { "${self.x}, ${self.y}" }
}
```
```javascript
function Point_Show_to_str(self) { return `${self.x}, ${self.y}`; }
const Point_Show = { to_str: Point_Show_to_str };
```

方法命名：`{类型名}_{Trait名}_{方法名}`。Dictionary 命名：`{类型名}_{Trait名}`。

### Effect 声明

Effect 声明不生成任何 JS 代码。Effect 的存在体现在 evidence 参数的注入中。

### Extern 声明

`extern fn` 在单文件模式下不生成代码（假设 JS 函数已在全局存在）。多文件模式下生成别名：

```javascript
const module$fn_name = fn_name;
```

`extern type` 不生成任何代码。

### Test

```ring
test "my test" { assert(1 + 1 == 2, "math works") }
```
```javascript
(function() { assert((1 + 1) === 2, "math works"); })();
```

## 语句翻译

| Ring | JS |
|------|-----|
| `let x = expr` | `const x = expr;` |
| `var x = expr` | `let x = expr;` |
| `x = expr` | `x = expr;` |
| `x += expr` | `x = (x + expr);` |
| `return expr` | `return expr;` |
| `break` | `break;` |
| `continue` | `continue;` |

### Let 解构

```ring
let (a, b) = pair
```
```javascript
const __ring_dt0 = pair;
const a = __ring_dt0[0];
const b = __ring_dt0[1];
```

通配符 `_` 不生成绑定。

### While 循环

```ring
while cond { body }
```
```javascript
while (cond) { body }
```

### For-in 循环

**Range（优化路径）：**

```ring
for i in 0..10 { body }
for i in 0..=10 { body }
```
```javascript
const __ring_end0 = 10;
for (let i = 0; i < __ring_end0; i++) { body }

const __ring_end0 = 10;
for (let i = 0; i <= __ring_end0; i++) { body }
```

**Iterable 协议（通用路径）：**

当迭代对象不是 Range 时，编译器通过 Iterable trait 协议脱糖。内置集合类型（List/Set/Map）以及任何实现了 `Iterable` trait 的自定义类型均适用。

```ring
for x in collection { body }
```
```javascript
const __ring_iter = collection_Iterable.iter(collection);
while (true) {
  const __ring_next = __ring_iter_Iterator.next(__ring_iter);
  if (__ring_next._tag === "none") break;
  const x = __ring_next._0;
  body
}
```

**解构迭代：**

```ring
for (k, v) in entries { body }
```

解构迭代同样通过 Iterable 协议，迭代器 `next()` 返回的值在绑定时解构。

### If-let

```ring
if let some(val) = maybe { use(val) } else { fallback }
```
```javascript
{
  const __ring_t = maybe;
  if (__ring_t._tag === "some") {
    const val = __ring_t._0;
    use(val);
  } else {
    fallback;
  }
}
```

### Match 语句

语句位置的 match 使用 labeled block + break：

```ring
match value {
    0 => print("zero"),
    _ => print("other"),
}
```
```javascript
__ring_match0: {
  const __ring_m0 = value;
  if (__ring_m0 === 0) { print("zero"); break __ring_match0; }
  if (true) { print("other"); break __ring_match0; }
}
```

### If 语句

语句位置的 if 生成 JS if 语句（不包 IIFE）：

```ring
if cond { a } else { b }
```
```javascript
if (cond) { a; } else { b; }
```

## 表达式翻译

### 二元运算符

Ring `==`/`!=` 翻译为 JS `===`/`!==`（严格相等）。其他运算符直接传递。

### Struct 字面量

```ring
Point { x: 1, y: 2 }
```
```javascript
new Point(1, 2)
```

字段按 struct 声明顺序传递给构造函数。

### 字符串插值

```ring
"Hello, ${name}!"
```
```javascript
`Hello, ${name}!`
```

### If 表达式

表达式位置的 if 翻译为三元运算符：

```ring
let x = if cond { a } else { b }
```
```javascript
const x = (cond ? a : b);
```

### Match 表达式

表达式位置的 match 翻译为 IIFE：

```ring
let x = match v { 0 => "zero", _ => "other" }
```
```javascript
const x = (function() {
  const __ring_m = v;
  if (__ring_m === 0) { return "zero"; }
  if (true) { return "other"; }
  __match_fail(__ring_m);
})();
```

**含 `return` 时的临时变量方案：** 当 match 表达式内部包含 `return` 语句时，IIFE 会截获 `return`（return 退出的是 IIFE 而非外层函数）。编译器检测到这种情况后改用临时变量方案：

```javascript
let __ring_blk0;
const __ring_m = v;
if (__ring_m === 0) { __ring_blk0 = "zero"; }
else if (true) { __ring_blk0 = "other"; }
const x = __ring_blk0;
```

### Block 表达式

表达式位置的 block 翻译为 IIFE：

```ring
let x = { let a = 1; a + 2 }
```
```javascript
const x = (function() { const a = 1; return (a + 2); })();
```

语句位置的 block 直接生成 JS 语句（不包 IIFE）。

**含 `return` 时的临时变量方案：** 与 match 表达式同理，当 block 或 if 表达式内部包含 `return` 语句时，编译器改用 `__ring_blkN` 临时变量赋值方案替代 IIFE，避免 IIFE 截获 `return`。无 `return` 的表达式仍使用 IIFE（行为不变）。

### Lambda

```ring
fn(x: Int) -> Int { x + 1 }
```
```javascript
(function(x) { return (x + 1); })
```

Lambda 的 evidence 参数通过 JS 闭包捕获，不在参数列表中声明。

### Catch 表达式

`catch` 使用 match-arm 风格语法，捕获 `fail` effect 并按模式匹配分派错误处理：

```ring
expr catch {
    NotFound(path) => default_value,
    Timeout => retry(),
}
```
```javascript
(function() {
  const __ring_ev_fail = { raise: (__ring_err) => { throw new __EffectAbort("fail", __ring_err); } };
  try {
    return expr;
  } catch (__ring_e) {
    if (__ring_e instanceof __EffectAbort && __ring_e.effect === "fail") {
      const __ring_m = __ring_e.value;
      if (__ring_m._tag === "NotFound") { const path = __ring_m._0; return default_value; }
      if (__ring_m._tag === "Timeout") { return retry(); }
      __match_fail(__ring_m);
    }
    throw __ring_e;
  }
})()
```

`catch` 总是消除 `fail` effect——catch arms 经穷尽性检查（非穷尽报 E0601）。

### Handle 表达式

```ring
handle { io.read("file") } with { io.read(path) => "mocked" }
```
```javascript
(function() {
  const __ring_ev_io = { read: (path) => { return "mocked"; } };
  try { return (function(__ring_ev_io) { return __ring_ev_io.read("file"); })(__ring_ev_io); }
  catch (__ring_e) {
    if (__ring_e instanceof __EffectAbort) return __ring_e.value;
    throw __ring_e;
  }
})()
```

### Effect 操作调用

```ring
io.read(path)
```
```javascript
__ring_ev_io.read(path)
```

### 方法调用

固有方法：`receiver.method(args)` → `Type_method(receiver, args)`

Trait 方法（具体类型）：`receiver.method(args)` → `Type_Trait.method(receiver, args)`

Trait 方法（类型变量）：`receiver.method(args)` → `__ring_T_Trait.method(receiver, args)`

### HOF 内联

List/Map/Set 的高阶方法内联为 JS 原生调用：

```ring
list.map(fn(x) { x * 2 })
```
```javascript
list.map((x) => (x * 2))
```

Evidence 通过闭包捕获。`fold` 的参数顺序翻转（Ring `fold(init, f)` → JS `reduce(f, init)`）。

## 模式编译

### 条件生成

| 模式 | JS 条件 |
|------|---------|
| `_` | `true` |
| `x`（绑定） | `true` |
| `42` | `target === 42` |
| `"hi"` | `target === "hi"` |
| `true` | `target === true` |
| `Some(x)` | `target._tag === "some"` |
| `Ok { value: x }` | `target._tag === "Ok"` |
| `(a, b)` | `Array.isArray(target) && target.length === 2` |

嵌套模式递归生成条件。

### 绑定生成

| 模式 | JS 绑定 |
|------|---------|
| `x` | `const x = target;` |
| `Some(x)` | `const x = target._0;` |
| `Ok { value: x }` | `const x = target.value;` |
| `(a, b)` | `const a = target[0]; const b = target[1];` |

## 运行时

编译器在 JS 输出的开头生成运行时 preamble（除非 `skip_preamble` 选项）：

### 核心

```javascript
class __EffectAbort { constructor(effect, value) { this.effect = effect; this.value = value; } }
function __match_fail(value) { throw new Error("Non-exhaustive match: " + JSON.stringify(value)); }
function print() { console.log(...arguments); }
function assert(cond, msg) { if (!cond) throw new Error("Assertion failed: " + (msg || "")); }
function panic(msg) { throw new Error("panic: " + msg); }
function exit(code) { process.exit(code); }
```

### Cell（可变容器）

```javascript
function Cell(value) { return { value }; }
function Cell_get(self) { return self.value; }
function Cell_set(self, val) { self.value = val; }
function Cell_update(self, f) { self.value = f(self.value); }
```

### 集合辅助函数

Str 16 个、List 10 个、Map 13 个、Set 13 个运行时辅助函数。HOF 方法（map/filter/fold 等）通过内联生成，不在运行时中。

完整列表见[标准库](stdlib.md)。

## 标识符处理

### safe_ident

JS 保留字（`class`、`const`、`new` 等）在作为变量名时加 `_` 前缀：

```ring
let class = 5    →    const _class = 5;
```

### qualify（多文件模式）

顶层声明在多文件模式下加模块前缀：

```
parser 模块中的 parse  →  parser$parse
```

跨模块引用通过 `imports_map` 解析。内置类型和 `extern fn` 不加前缀。

## Main 入口

如果程序定义了 `main()` 函数，编译器在 JS 末尾生成调用：

```javascript
// 无 effect
main();

// 有 effect（io + fail）
const __ring_ev_io = {
  read: (p) => require("fs").readFileSync(p, "utf-8"),
  write: (p, d) => require("fs").writeFileSync(p, d, "utf-8")
};
const __ring_ev_fail = { raise: (error) => { throw error; } };
main(__ring_ev_io, __ring_ev_fail);
```
