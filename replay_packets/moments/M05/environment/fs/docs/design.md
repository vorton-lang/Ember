# Ring-lang 设计文档

**Rust 的安全性 + Python 的书写体验 + 效果系统让编译器知道一切，然后用这些信息优化性能。**

核心定位（2026-05-24 确定）：

**三支柱**：

1. **推断一切** — 类型 + effect + 可变性 + 所有权，全推断。写代码的体验接近 Python，编译器内部看到完整类型+效果+所有权信息。标注由 formatter 按配置等级自动生成，人只控制详细度。Rust 的安全性不应以标注负担为代价。
2. **追踪一切** — 签名即完整行为契约。函数的副作用（IO、失败、可变、异步）全部由 effect system 在类型层追踪。LLM 和人都能从签名读出全部副作用，无需查看实现。
3. **语义驱动性能** — LLVM 后端 + effect purity / linearity 信息直接转化为编译优化（bounds check 消除、RC 省略、纯函数重排/并行化）。前两个支柱产生的类型信息是优化燃料——这是 C++/Rust 编译器做不到或需要手动标注才能做到的。

**实验赌注**：Refinement types（类型附带值级谓词，Z3 集成编译器）。成了在第三支柱上再加一层（refinement proof → 消除运行时检查，消灭 `unsafe`），不成前三个支柱自洽。

额外目标：让 LLM 也喜欢写这门语言——模块签名信息密度最大化，LLM 在零训练数据的情况下只需签名即可正确使用 API。

## 设计公理

1. **类型即模型，不是谜题** — 类型系统表达力上限很高（refinement types、const generics、GAT），但语法让简单场景零注解，复杂场景读起来像自然语言约束。强力但不鼓励类型体操：类型建模实际问题，不耍杂技。
2. **效果即可见性** — 函数的副作用（IO、失败、可变、异步）全部由 effect system 在类型层追踪。编译器全推断，人通过 IDE 幽灵标注感知冒泡点。只在模块边界处显式声明。
3. **推断为王，标注为仆** — Bidirectional + constraint solving + effect inference。写代码的体验接近 Python，编译器内部看到完整类型+效果信息。标注由 formatter 按配置等级自动生成维护，人只控制详细度。
4. **无人回路** — 语言设计的终极约束：让 LLM agent 能在无人审查的情况下自主编写正确代码。每个语言特性的评估标准之一是"它能替代人类在开发回路中的哪个角色"。编译器不只是检查工具，而是自主开发闭环中替代人类的控制器。

## LLM 友好性设计原则（2026-05-24 确定）

Ring 的核心论点是"类型系统复杂度由 LLM 承担，收益由用户享受"。以下三条原则约束特性设计，防止复杂度超过 LLM 可用的临界点。

**原则 1：借来的语法行为要像原主**

Ring 借用了大量 Rust/TS 语法（struct/enum/trait/impl/match/let mut/pub/mod）。LLM 的训练数据覆盖这些语言，会基于经验预测行为。如果 Ring 的同名语法行为不同，LLM 会产生错误预期。规则：同名语法的语义应尽可能与来源语言一致；有意偏离时，编译器错误信息必须明确指出差异（"Ring 的 mut 参数不是 Rust 的 &mut 借用"）。

**原则 2：编译器错误信息对 LLM 足够友好**

每个新特性的错误码必须有 `--error-format=llm` 格式的修复建议。LLM 不需要"理解"类型理论，只需要跟着编译器指引修。特性交互产生的报错必须可被 LLM 从错误信息推断出修复方式——如果做不到，说明特性交互设计有问题。

**原则 3：高级特性的两条 LLM 路径**

- **自动浮现路径**：LLM 正常写代码 → 编译器报错教它 → LLM 根据错误修复。适用于 linear types（std 类型预标注，编译器报"资源未消耗"）、effect system（自动推断传播，报缺 handler）、associated types（实现 trait 时报缺 `type Item`）。
- **用户触发路径**：用户明确要求 → LLM 查文档学语法 → 写代码。适用于 refinement types（`where` 约束）、GADTs（变体类型约束）、delegate（trait 委托）。

高级特性不能强制渗透到日常代码——不写 refinement/linear/GADT 标注的代码必须照常编译运行。

## 偏好约束（来自用户画像分析）

| 维度 | 倾向 |
|------|------|
| 范式 | 过程式 + 函数式；struct/trait/impl 提供 OOP 常见手感，底层为 typeclass + 组合 |
| 命名 | snake_case，ALL_CAPS 常量 |
| 不可变 | 默认不可变，`let mut` 显式声明可变，`mut` 是唯一的可变性关键字 |
| 错误 | 错误即 effect，自动冒泡；需持久化时物化为 Result 数据 |
| 抽象 | 扁平 > 嵌套，中间变量 > 链式调用 |
| 数据结构 | struct + enum + trait，不造 class 层级 |
| 内存 | Perceus RC（无 GC 无手动管理），当前 JS 后端为 GC |
| 标注 | 工具生成，人控制详细度 |

---

## 1. 类型系统

### 1.1 基础层：ADT + Trait

所有抽象由三种构造完成，无 class、无继承：

```
struct Point { x: Float, y: Float }

enum Shape {
    circle(radius: Float),
    rect(width: Float, height: Float),
    polygon(vertices: List<Point>),
}

fn area(s: Shape) -> Float {
    match s {
        circle(r)    => pi * r * r,
        rect(w, h)   => w * h,
        polygon(vs)  => polygon_area(vs),
    }
}

trait Drawable {
    type Surface
    fn draw(self, target: Surface) -> Unit
}

impl Drawable for Shape {
    type Surface = Canvas
    fn draw(self, target: Canvas) -> Unit {
        match self { ... }
    }
}
```

Trait 泛型约束：

```
fn sort<T: Ord>(list: List<T>) -> List<T> { ... }

fn serialize_sorted<T: Ord + Serialize>(list: List<T>) -> Bytes {
    list.sort().map(to_bytes).concat()
}

trait Collection {
    type Item
    type Iter: Iterator<item = Item>
    fn iter(self) -> Iter
}
```

### 1.1b Union Type（匿名 enum 语法糖，2026-05-25 决策）

`A | B | C` 是匿名 enum 的语法糖。纯编译期展开，不引入子类型，HM 推断不受影响。

```
// 写法
fn process(x: Str | I64) -> Str {
    match x {
        Str(s) => s,
        I64(n) => n.to_str(),
    }
}
process("hello")   // 编译器自动包装为 union 的 Str 分支
process(42)        // 编译器自动包装为 union 的 I64 分支

// 错误组合——核心用例
fn load_config(path: Str) -> Config with {fail<IoError | ParseError>} {
    let raw = read_file(path)        // fail<IoError>，自动包装进 union
    let parsed = parse_json(raw)     // fail<ParseError>，自动包装进 union
    parsed
}
```

**语义规则**：
- `A | B` 展开为编译器生成的匿名 enum，tag + payload 与普通 enum 相同
- 归一化：按类型名字典序排列（`I64 | Str` = `Str | I64` 不成立，canonical form 按名字序）
- 去重：`A | A` = `A`
- 扁平化：`(A | B) | C` = `A | B | C`
- 结构等价：两处写 `Str | I64` 是同一类型
- 调用点隐式包装：传入 `Str` 值到 `Str | I64` 参数时编译器自动插入 enum 构造
- match 使用类型名作为 pattern（具体语法待定，见 backlog）

**不引入的东西**：
- 无子类型关系（`Str` 不是 `Str | I64` 的子类型——是隐式包装，不是子类型）
- 无运行时类型检查（tag 区分，同 enum）
- 无 `Any` 类型

### 1.2 Refinement Types

类型附带谓词，编译器尽力静态检查，无法证明时插入运行时检查：

```
type Positive    = Int where it > 0
type NonEmpty<T> = List<T> where it.len() > 0
type Percentage  = Float where 0.0 <= it <= 100.0
type Email       = Str where it.matches(r"^[^@]+@[^@]+\.[^@]+$")

fn divide(a: Float, b: Float where b != 0.0) -> Float {
    a / b
}

struct Portfolio {
    weights: List<Percentage> where it.sum() == 100.0,
    assets:  NonEmpty<Asset>,
}

let x = 42
divide(1.0, x)      // 编译器证明 42 != 0 ✓

let y = read_input()
divide(1.0, y)      // 编译器插入运行时检查，失败触发 fail effect
```

### 1.3 Const Generics（值参数化类型）

> 原"Dependent Types Lite"（B-003）。2026-05-25 决策：不作为独立特性——其能力 = Const Generics（B-070 起步）+ Refinement predicates on const params（B-001）。不引入"依赖类型"概念——对用户来说就是"带编译期常量参数的泛型 + 约束"。

类型可参数化于编译期常量值，配合 refinement 约束实现维度安全：

```
// 固定长度数组（B-070）
let key: [U8; 32] = [0; 32]

// 等式约束：两个 N 必须相等（HM unification 自然处理）
fn zip<T, U, const N>(a: [T; N], b: [U; N]) -> [(T, U); N] { ... }

// Refinement on const param（B-001 SSA 约束传播）
fn head<T, const N where N > 0>(v: [T; N]) -> T {
    v[0]
}

// 远期：用户自定义类型的 const generics
// struct Mat<const M, const K> { data: [F64; M * K] }
// fn matmul<const M, K, N>(a: Mat<M, K>, b: Mat<K, N>) -> Mat<M, N>
```

### 1.4 Row Polymorphism（语法糖定位，2026-05-25 决策）

结构化多态——函数参数按字段匹配，无需定义 trait。**定位为语法糖**：编译期通过单态化消除，不作为类型系统一等概念。

```
fn greet(person: {name: Str, ..rest}) -> Str {
    "hello, ${person.name}"
}

struct User    { name: Str, age: I64, email: Str }
struct Company { name: Str, industry: Str }

greet(User { ... })       // ✓ 单态化为 greet__User
greet(Company { ... })    // ✓ 单态化为 greet__Company
```

**编译策略**：
- 编译器收集所有调用点的具体类型，为每个生成特化版本（同泛型单态化）
- 如果存在覆盖所需字段的 trait，归化为 trait 约束（trait 归化）
- `RecordType` 不出现在最终类型表示中——编译期消除
- **pub fn 不允许 row poly 参数**——模块边界必须使用具名类型或 trait

**签名显示**（lv2 formatter）：
- 有匹配 trait → 显示 trait 约束：`fn greet<T: Named>(person: T) -> Str`
- 无匹配 trait → 显示具体调用类型的 union：`fn greet(person: User | Company) -> Str`（使用 1.1b union type 语法）
- pub fn → 不适用（已禁止 row poly）

**实现时序**：当前 `RecordType` + row unification 实现保留，LLVM 后端阶段重构为单态化 pass。

### 1.5 错误的生命周期模型

Ring 的错误处理基于一个核心洞察：**错误有生命周期——诞生（raise）、流动（propagate）、有时落地（materialize）。** effect 是错误的运动形态，Result 是错误的静止形态。两者不是竞争关系，是同一个错误在不同阶段的表现。

- **`fail<E>` effect 是主模型** —— 错误默认以 effect 形式存在和流动，零语法自动传播
- **`to_result()` 是"物化"操作** —— 当需要存储、序列化、收集多个错误时，将 effect 转为数据
- **`catch` 是就地恢复** —— 捕获 fail effect 并提供替代值，总是消除 fail effect
- **`Option<T>` 是独立的数据类型** —— 表达"有或没有"，通过 `to_fail()` 进入 effect 世界

```
// Option 是数据类型，T? 是 Option<T> 的糖
enum Option<T> { some(T), none }

struct User {
    name:     Str,
    nickname: Str?,               // 数据层面的"有或没有"
}

// Option → 值：unwrap 方法
let nick = user.nickname.unwrap()              // none → panic
let nick = user.nickname.unwrap_or("匿名")     // none → 默认值
let nick = user.nickname.unwrap_or_else(fn() { compute_default() })

// Option → fail effect：to_fail 方法（从数据进入 effect 世界）
fn get_nickname(user: User) -> Str {
    user.nickname.to_fail()       // none → raise(Unit)，自动冒泡
}

// fail effect → 就地恢复：catch 表达式（总是消除 fail）
let config = load_config(path) catch {
    IoError(e) => default_config(),
    _          => panic("unexpected error"),
}

// fail effect → 物化为数据：to_result（当需要错误作为持久数据时）
let result: Result<Config, Str> = to_result(fn() { load_config(path) })
```

**什么时候用哪个：**

| 场景 | 机制 | 理由 |
|------|------|------|
| 不关心错误，让上层处理 | 零语法（自由传播） | 错误在流动，不需要干预 |
| 在调用点就地恢复 | `catch { ... }` | 错误到此为止，提供替代值 |
| 需要错误作为数据（收集/序列化/测试断言） | `to_result()` | 错误需要落地成持久值 |
| 拦截/替换 effect 实现（mock/DI） | `handle...with` | 不只是错误，是 effect 语义替换 |

设计原则：**错误在 effect 世界诞生和流动（零开销），只在需要持久化时物化为数据。大多数代码不需要物化。**

### 1.6 可变性模型

Ring 的可变性由唯一关键字 `mut` 统一管理。设计原则：**局部 mutation 不是 side effect，共享 mutation 才是。**

**`let` vs `let mut`：**

```
let x = 10                   // 不可变——不可重绑定，不可调用 mut self 方法
let mut counter = 0          // 可变——可重绑定，可调用 mut self 方法

let list = [1, 2, 3]
list.push(4)                 // ERROR — push 是 mut self 方法，需要 let mut
list.len()                   // ok — len 是只读方法

let mut list = [1, 2, 3]
list.push(4)                 // ok
list = [5, 6]                // ok — 重绑定
```

**`mut` 参数——传入可变引用：**

```
fn increment(mut counter: Int) {
    counter = counter + 1    // 直接赋值，修改调用方的变量
}

let mut n = 0
increment(n)                 // 编译器从签名推断需要 box
print(n)                     // 1

// formatter preset "review"+ 自动插入 mut 标记：
increment(mut n)             // 等价写法，可选语法，方便人阅读
```

