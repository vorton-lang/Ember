# Ring-lang 设计哲学

面向大型多端应用的编程语言。转译到 JavaScript/V8 运行。

核心赌注：LLM 在零训练数据的情况下 vibe coding 大规模代码库的表现能干掉 JS/TS。

---

## 四条公理

### 1. 类型即模型，不是谜题

类型系统表达力上限很高（refinement types、dependent types lite、GAT），但语法让简单场景零注解，复杂场景读起来像自然语言约束。强力但不鼓励类型体操：类型建模实际问题，不耍杂技。

### 2. 效果即可见性

函数的副作用（IO、失败、可变、异步）全部由 effect system 在类型层追踪。编译器全推断，人通过 IDE 幽灵标注感知冒泡点。只在模块边界处显式声明。

### 3. 推断为王，标注为仆

Bidirectional + constraint solving + effect inference。写代码的体验接近 Python，编译器内部看到完整类型+效果信息。标注由 formatter 按配置等级自动生成维护，人只控制详细度。

### 4. 无人回路

终极约束：让 LLM agent 能在无人审查的情况下自主编写正确代码。每个语言特性的评估标准之一是"它能替代人类在开发回路中的哪个角色"。编译器不只是检查工具，而是自主开发闭环中替代人类的控制器。

---

## 语法原则

### 一种事只有一种写法

TS 里定义数据结构有 interface/type/class/literal 四种写法，LLM 每次选不同的导致大型代码库风格混乱。Ring 中：

- 数据定义只有 `struct`
- 错误只有 `fail.raise`
- 方法调用只有 `.method()` 链式风格（无管道运算符）
- Option 操作只有方法链（`.map()`, `.and_then()`, `.unwrap_or()`）——无关键字
- 函数/闭包统一用 `fn` 关键字（无第二种 lambda 语法）

每当一种操作出现第二种写法，必须删掉一种。如果两种都有道理，删语法更重的那个。

### 语法借用——最大化知识迁移

不发明新关键字，除非语义确实是新的。LLM 的训练数据里已经有这些：

- `fn`/`let`/`var`/`struct`/`enum`/`match`/`trait`/`impl` ← Rust
- `"${x}"` 字符串插值 ← JS/Kotlin
- `//` 行注释 ← C/JS/Rust
- `.unwrap_or()` / `.and_then()` / `.unwrap()` ← Rust Option API

只有 `handle...with` 和 `catch { arms }` 是 Ring 特有语法——因为 algebraic effect handler 在主流语言中确实没有对应物。`.to_fail(error)` 是 Ring 独有方法——桥接 Option 和 fail effect。

### 扁平优于嵌套

过程式 + 函数式，零 OOP 语义（但模拟 OOP 手感）。偏好中间变量和顺序步骤，而非深度嵌套的表达式链。UFCS + `.method()` 链式调用是唯一的调用风格。

---

## 错误处理哲学

### 两个世界，各司其职

Option 是数据，fail 是计算。两者有清晰的职责分离：

```
Option 世界（数据类型）          Fail 世界（effect）
├── .map(fn)                    ├── 自动冒泡（零语法）
├── .and_then(fn)               ├── catch { pattern => handler }
├── .unwrap_or(default)         ├── handle...with（完整 handler）
├── .unwrap_or_else(fn)         │
├── .unwrap()  [panic]          │
├── .to_fail(error) ───────────→┘  桥接（Option→fail，保留错误信息）
├── match / if let              │
└── Result<T, E> [std]          └── to_result(fn) [std] 桥接（fail→Result）
```

- **Option** 是纯方法 API。无关键字，无运算符，无特殊语法
- **Fail** 有 `catch`（模式匹配错误）和 `handle...with`（完整 effect 处理器）
- **Option→fail 桥接**：`.to_fail(error)` 方法，调用者指定错误值——不丢失信息
- **fail→Option 桥接**：`some(expr) catch { _ => none }` 组合
- **fail→Result 桥接**：标准库 `to_result(fn)` 函数
- **`.unwrap()`** panic（不可恢复）vs **`.to_fail(error)`** raise fail（可恢复）——两种语义，不是重复

