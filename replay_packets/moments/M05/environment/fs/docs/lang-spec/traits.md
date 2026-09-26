# Trait 系统

Ring 的 trait 系统提供有界多态性（bounded polymorphism），通过 dictionary passing 编译到 JavaScript。

## Trait 声明

```ring
trait Show {
    fn to_str(self: Self) -> Str;
}
```

声明一组类型必须实现的方法。`Self` 类型变量引用实现该 trait 的具体类型。

### EBNF

```
TraitDecl = "trait" IDENT TypeParams? (":" TypeBound ("+" TypeBound)*)? "{" TraitMember* "}"
TraitMember = FnDecl | AssocTypeDecl
AssocTypeDecl = "type" IDENT (":" TypeBound ("+" TypeBound)*)? ("=" TypeExpr)?
```

### 默认方法

```ring
trait Eq {
    fn eq(self: Self, other: Self) -> Bool;
    fn ne(self: Self, other: Self) -> Bool {
        !self.eq(other)
    }
}
```

有函数体的方法提供默认实现。实现类型可以覆盖默认方法，也可以直接使用默认实现。

### Supertrait 继承

```ring
trait Describable {
    fn describe(self) -> Str
}

trait Printable: Describable {
    fn label(self) -> Str
}
```

`trait B: A` 声明 B 的 supertrait 为 A。实现 B 的类型必须同时实现 A，否则报错。

**多级传递**：约束自动沿继承链传递——若 `T: Printable` 且 `Printable: Describable`，则 `T` 隐含 `Describable`，可直接调用 `describe()`。

**默认方法中的 supertrait 访问**：默认方法体可调用 supertrait 的方法。编译器自动为 dictionary 函数注入 supertrait 的 dictionary 参数。

```ring
trait Greeter: Named {
    fn greet(self) -> Str {
        "Hello, ${self.name()}!"  // 调用 supertrait Named 的方法
    }
}
```

**循环检测**：`trait A: B` + `trait B: A` 在声明阶段检测，报 E0501。

**impl 验证**：`impl Printable for Foo` 时若未实现 `Describable for Foo`，报 supertrait 未满足错误。

### 关联类型

```ring
trait Container {
    type Item
    fn get(self) -> Item
}
```

关联类型在 trait 内声明一个类型成员。`Item` 在方法签名中可作为类型使用。

**impl 中赋值**：

```ring
impl Container for IntBox {
    type Item = Int
    fn get(self) -> Int { self.value }
}
```

**限定路径**：泛型函数中通过 `T::Item` 引用关联类型。

```ring
fn use_it<T: Producer>(p: T) -> T::Item {
    p.produce()
}
```

**约束语法**：`<Item = Int>` 约束关联类型的具体值。

```ring
fn sum_source<T: Source<Item = Int>>(s: T) -> Int {
    s.next() + s.next()
}
```

**关联类型 bound**：声明关联类型时可附加 trait 约束。

```ring
trait Container {
    type Item: Eq   // Item 必须实现 Eq
    fn get(self) -> Item
}
```

**默认关联类型**：声明时可提供默认值，impl 可省略或覆盖。

```ring
trait Processor {
    type Output = Int           // 默认为 Int
    fn process(self) -> Output
}

impl Processor for Doubler {    // 使用默认 Output = Int
    fn process(self) -> Int { self.value * 2 }
}

impl Processor for Greeter {    // 覆盖为 Str
    type Output = Str
    fn process(self) -> Str { "Hello, ${self.name}!" }
}
```

**错误码**：

| 错误码 | 含义 |
|--------|------|
| E0510 | 缺少必需的关联类型实现 |
| E0511 | 引用了 trait 中不存在的关联类型 |
| E0512 | 关联类型歧义 |
| E0513 | 关联类型 bound 不满足 |
| E0514 | 出现了意外的关联类型 |

## Impl 块

### 固有方法

```ring
impl Point {
    pub fn distance(self) -> Float { ... }
}
```

为类型定义方法，不依赖任何 trait。通过 UFCS 调用：`point.distance()`。

### Trait 实现

```ring
impl Show for Point {
    fn to_str(self: Self) -> Str {
        "${self.x}, ${self.y}"
    }
}
```

为具体类型实现 trait。必须提供所有无默认实现的抽象方法。缺少必需方法报错。

### 泛型 Impl

```ring
impl<T: Show> Show for List<T> {
    fn to_str(self: Self) -> Str { ... }
}
```

Impl 块可以有自己的类型参数和约束。

## Trait Bound

### 函数约束

```ring
fn stringify<T: Show>(x: T) -> Str {
    x.to_str()
}
```

`T: Show` 约束要求 `T` 实现 `Show` trait。函数体内可调用 `Show` 的方法。

### 多约束

```ring
fn process<T: Show + Eq>(x: T, y: T) -> Bool { ... }
```

`+` 组合多个 trait bound。`T` 必须同时实现 `Show` 和 `Eq`。