编译器为 `mut` 参数自动 box（`{ value }` 对象），用户无感。调用方的 `mut` 前缀是**可选标注**——编译器接受两种写法，语义相同。formatter 按配置决定是否插入：`preset = "none"` 省略，`preset = "review"+` 插入（代码审查时副作用可见）。

**`mut self`——可变方法：**

```
impl List<T> {
    fn len(self) -> Int { ... }           // 只读
    fn push(mut self, value: T) { ... }   // 可变——调用方需要 let mut 绑定
    fn clear(mut self) { ... }            // 可变
}
```

**闭包捕获——编译器透明 box：**

```
let mut counter = 0
let inc = fn() { counter = counter + 1 }  // 闭包捕获 mut 绑定
let get = fn() { counter }

inc(); inc(); inc()
get()  // 3
```

编译器检测到 `counter` 被闭包捕获且为 `let mut`，自动 box 为 `{ value: 0 }`。闭包和外层作用域共享同一个 box。用户写的是直觉代码，编译器干脏活。

**Effect 追踪规则：**

| 场景 | 是否 box | `mut<T>` effect | 理由 |
|------|---------|-----------------|------|
| `let mut x` 纯局部使用 | 不 box（JS `let`） | 不出现 | 局部 mutation 不是 side effect |
| `let mut x` 被闭包捕获 | 自动 box | 出现在闭包签名 | 共享 mutation 是 side effect |
| `mut` 参数传递 | 调用方 box | 出现在函数签名 | 修改外部状态是 side effect |
| struct 字段修改（`let mut s; s.f = v`） | 不 box | 不出现 | 局部持有的 struct 修改是局部行为 |

**`mut<T>` 追踪粒度：参数级，非 field 级。** `self.field.push()` 不额外注入 `mut<FieldType>` effect——`push()` 要求 `mut self`，即函数已有 `mut<Self>` effect，field mutation 是其子集。递归追踪 field chain 会产生大量冗余 effect（任何深层字段修改都传播到顶层），信噪比极低。

**不再需要 `Cell<T>` / `Ref<T>` 等包装类型。** 所有可变性通过 `let mut` + `mut` 参数 + 编译器自动 box 处理。词汇量：一个关键字 `mut`。

**闭包内的 `return` 语义**：闭包内的 `return` 返回闭包本身，不影响外层函数。这与 Rust/Kotlin 一致，与 Ruby/Smalltalk 不同。当闭包作为 HOF 回调传入时（如 `list.map(fn(x) { return x * 2 })`），`return` 仅影响该回调。当前编译器通过 IIFE 实现 block expression；当检测到 block/if/match 表达式包含 `return` 时，改用临时变量方案（inline emit + 赋值），避免 IIFE 截获 return（B-022 修复）。

### 1.5 类型系统特性交互矩阵（2026-05-24 确定）

Refinement types、Linear types、Effect system 三个特性单独设计清晰，但组合后存在语义交互。以下为六个交互场景的已确定规则。

#### Refinement × Ownership（正交）

Refinement 是值级谓词——描述值本身的性质（`Int where it > 0`），不引用外部可变状态。Ownership 追踪值的所有者。两者正交。

- 值 move 后，refinement 随值转移到新 owner
- **约束**：refinement 谓词不允许引用可变绑定。`x: Int where x < len` 中 `len` 必须是 `let` 绑定或常量，否则编译错误。这保证谓词在值的整个生命周期内恒成立

#### Refinement × Effect（无冲突）

- **Abort 路径**（`fail.raise`）：refined 值随栈帧一起销毁，无需特殊清理——refinement 是编译期信息，没有运行时资源
- **Tail-resumptive 路径**（io/custom effect）：计算继续，refined 值不受影响
- **Handler resume 值**：handler 提供的恢复值必须满足恢复点的 refinement 约束（编译器检查）

#### Ownership × Effect（RAII / Drop trait）

`impl Drop` 的类型在所有路径自动 drop（RAII）。Rust 风格所有权模型，无 borrow checker。

```
trait Drop {
    fn drop(mut self) with {io}   // 允许 io（flush 等），禁止 fail
}
```

**所有权规则**：
- 所有值 scope 结束自动 drop（正常路径 + abort 路径 + cancel 路径均自动 RAII）
- Move 语义：赋值/传参 = move，move 后原变量不可用
- `impl Drop` 的类型禁止 `impl Clone`（资源不可复制）
- `drop(x)` 提前释放，`leak(x)` 显式逃逸（不触发 Drop）
- `mut self` 方法 = 隐式借用（不消耗所有权）
- 共享访问 → `Rc<T>`，Rc 可 Clone，内部资源 Drop 在 Rc 归零时触发
- 无 `linear` 关键字——`impl Drop` 是唯一的所有权约束入口
- 容器持有 Drop 类型值 → 容器 Drop 自动 drop 所有元素，容器自身不因此获得 Drop 约束
- 无 borrow checker——Ring 用 Perceus RC 代替借用保证内存安全

**不引入 `defer` 关键字**——RAII 覆盖了资源清理的所有场景。`Drop::drop` 禁止 `fail` effect，避免"清理时抛异常"问题。

#### Ownership × async（Move 语义）

`spawn` 闭包捕获 Drop 值 = ownership 转移。原作用域失去访问权（编译错误）。

- 一个 Drop 值不能被两个 `spawn` 闭包同时捕获（违反所有权，编译错误）
- 子任务取消时，被取消的任务走 `Cancelled` fail 路径 → 触发 Drop（同 Ownership × Effect 规则）

#### Refinement × async（成立）

值级谓词不受 await 挂起/恢复影响——`id: Int where id > 0` 在 await 前后恒成立。因为交互 1 已确定 refinement 不引用可变外部状态。

#### 三系统组合（无新规则）

前五个交互规则的自然组合。典型场景：

```
fn safe_write(file: FileHandle, data: Str where data.len() > 0) with {fail<Str>, async} {
    // file: impl Drop → scope 结束自动 close（正常 + abort 均 RAII）
    // data: refined → 保证非空，跨 await 稳定
    let written = await(file.write(data))
    if written == 0 {
        fail.raise("write failed")   // abort → file.drop() 自动触发
    }
    file.close()                      // 也可提前显式消耗
}
```

三系统的类型检查算法各自独立运行，无循环依赖。

#### 扩展交互矩阵（2026-05-24 确定）

以上六个交互覆盖 Refinement × Ownership × Effects 三大支柱。以下为其余重要特性交互的已确定规则。

**GADTs × Or-Pattern（禁止不兼容约束合并）**

Or-pattern 合并的 GADT 变体必须携带兼容的类型等式。`Lit(n) | Add(a,b)` 合法（两者均 T=Int），`Lit(n) | IsZero(e)` 非法（T=Int vs T=Bool 冲突）。编译器在 or-pattern 展开时验证各分支的 GADT 类型约束一致性，不一致则报编译错误。

**Refinement × mut 参数（赋值点重新验证）**

`fn foo(mut x: Int where x > 0)` 的 refinement 必须在每次赋值后重新成立。编译器通过 SSA 约束传播在每个赋值点验证新值满足谓词。这和 refinement 本身的流分析实现是同一层复杂度，不单独拆分。Refinement 的核心价值是使用点的保证，不只是入口检查。

**Auto-Boxing × Linear（透明）**

Auto-boxing（`mut` 参数的 `{value: x}` 包装）是 codegen 实现细节，对 linearity checker 透明。Linearity check 在 HIR 层完成，auto-boxing 在 codegen 层完成，两层不交叉。LLVM 后端 `mut` 参数直接传指针，不需要 boxing。但**被闭包写穿捕获的 `let mut` 局部**（`boxed_vars`，checker 标记 def_id）在 LLVM 后端会 auto-box 成一个单槽堆 cell（`RING_TYPEID_CELL`，`{ ptr value }`），镜像 JS 后端的 `{value: ...}`：外层作用域和闭包 env 共享同一 cell 指针，读/写走 `cell.value`，从而实现写穿（B-091）。Perceus 对 boxed cell 的赋值**不**插入旧值 Drop——写只覆写 `cell.value`，不消费共享的 cell 指针，否则每次写都会 `ring_drop` 一个外层和闭包仍持有的 cell（确定性 UAF）。cell 指针本身按普通 owned 堆值参与 RC（捕获点 dup、作用域末 drop / 工厂场景 move 进闭包）。

**delegate × Associated Types（自动继承）**

delegate 创建完整 trait impl（包含关联类型绑定）。关联类型从 inner 字段的已有 impl 自动推导——`delegate inner: Iterator<Int>` 自动获得 `type Item = Int`。语义确定：delegate = "我就是它"，关联类型必然与 inner 一致。

**Associated Types × Supertrait（自然组合）**

`T: Collection` 蕴含 `T: Iterable`，`T::Item` 等 supertrait 关联类型自动可用。实现时 supertrait bound 展开时带上关联类型即可，无需额外规则。

**GADTs × Effects / delegate × Effects（正交）**

GADT 的 scoped type equality 是编译期 unification，effect evidence 是运行时值传递，两层不交叉。delegate 转发方法时完整复制签名（含 effect 标注），evidence 正常传递。两个交互均不需要特殊规则。

**mut\<T\> × Ownership（隐式借用 + 无 borrow checker）**

`mut self` 方法调用 Drop 值时，语义为隐式借用（不消耗所有权）。Drop 值在 scope 内可通过 `mut self` 被修改，scope 结束时自动 drop（RAII）或提前 `drop(x)` / `x.close()` 显式消耗。Ring 不引入 borrow checker——Perceus RC + Ownership + mut\<T\> + Drop 已覆盖安全性需求（内存安全由 Perceus RC 保证，资源安全由 Ownership + Drop 保证，mutation 追踪由 mut\<T\> effect 保证，数据竞争由结构化并发 + move 语义排除）。不设 borrow checker 的代价是允许可变别名（mutable aliasing），其语义由 Perceus 的 COW 策略决定（见 B-042）。

### 1.7 语义规范（后端无关，2026-05-24 确定）

Ring 语言的语义规范，两个后端都必须符合。LLVM 落地后 JS 后端废弃。

#### 数值类型（2026-05-25 更新）

16 个固定宽度类型，无别名：`I8, I16, I32, I64, I128, U8, U16, U32, U64, U128, F32, F64, ISize, USize`。每个类型名自带宽度信息，拒绝 C 系 `int` 的平台歧义。

**字面量规则**：
- `42` → `I64`，`3.14` → `F64`，永远确定，无歧义
- 无后缀语法（不支持 `42u8`——可由社区反馈驱动后续添加）
- 类型标注窄化：`let x: U8 = 42`（编译期常量折叠 + 范围检查，`256` → 编译错误）
- 方法窄化：`42.to_u8()`（等价于类型标注）
- 运行时窄化：`some_int.to_u8()`（溢出 → fail effect）

**零隐式转换**：
- 不同宽度类型之间无隐式转换（无 widening、无 narrowing）
- `u8_val + i64_val` → 编译错误，要求 `u8_val.to_i64() + i64_val`
- 算术运算只在同类型之间

#### 内存布局（2026-05-24 决策）

默认布局不保证（编译器可重排字段）。`@repr(C)` C 兼容布局（FFI）、`@repr(packed)` 紧凑布局（协议解析）、`@align(N)` 显式对齐。属性标注机制。

#### 运算符重载（2026-05-24 决策）

通过 trait 实现。算术（`Add/Sub/Mul/Div/Rem/Neg`）、比较（`Eq/Ord`，`Ord: Eq`）、位运算（`BitAnd/BitOr/BitXor/BitNot/Shl/Shr`）、索引（`Index/IndexMut`）。不支持跨类型运算。16 个数值类型各自 impl 全套 trait（编译器内置）。

#### 尾调用优化（2026-05-24 决策）

编译器自动检测，无新语法。尾位置 + 无 Drop + 签名匹配 → 保证 TCO（debug/release 都做）。自递归转循环（编译器变换），互递归/间接尾调用用 LLVM `musttail`。间接尾调用模式（tail-call interpreter）自动支持。

| 维度 | Ring 语义 | 备注 |
|------|----------|------|
| **整数范围** | 各类型固定宽度（I64 = ±2^63，I32 = ±2^31 等） | JS 后端 I64 受限于 ±2^53，已知差异 |
| **整数溢出** | Debug panic / Release 二补数回绕 | Rust 模型。JS 后端静默溢出为 float，已知差异 |
| **浮点精度** | F64 = IEEE 754 double，F32 = IEEE 754 single | 两后端一致（JS 后端只有 F64） |
| **字符串编码** | UTF-8 | JS 后端内部 UTF-16，已知差异 |
| **`str[i]`** | 第 i 个 Unicode code point | O(n)，安全访问用 `.get(i)` 返回 `Option`。未来引入 `Char` 类型 |
| **`str.len()`** | Unicode code point 数 | 另提供 `.byte_len()` 返回 UTF-8 字节数 |
| **数组越界** | panic | 安全访问用 `.get(i)` 返回 `Option<T>`。已是当前行为 |
| **整数除零** | panic | JS 后端当前返回 Infinity，需修正 |
| **栈溢出** | 实现定义的 panic 或 abort | LLVM 用 stack guard page，JS 有 RangeError。不保证所有平台均可捕获 |

---

## 2. Effect 系统

代数效果统一所有副作用。

### 2.1 效果声明

```
effect io {
    fn read(path: Str) -> Bytes
    fn write(path: Str, data: Bytes) -> Unit
    fn net_get(url: Str) -> Bytes
}

effect fail<E> {
    fn raise(error: E) -> Never
}

effect async {
    fn spawn<T>(task: fn() -> T) -> Future<T>
    fn await<T>(f: Future<T>) -> T
}

// 当前实现：mut 无类型参数（Cell<T> 泛型保证类型安全）
// Phase 3 目标：mut<S> 参数化 effect
effect mut<S> {
    fn get() -> S
    fn set(new_state: S) -> Unit
}
```

### 2.2 Default Handler（默认处理器）

Effect 的 op 可以带 body，语法与 trait 默认方法一致——有 body = 有默认 handler，无 body = 必须显式 handle：

```
effect Logger {
    fn log(msg: Str) -> Unit {       // 有默认 handler
        print(msg)
    }
}

effect Storage {
    fn read(key: Str) -> Str         // 无默认，必须 handle
    fn write(key: Str, val: Str) -> Unit  // 无默认，必须 handle
    fn log(msg: Str) -> Unit {       // 有默认，可选 handle
        print("storage: ${msg}")
    }
}
```

