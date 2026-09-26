# Effect 系统

Ring 的 effect 系统基于 effect row（来自 Koka），通过 evidence passing 编译到 JavaScript。Effect 追踪函数可能执行的副作用，并由类型系统强制执行。

## Effect 种类

| Effect | 描述 | 操作 |
|--------|------|------|
| `io` | I/O 副作用 | `read(path: Str) -> Str`、`write(path: Str, data: Str) -> Unit` |
| `fail<E>` | 可恢复错误 | `raise(error: E) -> Never` |
| `mut<T>` | 可变性追踪 | `mut self` 方法调用、`mut` 函数参数自动注入；Cell 操作 |
| 自定义 | 用户定义 effect | 用户定义的操作 |

### 内置 Effect

`io` 和 `fail` 是内置的——编译器直接理解它们的语义。`mut<T>` 是编译期 marker effect，用于追踪可变性（详见下方 `mut<T>` Marker Effect 章节）。自定义 effect 通过 `effect` 声明引入。

### 自定义 Effect 声明

```ring
effect Logger {
    fn log(msg: Str) -> Unit;
}
```

声明一个 effect 及其操作。操作签名定义参数和返回类型。

### Default Effect Handler

Effect 操作可以带有默认实现（body）。当一个 effect 的所有操作都有默认实现时，可以直接调用操作而无需 `handle...with`，编译器自动注入 evidence。显式 `handle...with` 可覆盖默认实现。

```ring
effect Logger {
    fn log(msg: Str) -> Unit {
        print(msg)   // 默认实现
    }
}

// 可以直接调用，无需 handle...with
fn main() {
    Logger.log("hello")
}

// 显式 handle 覆盖默认
let result = handle {
    Logger.log("hello")
    42
} with {
    Logger.log(msg) => eprintln(msg),
}
```

AST 中 `EffectOpDecl` 的 `body: Expr?` 字段存储默认实现。`body` 为 `none` 时操作无默认 handler，必须通过 `handle...with` 提供。

### Effect Alias

`effect alias` 定义 effect 集合的别名，简化常用 effect 组合的标注：

```ring
effect alias IO = {io, fail<Str>}

// 等价于 fn read_config() -> Config with {io, fail<Str>}
fn read_config() -> Config with IO {
    // ...
}
```

支持泛型参数：

```ring
effect alias Fallible<E> = {fail<E>}
```

特性：
- 编译器执行循环检测，禁止 alias 间的循环引用
- 支持 `pub` 导出，跨模块使用
- 展开发生在类型检查阶段，对 codegen 透明

### `mut<T>` Marker Effect

`mut<T>` 是编译期 marker effect，用于追踪可变操作。零运行时成本。

自动注入时机：
- 调用 `mut self` 方法时，自动注入 `mut<T>`（T 为 receiver 类型）
- 调用带 `mut` 参数的函数时，自动注入对应的 `mut<T>`

```ring
struct Counter { value: Int }

impl Counter {
    fn increment(mut self) {
        self.value = self.value + 1
    }
}

fn main() {
    let mut c = Counter { value: 0 }
    c.increment()  // 自动注入 mut<Counter> effect
}
```

局部变量 mutation 自动消除：当 `mut` 参数为局部变量时，`mut` effect 不会向上传播。例如调用 `push_item(local)` 时若 `local` 是局部绑定的变量，则不产生 `mut` effect。

可通过 `mod requires {}` 限制模块允许的 effect，从而禁止特定类型的 mutation。

## Effect Row

```
EffectRow = { e₁, e₂, ..., eₙ }          (* 封闭 row *)
EffectRow = { e₁, e₂, ..., eₙ, ..α }     (* 开放 row，带尾变量 α *)
```

- **封闭 row**：恰好包含列出的 effect
- **开放 row**：至少包含列出的 effect，其余由尾变量 `α` 捕获

Effect row 附加在函数类型上。一个类型为 `(Int) -> Str / { io }` 的函数执行 `io` effect。类型为 `(Int) -> Int / {}` 的函数是纯函数。

## Effect 传播

Effect 通过表达式自动传播：

| 表达式 | 结果 effect |
|--------|------------|
| 标识符 | `{}` |
| 二元运算 | `ε₁ ∪ ε₂`（操作数的 effect 合并） |
| 函数调用 | `εf ∪ ε_args`（被调函数 + 参数的 effect） |
| 方法调用 | `ε_recv ∪ εm ∪ ε_args` |
| 块 | 所有语句的 effect 顺序合并 |
| Match | 所有分支 effect 的并集 |
| If-else | 所有分支 effect 的并集 |
| Lambda | 捕获在 FnType.effects 中（lambda 本身无 effect） |