### Bound 在 Type Scheme 中的传播

```
TypeScheme = ∀α₁..αₙ. τ [bounds]
bounds = { (α₁, "Show"), (α₂, "Eq"), ... }
```

泛化时 trait bound 从 `var_bounds` 收集并存入 type scheme。实例化时 bound 从旧变量转移到 fresh 变量。

## 方法解析

调用 `x.method()` 时，方法按以下顺序查找：

1. **固有方法**：`impl_methods[type_name]["method"]`
2. **原始类型方法**：Str/Int/Float 的内置方法表
3. **Trait 方法**：搜索所有 `trait_impls`，找到为该类型实现的 trait 中的方法
4. **Dictionary dispatch**：如果 receiver 是类型变量且有 trait bound，通过 dictionary 调用

### 具体类型直接调用

```ring
let p = Point { x: 1, y: 2 }
p.to_str()   // 直接调用 Point_Show_to_str(p)
```

类型已知时，编译器直接选择具体实现。

### 泛型 Dictionary Dispatch

```ring
fn show_it<T: Show>(x: T) -> Str {
    x.to_str()   // 通过 dictionary 调用
}
```

类型变量时，方法调用通过 dictionary 参数间接调用。

## Dictionary Passing 编译模型

### Trait 实现 → Dictionary 对象

```ring
impl Show for Point { fn to_str(self) -> Str { ... } }
```

编译为：

```javascript
function Point_Show_to_str(self) { ... }
const Point_Show = { to_str: Point_Show_to_str };
```

### 泛型函数 → 接收 Dictionary 参数

```ring
fn stringify<T: Show>(x: T) -> Str { x.to_str() }
```

编译为：

```javascript
function stringify(x, __ring_T_Show) {
    return __ring_T_Show.to_str(x);
}
```

### 调用时 → 传递 Dictionary

```ring
stringify(my_point)
```

编译为：

```javascript
stringify(my_point, Point_Show)
```

### Dictionary 转发

泛型函数调用另一个泛型函数时自动传递 dictionary：

```ring
fn show_twice<T: Show>(x: T) -> Str {
    stringify(x) + stringify(x)
}
```

编译为：

```javascript
function show_twice(x, __ring_T_Show) {
    return stringify(x, __ring_T_Show) + stringify(x, __ring_T_Show);
}
```

### 默认方法的 Dictionary 引用

默认方法以独立函数形式存在，dictionary 中通过 wrapper 引用：

```javascript
const Point_Eq = {
    eq: Point_Eq_eq,
    ne: function(other) {
        return __Eq_ne(Point_Eq, other);
    }
};
```

## Delegate（Trait 委托）

`delegate` 在固有 impl 块中使用，将 trait 实现委托给某个字段。编译器自动生成转发方法，替代继承的复用机制。

```ring
struct Admin {
    base: User,
    level: Int,
}

impl Admin {
    delegate base: Describable, Loggable
}
```

`delegate field: Trait1, Trait2` 声明：对于 `Trait1` 和 `Trait2` 的每个方法，生成 `impl Trait for Admin`，方法体转发至 `self.base.method(args...)`。

**语法**：

```
DelegateDecl = "delegate" IDENT ":" IDENT ("," IDENT)*
```

`delegate` 只能出现在固有 `impl Type { ... }` 块中（非 trait impl 块）。

**带参数方法**：自动转发所有参数。

```ring
trait Greeter {
    fn greet(self, greeting: Str) -> Str
}

impl Employee {
    delegate person: Greeter   // 生成 fn greet(self, greeting) { self.person.greet(greeting) }
}
```

**冲突检测**：若类型已有该 trait 的手写 impl，`delegate` 报 E0509。

**错误码**：

| 错误码 | 含义 |
|--------|------|
| E0507 | 委托字段不存在 |
| E0508 | 委托字段类型未实现目标 trait |
| E0509 | 委托与已有 impl 冲突 |

## 自动派生 (Auto-derive)

编译器自动为所有 struct/enum 类型派生可派生的 trait。当前支持的 auto-derive trait：

- **Eq**: 当所有字段都实现 Eq 时自动派生。`==`/`!=` 运算符解糖为 `Eq.eq()` 调用。
- **Clone**: 当所有字段都实现 Clone 时自动派生。
- **Debug**: 当所有字段都实现 Debug 时自动派生。
- **Ord**: 当所有字段都实现 Ord 时自动派生。`<`/`>`/`<=`/`>=` 运算符解糖为 `Ord.cmp()` 调用。

派生使用 fixpoint 迭代算法：从基本类型开始，逐步扩展到包含已派生字段的类型，直到不再有新类型可以派生。

## 限制

- 不支持 `dyn Trait` 动态分发
- 不支持 GATs（Generic Associated Types）
- Trait dictionary dispatch 的 evidence 转发已基本修复（#77），但 delegate 复杂路径仍有低风险残留问题（见 audit-report #93/#123）