**语义规则：**

1. **签名透明**：有默认的 effect 仍出现在函数签名中（`fn work() -> Unit with {Logger}`）。"效果即可见性"——默认 handler 消除的是 boilerplate，不是可见性。

2. **部分默认**：`handle...with` 中显式 handle 的 op 覆盖默认，未写的 op 走默认。如果一个 op **没有默认且未 handle → 编译错误**。

3. **全默认可省略 handle**：如果一个 effect 的所有 op 都有默认，调用者可以完全不写 `handle...with`，编译器自动注入默认 evidence。

```
// Logger 全部 op 有默认，无需 handle
fn main() {
    do_work()  // Logger.log 自动走 print(msg)
}

// Storage 部分 op 无默认，只 handle 无默认的
handle {
    work()
} with {
    Storage.read(k) => read_from_disk(k),
    Storage.write(k, v) => write_to_disk(k, v),
    // Storage.log 不写 → 走默认的 print
}
```

**Default handler 的 effect 约束（中间版设计）：**

Default handler body 可以使用：
- 内置 effect（io / fail / mut）
- 已有 default handler 的自定义 effect

不允许使用无默认 handler 的自定义 effect（会产生无法解析的依赖）。编译器对 default handler 间的依赖做拓扑排序，检测循环时报编译错误。

⚠️ 设计已确定（2026-05-22），尚未实现。

### 2.3 Effect 推断

你不写 effect 标注，编译器全推断：

```
// 你写的：
fn load_portfolio(path: Str) -> Portfolio {
    let raw = io.read(path)
    let data = json.parse(raw)
    let weights = validate(data)
    Portfolio { weights, assets: data.assets }
}

// 编译器推断的完整签名（IDE hover 可见）：
// fn load_portfolio(path: Str) -> Portfolio
//     with {io, fail<ParseError | ValidationError>}
```

### 2.4 错误处理——生命周期模型

错误有生命周期：诞生（raise）→ 流动（propagate）→ 落地（materialize 或 catch）。大多数代码只涉及前两个阶段。

**阶段 1：诞生与流动——零语法**

```
fn load_portfolio(path: Str) -> Portfolio {
    let raw = io.read(path)       // io + fail 自动冒泡
    let data = json.parse(raw)    // fail 自动冒泡
    validate(data)                 // fail 自动冒泡
}
```

80% 的错误处理到此结束。函数签名自动推断出 `with {io, fail<...>}`，调用方继续传播。

**阶段 2：就地恢复——`catch` 表达式**

```
let config = load_config(path) catch {
    IoError(e)    => { log(e); default_config() },
    ParseError(e) => fallback(path),
    _             => panic("unexpected"),
}
```

`catch` 总是消除 `fail` effect——它是一个完整捕获点。内部用模式匹配分派不同错误类型。如果需要选择性处理（只处理部分错误、其余继续传播），在 catch 内部 match + re-raise：

```
let config = load_config(path) catch { e =>
    match e {
        IoError(io_err) => default_config(),
        other           => raise(other),    // 显式重新抛出
    }
}
```

这样"部分处理"是显式的（re-raise），而非隐式的（有没有 catch-all arm）。

**阶段 3a：物化为数据——`to_result()`**

当需要错误作为持久数据时（收集多个错误、序列化、测试断言、跨 API 边界传递）：

```
let result: Result<Config, Str> = to_result(fn() { load_config(path) })
match result {
    ok(config) => use_config(config),
    err(e)     => log("failed: ${e}"),
}

// 典型场景：验证收集
let results = fields.map(fn(f) { to_result(fn() { validate_field(f) }) })
let errors = results.filter(fn(r) { r.is_err() })
```

**阶段 3b：effect 替换——`handle...with`（高级）**

用于拦截和替换 effect 实现，不限于错误处理（mock、DI、自定义 effect）：

```
handle {
    let result = complex_pipeline()
    save(result)
} with {
    io => perform,                          // 透传 io
    fail(e: ValidationError) => log_and_skip(e),
}
```

### 2.5 Effect Handler 用于测试 Mock

```
test "load_portfolio parses correctly" {
    let mock_data = r#"{"weights": [25, 25, 25, 25], ...}"#

    handle {
        let p = load_portfolio("fake.json")
        assert(p.weights.len() == 4)
    } with {
        io.read(_path) => mock_data,
        fail(e) => panic("unexpected: ${e}"),
    }
}
```

### 2.6 Effect 多态

当前 handler 支持两种语义：

- **Tail-resumptive**（已实现）：handler 返回值即 resume 值，计算继续。覆盖 mock、adapter、default provider 等场景。
- **Abort**（已实现）：`fail.raise` 专用，handler 替换整个计算结果。

```
// tail-resumptive：handler 返回值替代 io.read 的返回值，计算继续
handle {
    let data = io.read("config.toml")   // → "mock-data"
    "got: ${data}"                       // → "got: mock-data"
} with {
    io.read(path) => "mock-data",
}
```

> **Phase 3 目标：full algebraic effect**（post-resume handler，需要 delimited continuation）：
>
> ```
> // 未实现：handler body 调用 resume 后继续执行额外代码
> fn retry<T, E>(times: Int, action: fn() -> T with {fail<E>}) -> T with {fail<E>} {
>     var attempts = 0
>     loop {
>         handle {
>             return action()
>         } with {
>             fail(e) => {
>                 attempts += 1
>                 if attempts >= times { raise(e) }
>             }
>         }
>     }
> }
> ```

### 2.7 Effect 冒泡可见性

冒泡点是人的需求，不是编译器的需求。由 IDE 层解决：

```
// IDE 模式 A：行尾幽灵文字
let raw = io.read(path)           ░ io, fail<IoError> ░
let data = json.parse(raw)        ░ fail<ParseError> ░

// IDE 模式 B：底色高亮
// 纯表达式 = 无底色
// fail 效果 = 淡黄底色
// io 效果 = 淡蓝底色
// async 效果 = 淡紫底色
```

Formatter 可选将 effect 标注固化为源码注释：

```
//: 前缀注释，formatter 自动维护
let raw = io.read(path)           //: io, fail<IoError>
let data = json.parse(raw)        //: fail<ParseError>
```

---

## 3. 类型推断与标注系统

### 3.1 三层推断

```
// 局部推断
let x = 42                        // Int
let names = ["a", "b", "c"]      // List<Str>

// 双向推断
let f: fn(Int) -> Bool = fn(x) { x > 0 }

// 全局约束求解 + row poly
fn process(items) {
    items.filter(fn(x) { x.age > 18 }).map(fn(x) { x.name })
}
// 推断: items: List<{age: Int, name: Str, ..rest}>
```

**延迟解析（2026-05-24 确定）**：`let x = []` 允许——类型变量延迟到后续 usage 消歧。函数结束时类型变量仍未确定 → 报错（要求标注）。标准 HM unification 天然支持，无需特殊处理。

### 3.2 Formatter：标注密度管理器

Ring 的 formatter 不只是语法格式化工具（缩进/空白/换行），它同时管理**标注密度**——基于编译器的类型推断结果，在源码上增删类型和 effect 标注。源码是规范形式，标注是可增减的文档层。

**核心设计原则：标注是文档，不是语义。** 编译器永远从函数体推断 convention，标注不改变编译行为。标注一致 = 无事；标注缺失/不一致 = warning（从不 error）。lv0 能编译的代码加上任何标注后仍能编译。编译错误只来自逻辑问题（use-after-move、类型不匹配等），不来自标注。

#### 3.2.1 Git 存储模型：lv0 / lv2（2026-05-24 确定）

Ring 采用两级标注模型管理源码的标注密度：

| 等级 | 场景 | 标注密度 | 说明 |
|------|------|----------|------|
| **lv0** | 写时 | 零标注 | 编译器全推断。开发者本地编辑用 |
| **lv2** | Git 存储/推荐 | 完整语义标注 | 所有标注项均为合法可选语法 |

`ring fmt` 将 lv0 自动补全为 lv2，幂等确定性。

**lv2 具体标注内容**：

| 标注项 | lv2 标注 | 说明 |
|--------|:---:|------|
| 函数返回类型 | ✅ | `fn f(...) -> Int` |
| effect row | ✅ | `with {io, fail<E>}` |
| move 参数（声明） | ✅ | `fn f(move x: T)` |
| mut callsite | ✅ | `f(mut list)` |
| 闭包 effect | ✅ | 闭包的 effect 签名 |
| move callsite | ❌ | 编译器 use-after-move 够用，标了噪音大 |
| 局部变量类型 | ❌ | 过于繁琐（与 Rust/TS 一致） |
| borrow 参数 | ❌ | 默认即 borrow，标了是噪音 |
| 泛型实例化类型参数 | ❌ | `Vec.new()` 不写 `::<Int>` |

纯函数省略 `with` = 空 effect。lv2 中纯函数和 lv0 写法相同（无冗余标注）。

**模块边界标注（pub fn/trait/type）**：

| 标注项 | 规则 | 说明 |
|--------|------|------|
| return type | 必须有 | `ring check` 缺失报 warning |
| effect row | 必须有 | 纯函数省略 with = 空 effect |
| move 参数 | 必须有 | 有 move 推断但无标注 → warning |
| mut 参数 | 必须有 | 已有 |
| 泛型约束 | 必须有 | `<T: Ord>` |
| borrow 参数 | 不标注 | 默认 |

**pub fn Formatter 策略**：

| 源码状态 | `ring fmt` | `ring fmt --force` | `ring check` |
|---------|-----------|-------------------|-------------|
| 无标注（新 fn） | 直接补全 | 直接补全 | ⚠ warning "missing" |
| 标注正确 | 无操作 | 无操作 | ✅ |
| 标注 ≠ 推断 | 只报 warning，不改 | 更新标注 | ⚠ warning "stale" |

Breaking change 附加提示（不影响编译，只影响 warning 措辞）：
- borrow → move: ⚠ "breaking: callers' values will be consumed"
- move → borrow: ℹ "non-breaking: callers retain ownership"
- effect 新增: ⚠ "breaking: callers need additional effect"
- effect 减少: ℹ "non-breaking: fewer requirements"

**环境适配**：
- IDE：clean view 写 lv0，保存/提交时 fmt 补全为 lv2
- vim/emacs + LSP：inlay hints + 保存时 fmt
- GitHub 网页端：直接看 lv2（Git 存的就是）
- 纯文本编辑器：文件中是 lv2，手动 `ring fmt` 补全

#### 3.2.2 扩展预设（不同上下文的查看模式）

lv0/lv2 是 Git 存储模型。在此之上，formatter 提供更多预设用于不同查看场景：

配置 `.ringfmt.toml`：

```toml
[annotations]
preset = "api"
# 预设（常用组合的快捷方式）：
#   "none"   = 零标注，只格式化语法
#   "api"    = pub 函数签名（返回类型 + 参数类型 + effect）
#   "review" = 所有函数签名 + 调用点 mut 标记 + 模块 capability
#   "audit"  = review + 调用点 effect 冒泡（//: 注释）+ 复杂表达式中间类型
#   "full"   = 全标注（let 类型、lambda 返回类型、泛型实例化、推断 trait bound）

# 维度开关（覆盖预设的个别维度）：
[annotations.types]
# pub_fn = true         # pub 函数参数 + 返回类型
# internal_fn = false   # 内部函数签名
# lambda_params = false # lambda 参数类型
# lambda_return = false # lambda 返回类型
# let_bindings = false  # let 绑定类型
# generic_instantiation = false  # 泛型实例化参数

[annotations.effects]
# pub_fn = true         # pub 函数 with {...}
# internal_fn = false   # 内部函数 effect 签名
# callsite = false      # 调用点 //: effect 冒泡标注
# module_capability = false  # mod requires {...}

[annotations.mut]
# callsite = false      # 调用点 mut 参数标记：increment(mut n)

[annotations.traits]
# inferred_bounds = false  # 推断的 trait bound
```

预设是常用维度组合的快捷方式，维度开关可覆盖预设中的个别维度。例如 `preset = "review"` 再开 `callsite = true` 只加调用点 effect 标注，不开其他 audit 级内容。

同一份代码在不同等级下的表现：

```ring
// preset = "none" — 零噪音
fn process(items) {
    items.filter(fn(x) { x.age > 18 }).map(fn(x) { x.name })
}

// preset = "review" — code review / 团队协作
fn process(items: List<User>) -> List<Str> with {io} {
    items.filter(fn(x: User) -> Bool { x.age > 18 }).map(fn(x: User) -> Str { x.name })
}

// preset = "audit" — 逐行审查，调用点 effect 可见
fn process(items: List<User>) -> List<Str> with {io} {
    items
        .filter(fn(x: User) -> Bool { x.age > 18 })  //: pure
        .map(fn(x: User) -> Str { x.name })           //: pure
}
```

降级/升级标注只需一个命令：

```bash
ring fmt --preset=full    # code review 时全展开
ring fmt --preset=none    # 日常开发最简洁
ring fmt                  # 使用 .ringfmt.toml 配置
ring fmt --check          # CI 检查：是否符合配置（不修改文件）
```

#### 3.2.3 标注语义：pub 契约 vs. 内部文档

标注在两种位置有不同的语义强度：

| 位置 | 语义 | 编译器行为 | 理由 |
|------|------|-----------|------|
| `pub fn` 签名（返回类型 + effect） | **契约** | 不匹配 = 编译错误 | 调用方依赖此签名，是 API 边界 |
| 内部（let 类型、lambda 参数、局部 fn） | **文档** | 不匹配 = 编译错误 | 引导开发者运行 formatter 刷新 |

两者都在编译时检查，但 formatter 对它们的处理策略不同：

| 标注状态 | 内部标注 | pub 签名标注 |
|----------|---------|-------------|
| 缺失 | 按 level 补上 | 按 level 补上 |
| 正确（匹配推断） | 保持 | 保持 |
| **错误（不匹配推断）** | **直接更新** | **不动，报 warning** |

关键区别：内部标注是 formatter 管辖范围，过期了直接刷新；pub 签名是 API 契约，可能是有意的 breaking change，也可能是无意的 body 改动，formatter 不替人做判断。