### Effect 合并（Row Merge）

```
merge(ε₁, ε₂):
  1. 按 identity 去重（io ~ io, custom(f) ~ custom(f)）
  2. fail<T> ~ fail<U>：在 unification 中统一 T 和 U
  3. 两边都有尾变量时按 row unification 求解
```

## Effect 消除

两种机制从 effect row 中移除 effect：

### `catch` — 错误处理

`catch` 使用 match-arm 风格语法捕获 `fail` effect：

```ring
let x = risky() catch {
    MyError(e) => handle(e),
    OtherError(msg) => default_from(msg),
}
```

`catch` 总是消除 `fail` effect——它是完整的捕获点。catch arms 经过穷尽性检查：如果 arms 未覆盖所有可能的错误类型，编译器报 E0601 错误。

```ring
// 使用通配符处理所有错误
let y = risky() catch {
    SpecificError(e) => recover(e),
    _ => default_value,
}
```

内部用模式匹配分派错误类型。需要部分处理时在 catch 内部 match + re-raise（显式）。

> **注意：** `try` 是保留关键字，使用时产生编译错误（E0101），提示使用 `catch` 替代。

### `handle...with` — Effect Handler

```ring
let result = handle {
    logger.log("hello")
    42
} with {
    Logger.log(msg) => print(msg),
}
```

Handler 拦截 effect 操作。被处理的 effect 从 body 的 effect row 中移除。

## Effect Row Unification

```
unify_effect_rows(ε₁, ε₂):

第 1 步：应用当前替换
  ε₁' = apply_to_effect_row(subst, ε₁)
  ε₂' = apply_to_effect_row(subst, ε₂)

第 2 步：按 identity 匹配 effect
  对 ε₁' 中每个 effect e₁：
    在 ε₂' 中查找匹配的 effect e₂（相同 kind 和自定义名称）
    找到：统一参数，标记为已匹配
    未找到：加入 a_unmatched

  同理处理 ε₂' → b_unmatched

第 3 步：验证未匹配 effect
  如果 a_unmatched 非空且 ε₂' 无尾变量 → Error（纯上下文中不允许的 effect）
  如果 b_unmatched 非空且 ε₁' 无尾变量 → Error

第 4 步：求解尾变量
  两边都有尾变量（α, β）：
    α = β：无约束
    α ≠ β，两边都有未匹配项：
      创建 fresh γ
      绑定 α ↦ { b_unmatched, ..γ }
      绑定 β ↦ { a_unmatched, ..γ }
    α ≠ β，一边无未匹配项：
      将无未匹配项的尾绑定到另一个尾

  一边或两边封闭：
    有未匹配 effect 在封闭侧 → Error
    无未匹配：将开放尾绑定到另一侧的尾
```

## HOF Effect 多态

高阶函数（如 `List.map`、`List.filter`）的回调参数使用 effect row 变量：

```
List.map<T, U, ?ε>: (List<T>, (T) -> U / ?ε) -> List<U> / ?ε
```

effect 尾变量 `?ε` 允许回调具有任意 effect，这些 effect 自动传播到外层调用结果。

## Handler 语义

### Tail-resumptive（非 abort）

```ring
handle { io.read("input.txt") } with {
    io.read(path) => "mocked-data",
}
```

Handler 的返回值作为操作的结果，计算继续。适用于 `io` 和自定义 effect。

### Abort

```ring
handle { fail.raise("error"); 0 } with {
    fail.raise(e) => -1,
}
```

`fail.raise` 具有 abort 语义：handler 的返回值成为整个 `handle` 表达式的结果，原始计算被丢弃。

### 限制

- 不支持 post-resume handler（resume 后继续执行额外代码）
- 需要 delimited continuation 的完整代数 effect 尚未实现

## Evidence Passing 编译模型

Effect 编译为 evidence 参数传递：

1. 每个 effect 对应一个 evidence 参数 `__ring_ev_{effect_name}`
2. Effect 操作编译为 evidence 方法调用：`io.read(x)` → `__ring_ev_io.read(x)`
3. Handler 构造 evidence 对象并传递给 body
4. 参数按 effect 名字母序排列
5. 顶层 `main()` 自动注入真实 evidence（io → fs，fail → throw）

详细翻译规则见 [JS 翻译](codegen.md)。