### 错误处理梯度

| 层级 | 语法 | 适用场景 |
|------|------|---------|
| 0 | 无 | fail 自动冒泡到调用方——90% 的情况什么都不用写 |
| 1a | `.unwrap_or(d)` / `.unwrap_or_else(fn)` | Option 需要默认值（急切/惰性） |
| 1b | `catch { arms }` | fail 需要处理，可能需要检查错误内容 |
| 1c | `.to_fail(error)` | Option→fail 桥接，保留错误信息 |
| 2 | `handle {} with {}` | 完整的 effect 处理（测试 mock、适配器模式） |

### 不存在的语法（及其理由）

| 不存在 | 理由 |
|--------|------|
| `try { }` | 与 `.and_then()` 重叠——两种 Option 链式方式违反"一种事一种写法" |
| `or` 关键字 | 关键字成本高于方法；Option 默认值统一用 `.unwrap_or()` / `.unwrap_or_else()` |
| `?` 运算符 | 本质是 unwrap；raise(undefined) 丢失错误信息；方法 `.to_fail(error)` 更好 |
| 管道运算符 `\|>` | 与 UFCS `.method()` 重叠——链式调用只有一种写法 |
| `\|x\| x + 1` 闭包 | 与 `fn(x) { x + 1 }` 重叠——函数定义只有 `fn` 一种形式 |

---

## 类型系统哲学

### ADT 三件套

所有抽象由三种构造完成：`struct`（积类型）、`enum`（和类型）、`trait`（行为接口）。无 class，无继承。

### 推断兜底一切

- 函数参数和返回类型可以不写——HM 推断 + 双向推断
- Lambda 参数类型在 HOF 上下文中自动推断：`xs.map(fn(x) { x * 2 })`
- Effect 完全推断——函数签名中的 `with { io, fail<E> }` 由编译器自动计算
- Formatter 按等级（0-4）自动补全标注，开发者控制详细度

### Trait = 行为，不是身份

Trait 定义行为接口，`impl` 块实现它。没有子类化，没有菱形继承。Trait 方法通过 UFCS 解析，优先级：impl 块 > trait 实现 > 自由函数。

---

## LLM 友好性哲学

### 编译器严格度 = LLM 安全网面积

同样的 prompt，TS 编译器放行的代码中藏着运行时炸弹，Ring 编译器在 LLM 提交前就拦截了。首次编译通过率可能低于 TS（更严格），但运行时错误率和总迭代轮数远低于 TS。

### 前馈控制替代人类审查

| 语言特性 | 替代人类的哪个判断 |
|----------|------------------|
| Refinement types | "这个参数合法吗？" |
| Effect 标注 | "这个函数有副作用吗？" |
| 穷尽匹配 | "所有 case 都处理了吗？" |
| `--error-format=llm` | 结构化错误，LLM 直接消费 |

每加一个类型安全特性，就是把一个原本需要人当观测器+判决器的场景，交给编译器自动完成。

### 模块签名 = 完美的上下文压缩

TS 要读完实现才知道函数会抛什么异常。Ring 的模块签名包含完整契约（类型+效果），一行顶 TS 几十行。LLM 用更少 token 获得更多 API 信息。

---

## 偏好约束

| 维度 | 选择 |
|------|------|
| 范式 | 过程式 + 函数式，零 OOP 语义 |
| 命名 | snake_case，ALL_CAPS 常量 |
| 不可变 | 默认不可变，`var` 显式声明可变 |
| 数据结构 | struct + enum + trait，不造 class 层级 |
| 内存 | GC（V8），开发者零心智负担 |
| 注释 | `//` 单行（无块注释），默认不写注释 |
| 编译目标 | JavaScript（V8），未来扩展 WASM/LLVM |