#### 3.2.4 工作流

```
编辑代码
  → ring fmt        # 内部标注自动刷新；pub 不一致的报 warning
  → ring check      # pub 标注仍不一致 → 编译错误
  → 人决定是否更新 pub 签名
  → ring fmt        # 确认一致
```

**Intentional breaking change**：改了 pub fn 的 body 后，编译器报"标注 Int，推断 Option\<Int\>"。开发者主动修改标注 → 这个改标注的动作本身就是 breaking change 的显式声明。

**Force mode**（绕过 pub 保护）：`ring fmt --level=0` 去掉所有标注 → `ring fmt --level=N` 重新生成 → pub 签名被重置为推断结果。两步操作 = 显式意图，不需要额外 flag。

**不想管标注的人**：工作在 Level 0，没标注就没不一致的问题。需要时一键 `ring fmt --level=4` 全量生成。

#### 3.2.5 机械约束

三层保证标注与推断的一致性：

**1. 编译器**：标注存在就检查。不匹配 = 编译错误。不区分 pub/内部——统一的信号："标注过期了"。

**2. Formatter 性质**：
- **幂等性**：`fmt(fmt(code)) == fmt(code)` — 格式化两次 = 格式化一次
- **Round-trip**：`fmt(level=0, fmt(level=N, code)) == fmt(level=0, code)` — 升级再降级 = 降级
- **语义不变**：`compile(fmt(level=0, code)) == compile(fmt(level=N, code))` — 任何 level 编译到相同结果
- **规范化**：effect 排序、类型表示、空白 — formatter 输出唯一确定

**3. CI**：`ring fmt --check` 验证文件是否符合配置等级，不符合 → 非零退出码。

#### 3.2.6 架构：Formatter 是 Checker 的下游

Formatter 需要类型推断结果才能生成标注，因此它在编译管线中的位置是 checker 之后：

```
源码 → Parser → AST → Checker → HIR（含完整类型 + effect）
                                   ↓
                             Formatter（读 HIR，按 level 回写标注到源码）
                                   ↓
                             格式化后的源码
```

纯语法格式化（`ring fmt` 不带 `--level`）只需要 AST，不需要 checker。标注密度调整需要 checker 结果。Formatter 与 LSP 共享 checker 基础设施。

```toml
[annotations.effects]
ide_display = "inline"          # inline | gutter | highlight | none
materialize_as = "comment"      # comment | annotation | none
```

---

## 4. 方法调用与 impl 块

### 4.1 UFCS + impl 命名空间

`.method()` 是语法糖，第一个参数即 self。impl 块创建类型关联的命名空间，用于方法解析：

```
impl List<T> {
    fn map<U>(self, f: fn(T) -> U) -> List<U> { ... }
    fn filter(self, pred: fn(T) -> Bool) -> List<T> { ... }
}

impl Tree<T> {
    fn map<U>(self, f: fn(T) -> U) -> Tree<U> { ... }
}

my_list.map(fn(x) { x + 1 })   // 解析到 List.map
my_tree.map(fn(x) { x + 1 })   // 解析到 Tree.map
```

解析优先级：impl 块 > trait 实现 > 作用域内自由函数（UFCS 兜底）。

歧义时显式限定：

```
List.map(my_list, f)
Functor.map(my_tree, f)
```

自由函数仍可用 `.` 调用：

```
fn double(x: Int) -> Int { x * 2 }
42.double()                      // 无 Int.double impl，退到 UFCS
```

链式调用是唯一的方法调用风格——一种事只有一种写法：

```
users.filter(pred).map(f).sort()
```

### 4.2 impl 的定位

impl 不是 OOP——没有继承、没有 vtable、没有 this 指针。self 就是第一个参数，impl 就是给函数挂了个类型标签做查找。

### 4.3 Trait Effect 子类型（2026-05-24 确定）

Trait 方法声明 = effect 上界（契约）。实现可以更窄：

- Implementer 的 effect 可以 ⊆ trait 声明（更窄有效）
- 泛型调用（`S: Storage`）：编译器用 trait 声明的 effect（保守）
- 具体类型调用（已知 `MemoryStorage`）：编译器用 impl 的实际 effect（精确）
- 私有 trait：effect 完全推断（所有 impl 的并集）
- impl effect 超出 trait 声明 → 编译错误

### 4.4 Trait 系统约束（2026-05-24 确定）

Ring 有意选择简单 trait 系统，换取更强推断能力：

- 支持 blanket impl（`impl<T: A> B for T`），不允许 overlap
- 不支持 specialization（blanket impl + 具体类型覆盖）
- 性能特化由编译器单态化 + Phase E 热路径优化替代
- Default 覆盖由 trait 默认方法替代
- 不支持函数重载（破坏 HM principal types）

### 4.5 泛型约束推断（2026-05-24 确定）

所有函数（pub/私有）统一推断泛型约束（类型检查 + lv2 标注）。单态化是 codegen 优化，和类型系统无关。

**推断算法**：方法调用 → 反查提供该方法的 trait → 添加约束。

- 方法名全局唯一时 100% 能推断
- 方法名冲突 = 语义错误（ambiguous method）
- 最小约束 = 只含实际调用方法对应的 trait（不做 supertrait 归并）
- 方法属于具体类型固有方法（非 trait）→ 推断为具体类型参数（非泛型）
- 不需要 `impl Trait` 语法（推断比 impl Trait 更强）

---

## 5. OOP 手感模拟

底层没有 OOP 包袱，但给习惯 OOP 的场景提供等价的人体工学。

### 5.1 Trait 默认方法（"继承"的感觉）

```
trait Describable {
    fn name(self) -> Str
    fn kind(self) -> Str
    fn describe(self) -> Str {
        "${self.kind()}: ${self.name()}"
    }
}

struct User { name: Str, age: Int }

impl Describable for User {
    fn name(self) -> Str { self.name }
    fn kind(self) -> Str { "用户" }
    // describe 自动获得
}
```

### 5.2 Trait 组合（"多继承"无菱形问题）

```
trait Loggable {
    fn log_tag(self) -> Str
    fn log(self, msg: Str) { print("[${self.log_tag()}] ${msg}") }
}

trait Serializable {
    fn to_json(self) -> Str
}

impl Loggable for User {
    fn log_tag(self) -> Str { "User:${self.name}" }
}

impl Serializable for User {
    fn to_json(self) -> Str { ... }
}

// User 现在有 .describe() + .log() + .to_json()
```

### 5.3 委托（替代继承的复用机制）✅ 已实现

```
struct Admin {
    base: User,
    permissions: List<Str>,
}

impl Admin {
    delegate base: Describable, Loggable, Serializable
}

impl Describable for Admin {
    fn kind(self) -> Str { "管理员" }
    // name 和 describe 仍委托到 base
}

admin.describe()    // "管理员: yufeng"
admin.log("login")  // 转发到 User 的 Loggable 实现
```

### 5.4 Row Poly + Trait 交叉

```
fn greet_and_log<T: Loggable>(entity: {name: Str, ..} & T) -> Str {
    entity.log("被打招呼了")
    "你好, ${entity.name}"
}
```

### 5.5 动态分发（opt-in）⚠️ 设计愿景，尚未实现

```
fn process_all(items: List<dyn Describable>) {
    for item in items {
        print(item.describe())     // 动态分发
    }
}

let things: List<dyn Describable> = [user, admin, company]
process_all(things)
```

默认静态分发（泛型单态化），`dyn` 是主动选择运行时多态的标志。

### 5.6 OOP 概念映射表

| OOP 概念 | 本语言等价物 |
|----------|------------|
| class | struct + impl |
| 继承 | delegate + trait 默认方法 |
| 接口 | trait |
| 多态 | 泛型（静态）/ dyn（动态） |
| 鸭子类型 | row polymorphism |
| mixin | 多 trait impl |
| 向下转型 | pattern match on enum |

---

## 6. 模块系统

文件即模块。每个 `.ring` 文件是一个模块，通过 `use` 导入、`pub` 控制可见性。

### 6.1 文件级模块

```
// config.ring
pub struct Config {
    pub db_url: Str,
    pub port:   Int,
}

pub fn load(path: Str) -> Config {
    let raw = io.read(path)
    let table = toml.parse(raw)
    Config {
        db_url: table.get("db_url"),
        port:   table.get_int("port"),
    }
}
```

### 6.2 导入与可见性

```
// main.ring
use config                          // 导入 config.ring

let cfg = config::load("app.toml")

// 可以 pub use 重导出
pub use config
```

`pub` 可见性在多文件模式下强制执行，单文件模式不强制（向后兼容）。

### 6.3 未来方向 ⚠️ 设计愿景，尚未实现

- `sig` 模块签名（OCaml/SML 风格接口）
- 一等模块（模块作为值传递）
- ~~`inline mod` 块~~ ✅ 已实现（`pub mod name { ... }` 嵌套命名空间，声明自动加前缀 `mod_name::decl_name`）
- 相对路径导入（`super::`/`self::`）
- ~~Capability 限制~~ ✅ 已实现（`mod name requires {effects} { ... }` 语法，E0405 检查函数推断 effect 是否在 requires 集合内）

---

## 7. 内存管理与所有权（2026-05-24 确定）

**当前状态**：JS 后端使用 V8 GC，开发者无需关心内存。

**目标方向**：Perceus RC（精确引用计数 + 重用分析），不引入 GC。路线：LLVM 后端初期 malloc-only（bootstrap 阶段），之后过渡到 Perceus RC（B-012）。循环引用策略（B-042）为 Perceus 的前置决策。COW（copy-on-write）为 Perceus 内部优化，不是用户可见语义。

> **历史注记**：早期设计文档曾规划"分代并发 GC"，已被 Perceus RC 方向取代。

### 7.1 所有权模型

- Ownership + move 语义（move 后不可用、Drop 恰好一次）
- 小 struct 自动值语义（栈分配，copy-on-assign），编译器按大小和递归性判断
- 逃逸分析：短命对象不上堆
- 无 borrow checker——Perceus RC + Ownership + `mut<T>` + Drop 覆盖安全性（见 1.5 交互矩阵）
- Mutable aliasing 语义由 Perceus 内部 clone 优化决定（非用户可见 COW 语义）

### 7.2 参数传递：Borrow-by-default

Ring 的参数传递模型：默认只读借用，编译器推断 move，无 lifetime 标注。

| 参数形式 | 语义 | 说明 |
|----------|------|------|
| `x: T` | 只读借用（默认） | 调用方保留所有权，被调用方不能逃逸 |
| `mut x: T` | 可变借用 | 已有语义，不变 |
| `move x: T`（推断） | 移动所有权 | 编译器从函数体推断（参数被返回/存入字段/跨 spawn） |

**设计选择**：无 `&T` 语法，无 lifetime 标注。与 Rust 的核心区别——Ring 用 Perceus RC 代替 borrow checker 保证内存安全。

### 7.3 Move 推断

Move 由编译器从函数体推断，开发者不需要手动标注：

- 参数被返回 → move
- 参数被存入 struct 字段 → move
- 参数跨 `spawn` 闭包边界 → move
- 其他所有情况 → borrow（默认）

推断结果可通过 lv2 标注显式写出（`fn f(move x: T)`），但标注不改变编译行为——标注是文档，不是语义（见 3.2 节标注等级规范）。

### 7.4 逃逸规则

借用值受以下逃逸约束：

- 不能被返回
- 不能存入更长生命周期的位置
- 不能跨 `spawn` 闭包边界

违反逃逸约束 → 编译错误。编译器不需要跨函数逃逸分析——类型系统自动处理传染性（见 7.6 Scoped Struct Borrow）。

### 7.5 赋值语义

| 类型 | 赋值行为 | 说明 |
|------|----------|------|
| 值类型（Int/Float/Bool/Char） | auto copy | 零成本 memcpy |
| 复合类型（List/Map/struct/enum） | move | 保留需显式 `.clone()` |

### 7.6 Scoped Struct Borrow

含借用的类型自动标记为"不可存储"，传参时走 borrow 语义。传染性由类型系统自动处理：

- 含 borrow 字段的 struct → 整个 struct 不可存储（不可返回、不可存入更长 scope）
- 不需要跨函数逃逸分析——struct 的"可存储性"在类型定义时已确定
- 典型用例：Iterator/Parser/Slice 等 "struct 持有引用" 模式可正常使用

### 7.7 函数类型中的 Convention

```ring
fn(T) -> U          // T 为 borrow（默认，与参数 borrow-default 一致）
fn(move T) -> U     // T 为 move（必须手写——唯一不可推断的 move 标注点）
```

大多数回调只读，极少需要 `fn(move T)`。函数类型中的 `move` 标注是唯一一个不可推断、必须显式写出的 move 标注点。

### 7.8 闭包捕获

- 同步闭包捕获借用 → OK（闭包生命周期不超过创建者 scope）
- 逃逸闭包（如 spawn、存入字段）→ 需要 move/clone 捕获
- 具体边界 case 待 B-002 实现阶段验证

### 7.9 Perceus RC + 循环引用策略（2026-05-24 确定）

Ring 采用 Perceus 精确引用计数（B-012），不引入 GC。循环引用通过 `Weak<T>` 库类型解决。

**Perceus RC 路线**：
- LLVM 后端初期：malloc-only（bootstrap 阶段，编译器是短命进程）
- 正式阶段：Perceus RC（精确引用计数 + 重用分析 / reuse analysis）
- COW（copy-on-write）为 Perceus 内部优化，不是用户可见语义

**循环引用策略：`Weak<T>`**

```ring
// Weak<T> 是标准库类型（非关键字）
let parent = Rc.new(Parent { ... })
let child = Child { parent: Rc.downgrade(parent) }

// 使用时升级
match child.parent.upgrade() {
    some(p) => p.name,
    none => "parent already dropped"
}
```

**决策内容**：
- `Weak<T>` 作为标准库类型，配合 `Rc.downgrade()` 和 `.upgrade() -> T?`
- 确定性析构——最后一个强引用 drop 时立即释放，Weak 引用变为 none
- 不引入 cycle collector（破坏 RAII 确定性析构承诺——Drop 延迟 = 资源泄漏风险）
- 不做类型系统禁止循环（GUI/图/观察者模式全部写不了，限制过强）
- 图结构推荐 arena + index 模式（节点存 `List<Node>`，边用 `USize` index 邻接表）

