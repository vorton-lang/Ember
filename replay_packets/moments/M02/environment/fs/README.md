# Ring

写起来像 Python，编译器看到 Rust 级别的类型和副作用信息。

Ring 把代数 effect system、HM 类型推断和 trait-based 多态塞进一门语法尽量少的语言里。你几乎不写类型标注，但编译器知道每个函数会做 IO、会不会失败、会不会改状态——然后用这些信息帮你优化和检查。

编译器自举完成，用 Ring 自己写的。当前先编译到 JS 跑着，正在做 LLVM native backend。

## Quick Start

```bash
node compiler/dist/main.js run examples/hello.ring    # 跑
node compiler/dist/main.js build examples/hello.ring   # 编译成 JS
node compiler/dist/main.js check examples/hello.ring   # 只做类型检查
cd compiler && npm test                                 # 跑测试
```

只要有 Node.js 就行，没有任何外部依赖。

## 长什么样

### struct + enum + trait，没有 class

```ring
struct Point { x: Float, y: Float }

enum Shape {
    circle(radius: Float),
    rect(width: Float, height: Float),
}

fn area(s: Shape) -> Float {
    match s {
        circle(r)  => 3.14159 * r * r,
        rect(w, h) => w * h,
    }
}

trait Drawable {
    fn draw(self) -> Str
}

impl Drawable for Shape {
    fn draw(self) -> Str {
        match self {
            circle(r)  => "circle(${r})",
            rect(w, h) => "rect(${w}x${h})",
        }
    }
}
```

### Effect System：副作用自动追踪

```ring
// 你不需要写任何 effect 标注
fn load_config(path: Str) -> Config {
    let raw = io.read(path)        // io + fail 自动冒泡
    let data = json.parse(raw)     // fail 自动冒泡
    Config { host: data.host, port: data.port }
}

// 编译器自己推断出完整签名：
// fn load_config(path: Str) -> Config with {io, fail<ParseError>}
```

错误处理用 `catch`，像 match 一样按类型分派：

```ring
let config = load_config(path) catch {
    IoError(e)    => default_config(),
    ParseError(e) => fallback(path),
}
```

测试里想 mock IO？不用框架，handler 直接替换 effect 实现：

```ring
test "config loading" {
    handle {
        let c = load_config("test.toml")
        assert(c.port == 8080, "port check")
    } with {
        io.read(_path) => "{\"host\":\"localhost\",\"port\":8080}",
    }
}
```

### 类型推断：几乎不用写类型

```ring
fn main() {
    let items = [1, 2, 3, 4, 5]
    let doubled = items.map(fn(x) { x * 2 })
    let evens = items.filter(fn(x) { x % 2 == 0 })
    let sum = items.fold(0, fn(acc, x) { acc + x })
    print("sum = ${sum}")
}
```

全靠 HM 推断 + 双向类型推断，lambda 参数的类型从调用上下文推过来。

### Row Polymorphism

```ring
fn greet(person: {name: Str, ..rest}) -> Str {
    "hello, ${person.name}"
}

struct User    { name: Str, age: Int }
struct Company { name: Str, industry: Str }

// 两个都能传——只要有 name 字段就行
greet(User { name: "Alice", age: 30 })
greet(Company { name: "Acme", industry: "Tech" })
```

不需要继承，不需要 interface，结构匹配就行。

### Option 和 fail 的桥接

```ring
fn find_user(id: Int) -> User {
    let maybe_user: User? = db_lookup(id)
    maybe_user.to_fail()    // None → raise，自动冒泡
}

let result = to_result(fn() { find_user(42) })   // fail → Result::err
```

Option 是数据，fail 是计算。`to_fail()` 和 `to_result()` 在两个世界之间切换。

### 可变状态

```ring
fn main() {
    let mut counter = 0
    counter += 1
    counter += 1
    print("${counter}")   // 2

    let mut items = [1, 2, 3]
    items.push(4)           // mut 方法，编译器检查 items 是 let mut
    print("${items.len()}")  // 4
}
```

`let` 不可变，`let mut` 可变。编译器通过 `mut<T>` effect 在类型层追踪可变性。

## 为什么做这个

1. **类型是工具，不是谜题** — 表达力天花板很高（refinement types、dependent types lite），但日常写代码零标注。
2. **副作用可见** — IO、失败、状态修改、异步全在 effect system 里追踪。编译器推断，你不用写。
3. **给 AI 用的** — 函数签名就是完整的行为契约，LLM 看签名就能正确调 API，不用翻文档。

## 编译器

```
源码 (.ring) → Lexer → Parser → AST → Checker (HM + effects) → HIR → Codegen → JavaScript
```

| 组件 | 干什么 |
|------|--------|
| Lexer + Parser | 手写，Pratt parser，语法错误能恢复继续报 |
| Checker | HM 推断 + effect 推断 + trait 解析 + 穷尽性检查 |
| HIR | 每个表达式带推断出的 Type + EffectRow |
| Codegen | 生成可读 JS，effect 走 evidence passing，trait 走 dictionary passing |

编译器自己用 Ring 写（自举），编译成 JS 跑。JS 后端是过渡方案，目标是 LLVM native。

## 有什么

**类型系统**：HM 推断、effect 推断、trait + auto-derive（Eq/Clone/Debug/Ord）、supertrait、关联类型、row polymorphism、穷尽性检查（Maranget 算法）

**Effect system**：代数 effect（tail-resumptive + abort）、effect alias、default handler、`mut<T>` marker effect、`catch` 错误处理

**数据结构**：List / Map / Set / Tuple，下标访问 `list[i]` / `map[key]` / `str[i]`，Option（`T?` 语法）、Result

**模块系统**：多文件编译、pub/use、inline mod（可嵌套）、`super::`/`self::` 路径、`mod requires` capability 限制

**其他**：Iterator/Iterable 协议（自定义迭代器）、`delegate`（trait 委托）、Or-Pattern、字符串插值（支持嵌套）、raw string、`let mut` + compound assign、FFI（extern fn/type）、多错误报告

**工具**：VSCode 语法高亮插件、标准库（io/fs/path/process/str/num/list/map/set/result/iterator）

## 接下来

正在做 LLVM native backend——编译器已能编译为 native 二进制，ownership + Perceus RC（内存管理）正在收口。

再往后：async effect + 结构化并发、refinement types（实验性）、LSP。

## 项目结构

```
Ring-lang/
├── compiler/          编译器源码（.ring），自举
│   └── dist/          编译产出的 JS
├── std/               标准库
├── tests/             E2E 测试
├── examples/          示例
├── editor/vscode/     VSCode 插件
└── docs/design.md     语言设计文档
```

## 反馈

想听的东西：

- Effect system 好不好用？handler 替代 mock/DI 的方式直觉吗？
- 几乎不写类型标注的体验怎么样？推断挂了的时候错误信息有帮助吗？
- 如果你用 AI 写代码，这门语言是不是比 TypeScript 更容易让 LLM 写对？
- 跟你用的语言比，哪些设计有价值，哪些多余？
- 缺什么？