**场景覆盖**：

| 场景 | 解法 |
|------|------|
| GUI 父子组件 | child 持有 `Weak<Parent>` |
| 观察者模式 | listener 持有 `Weak<Emitter>` |
| 双向链表 | prev 用 `Weak<Node>` |
| 图结构 | arena + index（`List<Node>` + `List<USize>` 邻接表） |
| 事件系统 | emitter 持有 `Weak<Listener>` |

**否决方案**：
- Cycle collector：析构不确定，与 Ring 的 Drop/RAII 承诺冲突
- 类型系统禁止循环：限制过强
- 混合方案（Perceus + cycle collector fallback）：两套机制，复杂度高

### 7.10 Perceus 分层实现路线（2026-06-01 确定）

Perceus 天然分层，层次对应依赖链（Koka 自身亦如此演进：先 core dup/drop，再 borrowing，再 reuse）。Ring 切成可独立测试、独立 merge 的序列：

| 层 | 内容 | 作用 | backlog |
|----|------|------|---------|
| **L0 RC 核心** | dup/drop 插入，owned-everywhere，归零即 free | 释放堆内存 → 打破自举内存墙 → 完成全 native 自举 | B-012 |
| **L1 借用推断引擎** | borrow-default + 逃逸点推断 owned；读取默认 borrow、escape-clone、scope-end-drop | 消除 owned-everywhere 的 move-analysis double-free + 泄漏；大幅减 RC 流量 | B-098（引擎）|
| **L1 用户面** | `fn(move T)` 语法、lv2 标注、fmt 策略、pub 规则 | 文档化借用语义（不改编译行为）| B-068（§7.2–7.8，deferred）|
| **L2 Drop/RAII** | 用户 `impl Drop`、全路径 RAII、fail/catch 改 drop-aware unwind、`Weak<T>` | 资源安全 + 循环引用 | B-002 |
| **L3 Reuse (FBIP)** | `rc==1` 时就地改写，drop-reuse 配对、reuse specialization、COW | 性能核爆（函数式零拷贝）| B-079 |
| **L4 Unboxing** | 标量进寄存器不上堆 | 减 alloc + RC 流量 | B-080 |

**关键性质（2026-06-04 订正，#134 证伪原断言）**：原设计假设「L0 owned-everywhere 单独即可解锁全自举，无硬前置」——**错误**。owned-everywhere 对「循环内条件 move」（如 `register_impl_method` 的 `self_type` 在 for 循环里被条件 `push`）是 **double-free（崩溃，非泄漏）**：branch-balancing 给未消费分支强插 `drop`，单值多次 free；Perceus 三套循环机制（pre-loop single-dup / 闭包 per-iteration seeding / branch-balancing）均不覆盖此缝。逐点 always-own sweep 修了 7 处推进 2400×（chk 144→347K）后仍残留同类崩点，本质 = 每个循环/条件 move 需深层 Perceus 手术、站点未知。**结论**：借用推断引擎（L1 的 B-098）被提前到 native-working **之前**——borrow-default 不要求每路径消费 → 未消费分支不再插 spurious drop，从根上消除整类崩溃。L1 用户面（B-068）+ L2 仍是叠加层。

**L0 架构决策**：
- **对象头**：每个堆对象 offset 0 为 `{rc: u32, typeid: u32}`，dup/drop 类型无关（读 `*(u32*)ptr` 加减）。
- **drop dispatch**：per-type drop 函数 + typeid 全局派发表；内建类型 runtime 手写，用户 struct/enum 由 codegen 生成 `drop_T`（Koka 风格 per-type drop/scan）。
- **IR**：HIR 扩展显式 `Drop`/dup 节点（RC 行为可 dump/测试），仅 `--target=llvm` pass 产出，JS 路径跳过。
- **算法**：反向 liveness + branch-balancing，翻译 Koka Perceus（POPL'21）`⟦·⟧`。
- **范围边界**：L0 不处理 abort 路径 drop（longjmp 跳过 = 泄漏，非 UAF，安全；留 L2 drop-aware unwind）；不处理循环引用（树/DAG 自举无环；`Weak<T>` 在 L2）。
- **闭包 capture 所有权（2026-06-03）**：capture 进 env 有两种所有权语义——**owned capture**（gen_lambda 普通闭包；perceus 对 non-last-use 发 dup、last-use move-in，env 死时**该** drop）与 **borrowed capture**（catch/handle 闭包为让分支平衡 `Drop` 能执行而捕入，所有权不在 env，由 arm 内的显式 `Drop` 释放，env 死时**不该** drop）。当前 env struct 复用 closure typeid（7），`drop_closure` 只 drop slot[1] → 捕获 ≥2 时泄漏 + 误递归。落地分两步：**C 增量（#130，B-084）**先给普通闭包 env 独立 typeid + per-env `drop_env_T` 释放 owned captures，catch/handle 闭包显式排除（维持现状泄漏，本就如此，因 `ring_try` 不 drop 闭包）；**A 波（B-096）**再正式建模 borrowed capture（不进 env 或标 no-drop）+ `ring_try` 后 drop body/catch 闭包。差分测试抓 double-free（crash）抓不到泄漏 → owned-capture drop 可验证安全，遗留 catch 泄漏不退化。

**Ring 相对 Koka 的简化**：effect 仅 tail-resumptive + abort（无 multi-resume）→ 无 reified continuation 复制问题，handler 的 RC 退化为普通作用域 backward liveness。

---

## 8. 并发模型 ⚠️ 设计愿景，尚未实现

### 8.1 结构化并发

```
fn fetch_portfolio_data() -> PortfolioData {
    scope {
        let stocks_task = spawn { fetch_stocks() }
        let bonds_task  = spawn { fetch_bonds() }
        let gold_task   = spawn { fetch_gold() }

        PortfolioData {
            stocks: await(stocks_task),
            bonds:  await(bonds_task),
            gold:   await(gold_task),
        }
    }
}
```

### 8.2 async 是 effect，不是颜色

async 和 sync 代码无缝组合。handler 决定执行策略（设计已确定 2026-05-23）：

```
effect async {
    fn spawn<T>(task: fn() -> T with {async}) -> Future<T>
    fn await<T>(f: Future<T>) -> T
}

fn fetch_both() -> (Data, Data) with {async} {
    scope {
        let a = spawn { fetch_stocks() }
        let b = spawn { fetch_bonds() }
        (await(a), await(b))
    }
}

// 生产环境：默认 async handler 驱动
fn main() with {io, async} {
    let result = fetch_both()
    print(result.debug())
}

// 测试环境：sync handler 直接执行
fn test_fetch() {
    let result = handle fetch_both() with {
        async.spawn(task) => task(),
        async.await(f) => f,
    }
    assert(result.0 == expected)
}
```

**实现策略**：Generator-based。async 函数编译为 JS `function*`，handler 作为 driver 驱动 generator。默认 handler 异步驱动（外层 await yield 出的 Promise），自定义 handler 可同步驱动（直接传 mock 值）。模块导出自动包装为 JS `async function`。

**结构化并发**：spawn 必须在 `scope { }` 内。scope 结束等待所有子任务；scope 提前退出取消未完成子任务。

**取消机制**：被取消的任务在下一个 `await` 点收到 `Cancelled` fail effect。两个 await 之间的同步代码一定完整执行。`Cancelled` 可 `catch` 做补偿（如回滚事务）。

### 8.3 Channel 通信

```
fn producer_consumer() with {async} {
    let ch = channel<Int>(buffer: 16)
    scope {
        spawn { for i in 0..100 { ch.send(i) }; ch.close() }
        spawn { for msg in ch { log("received: ${msg}") } }
    }
}
```

---

## 9. GPU 计算与语义级 Profiling ⚠️ 远期愿景

### 9.1 问题空间

GPU profiling 存在根本矛盾：

- **硬件计数器**（NSight Compute / CUPTI）：零扰动，但指标固定不可编程，且需要 kernel replay（同一 kernel 跑多遍收集不同 counter 组）
- **软件插桩**（NVBit 二进制插桩）：可编程，但扰动不可控——额外指令改变 register allocation → occupancy 变化 → 调度行为变化 → profile 数据反映的不是原始 kernel 的行为
- **PC sampling**（CUPTI warp-level）：低扰动，但只有 PC + stall reason，无内存地址、无寄存器值、无源码语义，粒度粗（数千 cycle 采样一次）

核心矛盾：**SIMT 执行模型和细粒度软件插桩天然冲突**。CPU 上插桩开销是加法型（probe 点加几条指令，其余不受影响）；GPU 上是乘法型（extra registers → lower occupancy → 影响所有 warp；extra memory writes → bandwidth 竞争 → 影响所有 warp；条件分支 → warp divergence）。

AI 系统开发者的实际需求：不只是"哪里慢"，而是"attention 的 Q*K matmul 为什么 memory-bound，是 coalescing 问题还是 L2 capacity 不够"——需要源码语义和硬件指标的关联。

### 9.2 Ring 的切入点：编译期语义 × 硬件数据关联

Ring 不在数据采集层和硬件竞争（那是 NVIDIA 的领域），而是在**语义分析层**提供现有工具做不到的能力：

**层 1：编译期标注（零开销）**

编译器从 effect/type 信息自动生成 kernel 的语义 map——哪些代码区间属于哪个 effect scope，每个 scope 的内存访问模式（连续/strided/random），预测的 register pressure 和 occupancy。

```ring
// 编译器知道：
// - matrix_mul 有 gpu_mem effect
// - tile_load 区间做 N 次连续 global_read（可预测 coalescing）
// - compute 区间是纯算术（可预测 ALU-bound）
fn matrix_mul(a: Tensor, b: Tensor) -> Tensor with {gpu_mem} {
    let tile = gpu_mem.shared_alloc(256)    // shared memory 用量可静态算
    gpu_mem.global_read(a.data_ptr())       // 访问模式从类型可推导
    gpu_mem.barrier()
    // ...
}
```

**层 2：硬件计数器自动关联**

编译器生成的语义 map + CUPTI/NSight 收集的硬件计数器数据 → 自动对齐。报告不是 "PC 0x1234 has 80% memory stall"，而是 "attention.Q_K_dot 的 global_read effect memory-bound（L2 miss 40%），建议 tile size 从 256 增加到 512"。

**层 3：编译期性能预测（零运行时开销）**

Ring 的 effect + type 信息足以在编译期预测部分性能特征：
- 内存访问 coalescing（从类型的内存布局 + 循环 stride 推导）
- Shared memory bank conflict（从 shared_alloc 大小 + 访问 pattern 推导）
- Register pressure / occupancy（从 HIR 变量活跃性分析）
- Warp divergence 热点（从分支条件的 thread-dependence 分析）

这类似 NSight Compute 的 occupancy 静态分析，但扩展到更多维度，且带源码语义。

### 9.3 Effect handler 插桩（有扰动，开发/调试用）

对于不要求零扰动的场景（开发阶段调试、功能验证），effect handler composition 仍然有价值：

```ring
// 开发阶段：用 profiling handler 记录完整访问 trace
handle { matrix_mul(a, b) } with {
    gpu_mem.global_read(addr) => {
        trace.record("read", addr)
        cuda_read(addr)
    },
}
```

双版本编译 + warp 级采样可降低扰动：编译器生成生产版和插桩版两个 kernel variant，launch 时混合调度（95% warp 跑生产版，5% 跑插桩版），warp 内部零 divergence。但 register allocation 仍受插桩版影响（occupancy 按较差版本算），扰动不可完全消除。

### 9.4 前置条件

- LLVM 后端可用（NVPTX/AMDGPU target）
- GPU 内存模型作为类型或 effect 建模
- Kernel launch / grid / block 语义
- 栈分配 + 固定大小数组（GPU 无 GC/RC）
- CUPTI 集成（硬件计数器读取）

### 9.5 与竞品的差异化

Rust GPU / Mojo / Futhark 都在做"编译到 GPU"，但没有把 GPU 操作建模为 effect。NSight Compute 有硬件数据但无源码语义。NVBit 有可编程性但扰动大且只有指令级语义。

Ring 的定位：**编译器的语义知识（effect/type）是连接"源码意图"和"硬件行为"的桥梁**。这是第二支柱"追踪一切"和第三支柱"语义驱动性能"在 GPU 领域的自然延伸。

---

## 10. 实现策略：转译到 JavaScript

不自建运行时，站在 V8 的肩膀上。编译器是核心工作，JS 是代码生成目标。

### 9.1 架构

```
源码 → Parser → AST → 类型/Effect 推断 → Typed IR → JS 代码生成 → V8 执行
         ↑                ↑                              ↑
      我们的工作         核心数学            朴素翻译，V8 负责优化
```

性能不是目标——V8 的 JIT 对生成的 JS 代码（函数调用、对象创建、switch 分支）优化足够好，比 Python 快得多。编译速度是硬约束，因为 IDE 耦合的开发循环不能慢。

### 9.2 翻译映射

| 本语言 | 生成的 JS |
|--------|----------|
| struct | class（constructor + 字段） |
| enum | tagged object `{ _tag: "variant", ...fields }` |
| pattern match | switch/if 链 |
| trait + impl | dictionary passing（泛型）/ 直接调用（具体类型） |
| let / var | const / let |
| row poly | 直接属性访问（JS 天然鸭子类型，零翻译成本） |
| fail 冒泡（90%场景） | 直接就是 JS 的正常调用（无额外开销） |
| fail effect | throw / try-catch |
| catch 表达式 | try-catch 包装 |
| 完整 effect handler | evidence passing + EffectAbort try/catch |
| async effect | async/await 透传 |
| refinement 运行时检查 | if (!pred) throw |

### 9.3 Effect handler 的 JS 编码

90% 的 fail 场景特化成 try/catch（零额外成本）。完整 handler 用 evidence passing：

```javascript
// handle { load_config(path) } with { fail(e) => default_config() }
// 编译为：
try {
  load_config(path, __ev_io, { raise: (e) => { throw new __EffectAbort(e); } });
} catch (__e) {
  if (__e instanceof __EffectAbort) { default_config(); }
  else { throw __e; }
}

// 完整 effect handler（测试 mock 等复杂场景）：
// handle { read_config() } with { io.read(path) => "mock-data" }
// 编译为 evidence 对象构造：
const __ev_io = { read: (path) => { throw new __EffectAbort("mock-data"); } };
try {
  read_config(__ev_io);
} catch (__e) {
  if (__e instanceof __EffectAbort) { return __e.value; }
  throw __e;
}
// 函数签名自动注入 evidence 参数：read_config(__ev_io) 而非 generator yield
```

### 9.4 后端策略

**JS 后端定位为 bootstrap 后端**（2026-05-23 决策）：

JS 后端的作用是支撑编译器自举和早期语言开发，不是永久的生产后端。Ring 的语言特性（linear types、Perceus RC、full delimited continuation）在 LLVM 上才能完全发挥。

| 阶段 | JS 后端角色 | 说明 |
|------|------------|------|
| 当前 | 唯一后端 | 编译器自举跑在 Node 上，用户代码编译为 JS 执行 |
| LLVM 打通后 | 编译器运行时 | 编译器仍跑在 Node 上，用户代码可选 native 编译 |
| 编译器 native 化后 | 归档 | 编译器自身迁移到 LLVM native，JS 后端仅保留用于 Web playground（可由 WASM 替代） |

**LLVM 是 Ring 的目标后端**。生态通过 RIIR 策略（逐步用纯 Ring 重写标准库 + 核心库）解决，而非依赖外部包管理生态（npm/crates.io）。C 库通过 FFI 提供底层原语（libcurl、libpq、OpenSSL 等）。

#### LLVM 后端实现策略（2026-05-24 决策，2026-05-28 补充环境）

**环境**：LLVM 22（opaque pointers 唯一选项）+ Windows MSVC + `x86_64-pc-windows-msvc`。N-API addon 放 `compiler/llvm-addon/`（.gitignore）。详细执行计划见 `docs/llvm-migration.md`。

**核心原则：codegen 只写一次。** LLVM codegen 用 Ring 编写，通过 `extern fn` 调用 LLVM-C API。不同运行阶段 `extern fn` 的底层实现不同：

```
Bootstrap 阶段（编译器跑在 JS/V8 上）：
  Ring LLVM codegen ──extern fn──▶ Node N-API addon（thin C++ wrapper）──▶ LLVM-C API

自举完成后（编译器跑在 native 上）：
  Ring LLVM codegen ──extern fn──▶ 直接 C ABI 调用 ──▶ statically linked libLLVM
```

**N-API addon 是一次性本地工具**，不入仓库，不分发。作用仅是让 JS 版编译器能调用 LLVM-C API 产出第一个 native 二进制。自举完成后废弃。

**内存管理**：LLVM 后端初期不回收（malloc only），直接过渡到 Perceus RC（B-012），无中间 GC 方案。编译器是短命进程，不回收不影响正确性。

**值表示**：Uniform boxing——所有 Ring 值在 LLVM 层面统一为 `ptr`（opaque pointer，含 Int/Float/Bool）。极简 codegen，容器天然类型擦除，闭包捕获统一，递归类型自然工作。性能不是 bootstrap 阶段的目标。Perceus RC 阶段再引入 unboxing 优化。

**Runtime**：`ring_runtime.cpp`（~300 行），用 C++ STL 实现核心数据结构，`extern "C"` 暴露给 Ring：
- `List<T>` → `std::vector<void*>`
- `Map<K,V>` → `std::unordered_map<std::string, void*>`（bootstrap 阶段 key 统一为 Str）
- `Set<T>` → `std::unordered_set<std::string>`
- `Str` → `std::string*`
- 零额外依赖（libstdc++ 随 clang 自带）

**闭包**：`{fn_ptr, env_ptr}` 二元组。每个 lambda 生成环境 struct + 带 env 参数的函数。已知函数直接调用不走闭包。Trait dict 中方法为 `RingClosure*`。

**Enum 布局**：`{tag: i64, fields: void*[N]}`（N = 最大变体字段数，内联分配）。Uniform boxing 下递归类型天然工作（字段就是指针）。

**fail/catch 机制**：`setjmp`/`longjmp`。bootstrap 阶段无 Drop/RAII，不需要栈展开。`fail.raise` → evidence 函数内部 `longjmp`；`catch` → `setjmp` + handler 栈。Ownership/RAII 上来后可切换为 C++ exceptions 或自定义 unwind。

**Effect handler（tail-resumptive）**：evidence passing，镜像 JS oracle，与上面的 fail/abort 形成 **hybrid**（2026-06-03 决策）。带 effect 的 fn 签名尾部追加 evidence ptr 参数（`codegen_llvm_decl.ring`），call site `push(lookup_evidence)`（`codegen_llvm_expr.ring`）。evidence = `ring_alloc` 的 N-slot struct，slot k 放第 k 个 op 的 `{fn_ptr, env}` 闭包，**slot 顺序 = op 在 effect 声明里的顺序**——这是 `gen_handle_expr`（构造）与 `gen_effect_op`（派发）之间的跨阶段契约，放共享 helper `effect_op_slot(effect, op)`，性质同 `variant_js_name`。`gen_handle_expr` 造 struct，`gen_effect_op` load slot k 走 `gen_closure_call`。handler 闭包 + evidence struct 的 RC drop 暂泄漏（同 `ring_try` 闭包，纯泄漏非 UAF），收口并入 B-096 A 波。**hybrid 的原则**：fail/abort 绑定是 ambient（栈上随处 catch → handler stack + setjmp），tail-resumptive 绑定是 lexical（类型定向 → evidence value）；两类语义本就不同，且 JS oracle 自身就是此 hybrid（fail=try/catch、tail-resumptive=evidence passing），故 LLVM 镜像它 → parity 结构性。详见 backlog B-090。

**多文件编译**：bootstrap 阶段所有 .ring 文件编译到一个 LLVM Module，输出单个 .o 文件，链接为单一二进制。不需要跨模块符号解析。未来再做增量编译（每个 .ring → 一个 .o）。

**标准库迁移**：以编译器自身迁移为目标驱动，按需将 `extern fn` 从 JS 实现切换到 C ABI 实现。不追求标准库完整迁移——编译器用到什么就迁移什么。

**Bootstrap 路径**：

1. 声明 LLVM FFI 层（`extern fn` + `extern type` 包装 LLVM-C 核心 API，~80 个函数 + ~15 个 extern type）
2. 编写 Ring LLVM codegen 模块（消费 HProgram，调用 LLVM builder API）
3. 本地编译 N-API addon（~300 行 C++，纯机械转发，`compiler/llvm-addon/`）
4. JS 版编译器 + addon → 编译自身为 native 二进制
5. Native 编译器编译自身（验证自举一致性）
6. 废弃 addon + 归档 JS 后端

### 9.5 FFI 设计

当前 FFI（`extern fn` / `extern type`）服务于 JS 后端的标准库实现。LLVM 后端的 FFI 将面向 C ABI。

```ring
// 当前：JS 后端 FFI（标准库内部使用）
pub extern fn read_file(path: Str) -> Str
pub extern type List<T>

// 未来：LLVM 后端 FFI（C ABI）
extern "c" fn fread(ptr: Ptr, size: Int, count: Int, stream: FilePtr) -> Int
```

FFI 边界是 RIIR 的退缩前线——随着更多标准库用纯 Ring 重写，extern fn 数量持续减少。纯 Ring 代码天然跨后端。

---

## 11. LLM 友好性设计

额外设计目标：让 LLM 在零训练数据的情况下，vibe coding 大规模代码库的表现优于 JS/TS。

### 10.1 核心论点

**编译器严格度 = LLM 安全网面积。** 同样的 prompt，TS 编译器放行的代码中藏着运行时炸弹，本语言的编译器在 LLM 提交前就炸出来了。LLM 少的是训练数据，但它多了一个比 TS 严格 10 倍的 pair reviewer。

### 10.2 具体设计决策

**语法借用——最大化知识迁移：**
- `fn`/`let`/`var`/`struct`/`enum`/`match`/`trait`/`impl` 全部来自 Rust
- `"${x}"` 字符串插值来自 JS/Kotlin；多行字符串（`"..."` 允许跨行）；`r"..."` 和 `r#"..."#` raw string（无转义无插值）来自 Rust
- `//` 行注释来自 C/JS/Rust（最大化 LLM 已有知识迁移）
- 不发明新关键字，除非语义确实是新的（如 `handle...with`）

**一种事只有一种写法：** TS 里定义数据结构有 interface/type/class/literal 四种写法，LLM 每次选不同的导致大型代码库风格混乱。本语言只有 `struct`，错误触发只有 `raise`，错误恢复只有 `catch`，effect 替换只有 `handle...with`，异步只有 `spawn/await`，方法调用只有 `.method()` 链式风格（无管道运算符）。LLM 的输出天然一致。错误处理看似有多种机制，但它们对应错误生命周期的不同阶段（流动/恢复/物化/替换），不是同一件事的不同写法。

**模块签名 = LLM 的完美上下文压缩：** LLM 上下文窗口有限。TS 要读完实现才知道函数会抛什么异常；本语言的模块签名包含完整契约（类型+效果），一行顶 TS 几十行，LLM 用更少 token 获得更多 API 信息。

**标注等级匹配 vibe coding 工作流：** LLM 按项目配置的标注等级读写代码，保持认知一致性（读和写的 level 相同，无需在脑子里做 level 转换）。Formatter 规范化输出，编译器验证标注与推断的一致性。

**编译器错误驱动自修正：** 提供 `--error-format=llm` 输出结构化错误，包含可直接复制的修复代码建议：

```json
{
  "error": "refinement_unsatisfied",
  "expected": "Int where 1024 < it < 65536",
  "actual": "Int",
  "fix_hint": "let port = parse_int(raw); if port <= 1024 ... { raise(...) }",
  "alternative": "parse_int(raw) or 8080"
}
```

### 10.3 量化指标

| 指标 | 含义 |
|------|------|
| 首次编译通过率 | 同一 prompt，LLM 生成后首次编译通过的比例 |
| 运行时错误率 | 编译通过后实际运行时出错的比例（本语言应远低于 TS） |
| 自修正轮数 | 首次生成到编译+测试通过的迭代次数 |
| Token 效率 | 完成同一功能的总 token 数（生成+修正） |
| 大库一致性 | 100+ 文件代码库中风格/模式的一致性评分 |

核心赌注：首次编译通过率可能低于 TS（编译器更严格），但运行时错误率和总迭代轮数远低于 TS。

### 10.3.1 代价分配原则

类型系统复杂度增加的是语言的上限，不抬高下限。LLM 友好性的设计分三层：

- **推断能解决的，自动推断**：effect 推断、泛型参数推断。LLM 不需要学，编译器自动处理
- **安全性相关的，编译器强制**：linear types（资源必须消费）、exhaustive match。LLM 不学就编译不过，编译器错误信息就是教程
- **表达力增强的，opt-in**：refinement types、associated types。LLM/用户可以不用，不影响代码正确性；用了可以获得更强的编译期保证

代价分配逻辑：**类型系统的复杂度由 LLM 承担（编译器错误循环迭代），收益由终端用户享受（零 runtime surprise）。** runtime error = 用户介入 = 体验降级；LLM 与编译器搏斗十轮的代价远低于一个 runtime panic 到达用户面前的代价。

### 10.4 控制论视角：无人回路

设计公理 4 的理论根基。当前 LLM 开发工具链（如 Claude Code）中，人类在回路里承担三个控制论角色：

| 角色 | 控制论术语 | 人类做什么 |
|------|-----------|-----------|
| 观测器 | Observer | 看代码对不对、看行为是否符合预期 |
| 判决器 | Controller | approve / reject / 修正方向 |
| 兜底 | Stability guarantee | 系统再怎么跑偏，人最终能拉回来 |

**把人踢出回路，这三个功能不会消失，必须由语言和工具链接管。**

**前馈控制——编译器替代观测器和判决器：**

控制论中前馈控制在错误发生前阻止，反馈控制在错误发生后纠正。Ring 的安全特性本质上是把反馈控制（测试、review、监控）转化为前馈控制（编译时拦截）：

| 语言特性 | 替代人类的哪个判断 |
|----------|------------------|
| Refinement types | "这个参数合法吗？" — 编译器直接拦截非法值 |
| Linear types | "资源释放了吗？" — 编译器保证恰好使用一次 |
| Effect 标注 | "这个函数有副作用吗？" — 签名可见，不需读实现 |
| 穷尽匹配 | "所有 case 都处理了吗？" — 编译器强制穷尽 |
| `--error-format=llm` | "错误信息看懂了吗？" — 结构化输出，LLM 直接消费 |

**每加一个类型安全特性，就是把一个原本需要人当观测器+判决器的场景，交给编译器自动完成。**

**反馈控制——补全编译器覆盖不到的语义正确性：**

前馈控制（编译器）不可能覆盖全部——编译通过 ≠ 语义正确。反馈回路仍然必要：

- **自举 dogfooding**：Ring 编译器用 Ring 写，编译器自身的 bug 是最直接的反馈信号——修类型系统 → 同类 bug 永远消失。这比测试驱动更强，因为修的是约束本身
- **Property-based testing / fuzzing**：编译器保证类型正确，自动测试保证语义正确，两层叠加后 LLM 输出才能不经人审就上线
- **Effect 系统作为可观测性**：副作用被类型追踪后，运行时行为变得可预测，等于自带观测器

**飞轮策略的控制论表述：**

飞轮（见 13.4 节学术验证）用控制论语言重新表述：

> **用类型系统最大化前馈控制的覆盖面，用自动测试补全反馈控制，直到闭环足够紧密，人可以退出回路。**

"安全特性优先于性能特性"的判断等价于：**先把控制器造好，再提升被控对象的性能。** 反过来做（先上 LLVM/JIT 追求性能）等于给一个没有控制器的系统加大油门。

---

## 12. 性能分析与优化策略

Phase 1 全部朴素翻译，不做优化。以下分析各特性的性能瓶颈及编译器侧解法，供 Phase 2+ 按优先级逐个实施。所有优化都在编译器侧完成，不修改运行时。

### 11.1 Effect Handler 的 Generator 开销（影响：最高）

完整 effect handler 用 generator 编码时，每次 yield 涉及帧保存/恢复和堆分配。V8 的 TurboFan 基本不内联 generator 函数，热路径可能慢 10-100x。

**解法：编译期特化 + evidence passing**

编译器静态分析 handler 行为，绝大多数场景消除 generator：

```
-- fail handler 只是捕获 → 特化为 try/catch
handle { load_config(path) } with { fail(e) => default() }
-- 生成: try { load_config(path) } catch(e) { default() }

-- io handler 只是穿透 → 完全消除
handle { pipeline() } with { io => perform }
-- 生成: pipeline()  （无额外代码）

-- 只有 effect 重解释（如测试 mock）才保留完整机制
```

对于无法特化的场景，采用 evidence passing（Koka 论文的核心优化）——handler 引用作为隐藏参数传递，effect 操作变成直接调用：

```javascript
// evidence passing 风格的 JS 输出
function load_config(path, __ring_ev_io, __ring_ev_fail) {
    const raw = __ring_ev_io.read(path);
    const data = __ring_ev_fail.try_(() => json_parse(raw));
    return data;
}
// 零 generator，零 yield，只是函数调用 + 间接引用
// V8 的 inline cache 可以优化间接调用
```

### 11.2 不可变数据的拷贝开销（影响：高）

函数式风格下 filter/map/spread 每次创建新对象，大集合或深嵌套结构产生大量短命对象。

**解法 A：持久化数据结构**

标准库的 List/Map 底层用 HAMT 或 RRB-Tree，结构共享：

```
let new_list = old_list.push(item)
-- 底层只创建 O(log n) 个新节点，共享其余结构
```

JS 生态有成熟实现可集成。

**解法 B：线性性检测**

编译器做数据流分析：旧值之后无引用 → 安全就地修改：

```
let result = old_list.filter(f).map(g).sort()
-- 如果 old_list 此后无引用，直接在原数组上操作
```

**解法 C：融合（deforestation）**

消除中间数据结构，多次遍历合并为一次：

```
-- 源码: users.filter(f).map(g).filter(h)
-- 朴素: 3 次遍历，2 个中间数组
-- 融合: 1 次遍历，1 个结果数组
```

三种解法可叠加。

### 11.3 Row Poly 导致 V8 去优化（影响：中）

Row-polymorphic 函数被多种 object shape 调用时，V8 的 inline cache 从 monomorphic → polymorphic → megamorphic，回退到字典查找（慢 5-10x）。

**解法：热路径单态化**

编译器分析调用点，热循环中只有 1-2 种具体类型的 row-poly 函数生成特化版本：

```javascript
// 编译器发现 greet 在此循环中只接收 User
function greet_User(person) { return "hello, " + person.name; }
// V8 看到单态调用，全力 JIT

// 冷路径保留泛用版
function greet(person) { return "hello, " + person.name; }
```

### 11.4 Refinement 运行时检查冗余（影响：中）

热循环中每次迭代重复检查同一约束。

**解法：检查提升 + refinement 传播**

```
-- 如果类型已是 List<Item where price > 0>
-- 元素级 refinement check 完全消除

-- 如果类型是 List<Item>（未 refined）
-- 检查提升到循环入口，一次性验证
for item in items {
    assert_refine(item)    // 只在入口一次
    compute(item)           // 内部不再检查
}
```

本质是 refinement 的 SSA 传播：变量在某程序点被证明满足约束后，后续同一约束检查全部消除。

### 11.5 闭包创建的 GC 压力（影响：低）

管道中多个小闭包产生堆分配。V8 能内联小闭包，但复杂管道可能超出内联预算。

**解法：闭包合并**

配合融合优化，多个闭包合并为单次遍历中的一个合并函数。与 11.2 的 deforestation 自然联动。

### 11.6 优先级矩阵

| 瓶颈 | 影响 | 解法 | 实现难度 | 阶段 |
|------|------|------|---------|------|
| Effect handler generator | 最高 | 编译期特化 + evidence passing | 中 | Phase 2 |
| 不可变拷贝 | 高 | 持久化数据结构 + 线性性检测 + 融合 | 中 | Phase 2 |
| Row poly 去优化 | 中 | 热路径单态化 | 中 | Phase 3 |
| Refinement 冗余检查 | 中 | 检查提升 + SSA 传播 | 低 | Phase 2 |
| 闭包 GC 压力 | 低 | 闭包合并 + 融合 | 中 | Phase 3 |

---

## 13. 竞品与行业定位

详细分析见 [`docs/competitive-analysis.md`](competitive-analysis.md)。核心结论：

**Ring-lang 的独特组合（完整代数效果 + HM 推断 + LLM 友好性）仍无直接竞品。** 最接近的三个方向各有缺失：Zero 有工具链但无效果系统，MoonBit 有成熟度但只追踪错误，Mog 有极简规范但无高级类型。

---

## 13. 企业级性能路线

JS 后端是原型限制，不是架构限制。核心研究问题已被 Koka 等项目解决。

### 13.1 Koka 的启示

Koka（微软研究院）通过两项技术达到 C 性能的 75-85%：
- **Evidence passing**：effect handler 编译为函数调用 + evidence 向量查找，开销等价于 OOP 虚方法调用
- **Perceus**：精确引用计数 + 就地复用分析，完全消除 GC 停顿

### 13.2 编译目标升级路线

| 阶段 | 后端 | 性能水平 | 对标 |
|------|------|---------|------|
| 当前 | JS (V8) | V8 水平 | TypeScript 同级 |
| +LLVM | LLVM native | C 的 2-3x | Go/OCaml 同级 |
| +Perceus | LLVM + Perceus 引用计数 | C 的 1.2-1.5x | Koka/Swift 同级 |

JS 后端是 bootstrap 方案——支撑编译器自举和早期开发。LLVM 是 Ring 的目标后端，届时编译器自身也将迁移到 native。

### 13.3 泛型单态化策略（2026-05-24 决策）

按类型表示自动分流，借鉴 C#/.NET Tiered Compilation。不是全单态化 vs 全 boxing 的二选一。

**分流规则**：
- 值类型（I8/I32/I64/F64/`@value struct`）：size/layout 不同，必须单态化
- 引用类型（List/Map/Str/struct）：底层都是指针，共享一份泛型实现（trait dictionary dispatch）
- 热路径：PGO/JIT 决定是否对特定引用类型也单态化

**构建模式**：

| 模式 | 策略 | 编译速度 | 运行时性能 |
|------|------|---------|-----------|
| Debug | 全 boxing（共享泛型） | 快 | 慢（可接受） |
| Release | 值类型单态化 + 引用类型共享 | 中 | 好 |
| Release + PGO | 上面 + profile 驱动的热路径单态化 | 两次编译 | 很好 |
| JIT（远期） | 运行时 tiered compilation | — | 最佳 |

**与 Rust 的根本差异**：Rust 全量单态化导致编译膨胀。Ring 初始方案是 uniform boxing（B-011 决策），只有值类型必须单态化（实例有限，膨胀可控），引用类型共享代码。这从架构上避免了 Rust 的编译性能问题。

**编译性能额外措施（按需实现）**：
- Debug 快速后端（Cranelift）：B-011 codegen 预留后端抽象接口
- 增量编译：函数级增量，effect row 签名 = 精确依赖边界
- HIR 缓存：依赖包首次编译后缓存 type-checked HIR
- 并行编译：模块间 codegen 完全并行（check 完成后签名固定）

### 13.4 关键技术路径

- **LLVM native** 用于桌面/服务端。Koka 编译到 C 再 gcc/clang，Kotlin/Native 直接用 LLVM。已证明可行。
- **Perceus 引用计数** 替换 GC。无停顿、确定性析构、函数式代码可就地复用已死对象的内存。语言设计无需修改——Perceus 是编译器优化，用户代码不感知。
- **Evidence passing** 替换 generator effect handler。同样是编译器优化，用户代码不感知。

### 13.5 先例

- **Swift**：~4 年从"脚本手感"到系统级性能（Apple 全力投入）
- **Kotlin**：JVM → LLVM native，与 Swift 性能差距 ~15%
- **Koka**：已达到 C 的 75-85%，纯研究院项目

### 13.6 双层优化架构（2026-05-28 决策）

Ring 的静态信息（effect、linearity、refinement、purity）比市面上绝大部分语言都丰富。LLVM 能直接消费其中一部分，但不是全部。优化架构因此分两层：

```
HIR（完整 type + effect + linearity 信息）
  │
  ├─ Ring 优化 pass（HIR 层，利用 LLVM 表达不了的信息）
  │   ├─ 纯函数重排 / 并行化（effect 证明无副作用 → 安全重排）
  │   ├─ Perceus 重用分析（RC=1 → 原地修改，不分配新对象）
  │   ├─ Refinement 驱动的 bounds check 消除（Z3 证明 → 删运行时检查）
  │   ├─ 闭包内联 / 特化（已知 trait impl → 消除 dict 间接调用）
  │   └─ Dead effect 消除（handle 掉的 effect → 对应 evidence 代码全删）
  │
  ▼
LLVM IR（附带 Ring 生成的属性和 metadata）
  │
  ├─ LLVM 标准优化 pass（利用前端标注的属性，效果优于 C/C++）
  │   └─ SROA, GVN, LICM, 向量化, 内联...
  ▼
机器码
```

**LLVM 能直接消费的 Ring 信息**：

| Ring 信息 | LLVM 属性/metadata | 优化器用途 |
|-----------|-------------------|-----------|
| 纯函数（无 effect） | `readnone` | CSE、DCE、LICM、可并行化 |
| 只读函数 | `readonly` | 同上，允许重排 |
| mut 参数只改自己 | `argmemonly` | 别名分析改善 |
| 非空类型（默认非空） | `nonnull` | 消除 null 检查 |
| 值范围（refinement） | `!range` metadata / `llvm.assume` | 消除 bounds check |
| 穷尽 match | default → `unreachable` | 消除死分支 |
| move 后唯一所有权 | `noalias` | **杀手级**——允许 store forwarding、向量化 |
| 不 fail 的函数 | `nounwind` + `willreturn` | 更激进的 DCE 和重排 |
| 尾调用 | `musttail` | 保证 TCO |

**LLVM 表达不了、需要 Ring 自己处理的**：
- Effect 组合语义（LLVM 只有粗粒度 readonly/readnone）
- 任意 refinement 谓词（`!range` 只能表达整数区间）
- Perceus RC 重用分析（LLVM 不理解 RC 语义）
- 纯函数间的可交换性/可并行性（LLVM auto-parallelization 几乎不可用）
- Linear type 的"恰好消费一次"约束

**Bootstrap 阶段要求**：Ring 自己的 HIR 优化 pass 是远期工作，但 **LLVM 属性标注从第一天就做**——成本极低（每个函数多几行 `LLVMAddAttributeAtIndex` 调用），收益立竿见影（LLVM 标准 pass 因属性存在而做得更好）。具体地：
- 每个函数检查 effect row：无 effect → `readnone`；只有 fail → 不标 readnone（可能 longjmp）；有 io/mut → 不标
- 每个参数检查类型：非 Option → `nonnull`
- 每个函数检查 fail 可能性：不 raise → `nounwind`

这些信息 HIR 里全有（每个 HExpr 带 Type + EffectRow），不需要额外分析。

---

## 14. 编译器实现

**当前状态：自举完成（2026-05-21）。** 编译器已从 TypeScript 完全翻译为 31 个 Ring 源文件（~14,260 行），编译到 JS 运行于 V8。TS 原始实现归档于 git tag `ts-compiler-final`。

**Koka 作为参考实现**：Effect 推断（`InferEffect.hs`）和 evidence passing（`Evidence.hs`）的算法翻译自 Koka 编译器（MIT 许可）。未来 Perceus 引用计数也将参考其实现。

**自举叙事价值**：Ring-lang 的编译器用 Ring-lang 写，由 Claude vibe-coded——同时证明语言能构建复杂系统、LLM 能高效使用。

---

## 设计取舍

| 拿到了什么 | 付出了什么 |
|-----------|-----------|
| Effect 系统统一所有副作用 | 编译器实现极其复杂 |
| Refinement types 编码业务规则 | 静态验证有极限，部分退化为运行时检查 |
| 全推断 + formatter 维护标注 | 类型错误信息可能难以理解 |
| 转译到 JS，零运行时成本 | 性能天花板受 V8 限制（对玩具无所谓） |
| Row poly + OOP 手感 | 与现有 class-based 生态互操作需要 extern 声明 |
| Const generics + refinement 组合 | 约束求解可能不可判定，需要保守边界 |
| LLM 友好的严格编译器 | 首次编译通过率可能低于 TS |
| 一种事一种写法 | 老手可能觉得缺乏灵活性 |

## 附录：实现状态（2026-05-24 更新）

### 已落地的设计决策

| 设计点 | 决策 | 理由 |
|--------|------|------|
| Effect handler 语义 | tail-resumptive + abort（full AE 已取消） | evidence passing 天然支持 tail-resume；full AE 工程价值不足（95%+ 场景已覆盖），剩余用例用 async effect + bracket 解决 |
| `or`/`try`/`?` 运算符 | 已移除，使用 `unwrap`/`to_fail`/`to_result()`/`catch` | 简化语法面，减少歧义 |
| catch 语义 | 总是消除 fail effect；部分处理用 catch 内部 match + re-raise（显式） | 消除隐式行为（原设计中有/无 catch-all arm 决定不同类型行为），降低概念数 |
| 错误模型 | 生命周期模型：fail effect 为主（诞生/流动），to_result 物化为数据（落地） | effect 是运动形态，Result 是静止形态；双模型各有地盘而非竞争 |
| 可变性统一模型 | `var` → `let mut`，`Cell<T>` 消除，`mut` 为唯一可变关键字 | 局部 mutation 不 box 不追踪（非 side effect）；闭包捕获/mut 参数自动 box + `mut<T>` effect |
| `++` 拼接运算符 | 不实现，使用字符串插值 | "一种事一种写法"原则 |
| Lambda 双向类型传播 | receiver 统一提前 + lambda 接受 expected param types | 支持 `==` 在嵌套 closure 中正确推断 |
| fn 类型 effect 标注 | `fn(T) -> U with {io}` 语法，无标注时 open row | 支持 HOF callback 的 effect 多态 |
| impl bounds | `impl<T: Eq> List { ... }` 语法 | 前置条件：Eq trait 约束迁移到 impl 方法 |
| mod capability | `mod name requires {effects} { ... }` 语法 | 模块级 effect 限制，E0405 错误码 |
| 多行字符串 | `"..."` 允许跨行，空白原样保留 | 减少字符串拼接需求 |
| Raw string | `r"..."` 和 `r#"..."#`，无转义无插值 | 正则表达式/codegen 场景减少转义噪音 |
| JS 为 bootstrap 后端 | JS 是自举过渡方案；LLVM 是目标后端 | 编译器自举需要 JS 运行时；LLVM 才能完全发挥 linear types / Perceus RC / full AE；生态通过 RIIR 策略自建 |
| Int/Str 语义独立于 JS | Int = 64-bit signed（JS 用 BigInt），Str = UTF-8 code point 语义 | JS 是部署目标不是设计来源；Ring 语义独立定义，JS 端付性能代价适配 |
| LLVM effect 派发 hybrid（2026-06-03 修正）| fail/abort → 运行时 handler stack + setjmp（ambient 绑定）；tail-resumptive → evidence 当值线程化为函数参数 + 可捕获进闭包 env（lexical 绑定）。镜像 JS oracle（fail=try/catch、tail-resumptive=evidence passing）| 两类 effect 绑定语义本就不同（abort 栈上随处 catch=ambient，tail-resumptive 类型定向=lexical）；值携带的 evidence 保留优化器可见性（evidence 特化 / dict 反虚化）+ async 线程迁移安全；与 JS oracle 同构故 parity 结构性 |
| LLVM FFI effect 穿透（§原 TLS 决策收窄，2026-06-03）| FFI-callback 用 evidence 捕获进闭包 env + 裸 C callback 边界 thunk 摆渡 env 指针；TLS 仅作 context-less C callback 的 env 摆渡机制，**非 effect 派发统一方案**；abort 跨 C 帧（longjmp UB）另议（禁 raise 或转 error-return）| C 回调 Ring 闭包时 env 自带 evidence，无需 TLS 查派发；归并 TLS 会让 tail-resumptive 变 ambient（语义改变）+ 杀掉优化可见性 + 撞结构化并发线程迁移，故维持分离 |
| 类型系统代价分配 | 复杂度由 LLM 承担（编译器错误循环），收益由用户享受（零 runtime surprise） | runtime error = 用户受害 = 体验降级；LLM 不是人、不领工资，编译器搏斗十轮也无所谓 |
| Refinement × Ownership × Effects 交互 | 详见 1.5 交互矩阵 | 三系统正交 + RAII（Drop trait）处理 Drop 值在所有路径的释放 |
| Ownership 模型 | Rust 风格 RAII，无 borrow checker；`impl Drop` = 所有权约束入口；Drop 与 Clone 互斥；所有路径自动 drop | LLM 从 Rust 训练数据天然理解 move/drop/RAII；无 `linear` 关键字——少一个概念 |
| 下标赋值语义 | 支持 `xs[i] = val` + bounds-check（方案 C） | 读写语义一致（越界都 panic）；JS 后端临时方案，LLVM 原生支持；Refinement Types 可消除已证明安全的 bounds-check |
| `mut<T>` 追踪粒度 | 参数级，不递归 field chain | `mut self` 已含"可修改 self 任何部分"语义，field-level 追踪是冗余子集信息 |
| 扩展交互矩阵 | 详见 1.5 扩展部分 | GADTs×Or-Pattern 禁不兼容约束合并；Refinement×mut 赋值点重新验证；Auto-Boxing×Ownership 透明；delegate 创建完整 trait impl 含关联类型；无 borrow checker（RC+Ownership+mut\<T\>+Drop 覆盖安全性） |
| LLM 友好性三原则 | 详见设计公理后章节 | 借来的语法行为像原主；错误信息对 LLM 友好；高级特性分自动浮现/用户触发两条路径 |
| GADTs 降优先级 | P3，LLVM 之后 | 编译器不需要；无下游依赖；用户侧高级特性 |
| Iterator/Iterable 协议 | 双 trait：`Iterator { type Item; fn next(mut self) -> Item? }` + `Iterable { type Item; type Iter: Iterator; fn iter(self) -> Iter }` | `for..in` 脱糖为 `iter()` + `next()` 循环；Range 保留 C-style for 快速路径（builtin EnumType，无法 impl trait）；Iterator struct 使用 `mut self` 引用语义修改游标 |
| LLVM codegen 策略 | Ring 写 codegen + `extern fn` 调 LLVM-C API；bootstrap 用本地 N-API addon（不入仓库） | codegen 只写一次；addon 是一次性 bootstrap 工具，自举后废弃 |
| LLVM 后端内存管理 | 初期 malloc 不回收 → 直接上 Perceus RC，无中间 GC | 编译器短命进程不需要回收；避免引入过渡方案增加技术债 |
| LLVM 值表示 | Uniform boxing（一切皆 `void*`，含基础类型） | 极简 codegen；容器/闭包/递归类型全部统一处理；Perceus RC 阶段再引入 unboxing |
| LLVM runtime | C++ STL wrapper（`ring_runtime.cpp` ~300 行，extern "C"） | 零额外依赖（libstdc++ 随 clang 自带）；std::vector/unordered_map/string 免写哈希表和动态数组 |
| LLVM 闭包表示 | `{fn_ptr, env_ptr}` 二元组 + 已知函数直接调用 | 标准方案；uniform boxing 下捕获统一为 void* |
| LLVM fail/catch | setjmp/longjmp | bootstrap 无 Drop/RAII 不需要栈展开；Ownership 阶段可切换 |
| LLVM 多文件编译 | bootstrap 阶段单 LLVM Module，单 .o 输出 | 不需要跨模块符号解析；增量编译留给后续 |
| Perceus 分层路线 | L0 RC核心(B-012) → L1 引擎(B-098) → L1 用户面(B-068,deferred) → L2 Drop/RAII+Weak(B-002) → L3 reuse(B-079) → L4 unboxing(B-080) | 可独立测试/merge 的序列 |
| Perceus L1 引擎提前（2026-06-04，#134 证伪 L0-only 自举）| 原断言「L0 owned-everywhere 单独解锁全自举、无硬前置」**错误**——对「循环内条件 move」是 double-free（崩溃非泄漏）。借用推断引擎（B-098）提前到 native-working 之前：borrow-default + escape-clone + scope-end-drop，撤销 always-own 读取补丁。仅引擎，用户面（move 语法/lv2/fmt/pub）留 B-068 deferred | branch-balancing 给未消费分支强插 drop → 单值多次 free；三套循环机制不覆盖此缝；逐点 always-own sweep 是站点未知的 whack-a-mole + 每个 move 需深层 Perceus 手术。borrow 不要求每路径消费 → 整类崩溃从根消除 |
| Perceus L0 对象头 | 每堆对象 offset 0 `{rc:u32, typeid:u32}`；per-type drop 函数 + typeid 派发表 | dup/drop 类型无关；用户类型 drop 由 codegen 生成（Koka 风格 per-type drop/scan）|
| Perceus L0 范围 | 不处理 abort 路径 drop（留 L2 drop-aware unwind）/ 循环引用（留 L2 Weak） | longjmp 跳过 drop = 泄漏非 UAF（安全）；自举走成功路径 + 树形数据无环；先解内存墙 |
| Perceus dup/drop IR | HIR 显式 Drop/dup 节点 + 反向 liveness pass（仅 llvm） | RC 行为落 IR 可 dump/测试；翻译 Koka Perceus POPL'21 |
| Perceus L0 闭包 capture 所有权（2026-06-03） | owned capture（普通闭包，env 死时 drop）vs borrowed capture（catch/handle 为平衡 Drop 捕入，env 死时不 drop）；#130 走 C 增量（普通闭包 env 独立 typeid + drop_env_T，catch/handle 排除），A 波（B-096）完整收口（borrowed 建模 + ring_try drop 闭包 + #4 guard-false + Range/dict drop_T） | env 复用 closure typeid 致 ≥2 captures 泄漏+误递归；#131 借 catch env 整体泄漏安全引入 borrowed capture，裸加 auto-drop 会 double-drop；差分抓 crash 不抓泄漏 → C 增量可验证安全 |
| occurs_in/apply_subst 对 struct/enum fields 一致忽略（2026-06-03） | 维持现状（只处理 type_params，fields/variants 原样保留）= 正确 nominal 语义，非 bug；撤销 B-057（错误立项）；#108 标 wontfix；彻底统一留 #16 nominal 重构 | fields 自始至终是声明模板（apply_subst 原样保留 + 字段实例化走局部 inst_map 不写回 + type identity 只比 name+type_params），无限类型的环只能经 type_params 形成、已被 occurs check 覆盖；补 fields 遍历 → apply_subst 递归类型栈溢出 / occurs_in 误判模板 var |
| LLVM evidence 表示 D1（2026-06-03 B-090）| `{fn_ptr, env}` 闭包 struct，slot = op 在 effect 声明里的顺序；共享 helper `effect_op_slot` 给 gen_handle_expr/gen_effect_op 共用 | 与 JS oracle（`{op: closure}`）语义同构 → parity 结构性；复用现有闭包表示；跨阶段契约进共享层符合约定。否决 effect-as-trait（搅入 supertrait/关联类型包袱）|
| LLVM handler 闭包 RC D2（2026-06-03 B-090）| evidence struct + handler 闭包暂泄漏，drop 收口并入 B-096 A 波 | B-090 价值是 parity（差分可验），泄漏是正交问题且已有归宿；耦合大内存机 double-free 实测会让 P1 卡在 P3 后 |
| B-090 范围分期 D3（2026-06-03）| core（B-090，L）= 单 effect multi-op tail-resumptive + 自然涵盖的 nesting；phase 2（B-097，P2）= custom-abort + default body(#72) + delegate(B-088#4) + nesting/multi-effect edge | 单 op 是玩具（真实 effect 都多 op）；custom-abort 需独立 setjmp 落点、default 需注入默认 evidence、delegate 是派发通后的扩展，均与核心机制不同 |

### 幽灵功能（已解析但无语义效果）

以下语法 Parser 接受但 Checker/Codegen 不处理，保留作为扩展点：

| 功能 | 解析行为 | 激活时机 |
|------|---------|----------|
| `where` 精化子句 | 消费 tokens 后丢弃 | refinement types |
| Supertrait | AST 字段存在，始终为空 | 后续 trait 增强 |
| Resume 参数名 | AST/HIR 字段存在，无语法触达 | 已无计划（full AE 取消），可清理 |

### 实现偏差备忘

- **Enum 单元变体语法设计**：声明和模式匹配使用 `red()`（带空括号），构造使用 `red`（无括号裸名）。设计原因：声明时与命名字段变体区分；构造时单元变体是值非函数调用；模式匹配时区分于绑定变量
- **比较运算符非结合性**：parser 拒绝 `a == b == c`，有意行为
- **`+=`/`-=` 复合赋值**：支持
- **`Str.replace` 全替换语义**：对应 JS `replaceAll`，替换所有匹配项
- **单元素 `(expr)` 不是 tuple**：与 Rust/Python 一致
- **Parser 换行感知**：`(` 跨行时不触发函数调用（防止 `42\n(...)` 被解析为调用）

### 自举翻译中发现的语言限制（2026-05-21）

将 ~13,340 行 TS 编译器翻译为 ~14,260 行 Ring 代码（31 文件），以下限制在实际大规模 Ring 编程中反复出现：

**字符串处理**：
- **插值不支持嵌套引号**：`"\{fn("arg")}"` 解析失败——内层 `"` 被视为外层字符串终止。必须预计算到变量再插值。在 codegen 模块中每次函数调用带字符串参数都需要额外 `let`，代码量膨胀约 15%
- **无 `+` 拼接运算符**：所有字符串拼接只能用 `"\{a}\{b}"` 或 `List<Str>.join()`。构建复杂 JS 代码字符串时需要大量 `List<Str> + push + join("")`，可读性低于 TS 的 template literal
- **`$\{` 与 JS template literal 冲突**：Ring 的 `${...}` 与 JS 的 `${...}` 语法相同，codegen 生成 JS template literal 时需要 `escape_for_template_literal()` 逐字符构建

**集合与索引**：
- **下标运算符 `list[i]` / `map[key]` / `str[i]`**：越界或 key 不存在时 panic。安全访问用 `.get()` 返回 `Option<T>`
- **`[x].clear()` 返回 `Unit` 不可链式**：空列表构造必须三条语句 `let x = [dummy]; x.clear(); x`，封装为 `empty_xxx()` 但每种元素类型需独立函数。31 个源文件中共定义了约 40 个 `empty_xxx()` helper
- **无 `List.set(i, v)`**：修改列表中间元素需重建整个列表

**控制流**：
- **`return` 不能在 match arm 表达式位置**：match arm 是表达式，`return` 是语句级构造。需要提取为独立函数或改用 if-else。codegen_expr 中 eq/ord dispatch 的 early-return 模式需要完全重构
- **Struct literal 不能在条件位置**：`if x == MyStruct { f: 1 } { ... }` 歧义，parser 无法区分 struct literal 和块。需用括号或变量绑定（Go/Rust 同有此限制）

**类型推断**：
- ~~**空列表 `[]` 类型推断失败**~~：已修复（Phase 3）。`let x: List<T> = []` 和上下文推断均正常
- **`.map()` 闭包不能捕获 `var` 变量**：HOF 闭包内引用 `var ctx` 会报错，需改用 `for` 循环 + `push`

### 未实现特性优先级

**中（增强表达力）**：~~关联类型~~ ✅、~~Iterator/Iterable trait~~ ✅（`delegate` ✅、supertrait 继承 ✅ 已实现）

**低（研究向）**：`dyn Trait`、`async`/`spawn`/`Future`、refinement types、const generics（B-070 起步）、平台条件编译

---

## 一句话

纯函数为心脏，effect 为血管，类型为骨骼，推断为皮肤——摸到的是 Python 的手感，内部跑的是 Haskell 的引擎。
