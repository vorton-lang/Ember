# Ring-lang 设计哲学

LLM-first 的 native 编程语言：写起来像 Python（lv0 零标注），编译器看到 Rust 级别的类型与副作用信息。语义内核 = Rust − borrow checker − 标注负担 + 代数效果 + 可判定推断。主战场：CLI / 服务端 / 系统编程——编译器自身（自举，35k 行级）是第一个生产负载。编译到 LLVM native；JS/V8 为 bootstrap 后端，native 落地后归档。

核心赌注：LLM 在零训练数据的情况下 vibe coding 大规模代码库，运行时错误率与总迭代轮数干掉主流语言——首先是「够用就行」的 JS/TS/Python。

---

## 六条公理

> 唯一真值源（2026-06-12 由四条扩为六条：可判定性与资源语义两条隐性地基成文）。design.md/CLAUDE.md/README 只放指针或速查，不重复全文。设计决策与公理冲突时公理优先；公理间冲突的仲裁记录入 design.md 决策表。

### 1. 类型即模型，不是谜题

类型系统表达力上限很高（refinement types、dependent types lite、GAT），但语法让简单场景零注解，复杂场景读起来像自然语言约束。强力但不鼓励类型体操：类型建模实际问题，不耍杂技。

### 2. 效果即可见性

函数的副作用（IO、失败、可变、异步）全部由 effect system 在类型层追踪。编译器全推断，人通过 IDE 幽灵标注感知冒泡点。只在模块边界处显式声明。

### 3. 推断为王，标注为仆

Bidirectional + constraint solving + effect inference。写代码的体验接近 Python，编译器内部看到完整类型+效果信息。标注由 formatter 按配置等级自动生成维护，人只控制详细度。

推论：**标注是文档，不是语义**（Gradual Guarantee 编译期变体——加标注不改变编译行为，标注过时只产生 warning，编译器永远从代码推断真值。见 lang-design.md §2.4）。

### 4. 无人回路

终极约束：让 LLM agent 能在无人审查的情况下自主编写正确代码。每个语言特性的评估标准之一是"它能替代人类在开发回路中的哪个角色"。编译器不只是检查工具，而是自主开发闭环中替代人类的控制器。

演进主线即此公理的逐项兑现：effect 推断（"有副作用吗"）→ 穷尽匹配（"case 全了吗"）→ 静态 leak verifier（"泄露了吗"，B-104 D2）→ refinement（"参数合法吗"，B-001）。新特性的取舍判据 = 能否把又一个人类判断移交编译期判定。

推论：**失真必须响**（静默行为差异对 agent 不可见，必须以编译错误浮现——B-110）；**优化不可观测**（引擎优化绝不改变可观测语义——COW 原则）；**人类审查面可枚举**（审查没有被消灭的地方压缩为可枚举集合 = unsafe discharge 点清单，`ring audit unsafe`，design.md §7.12）。

### 5. 编译器必须终止

类型检查与推断必须可判定——每个高级特性限制在可判定片段内，超出片段 = 编译错误（要求标注或 runtime check 兜底），不允许编译器不终止或耗时不可预期。为此放弃的特性及替代方案见 lang-design.md §11.7（函数重载/真 union 子类型/rank-2+/specialization 等八项）。这是无人回路的前置条件：编译器卡死 = agent 闭环断裂。对比：Rust trait solver 图灵完备（可能不终止），Ring 当前系统全部可判定。

### 6. 确定性资源语义

资源的释放时机是语言语义（确定、可从代码推导），不是运行时策略：`Drop` 在 scope 退出/最后使用处触发（编译器插入、后端无关），内存在不可达瞬间精确回收（native = Perceus RC，garbage-free 定理），环 = 泄漏、由 `Weak<T>` 显式打破；无 GC 停顿、无 finalizer、无隐藏 runtime。这是 move 语义、`.clone()`、`Weak`、unsafe 区（design.md §7.12）的公理地基。

**GC 取舍记录（2026-06-12 分析定案——放弃 GC 的真实理由，旧理由"GC 停顿"不成立）**：
- **语义层费用 GC 省不掉**：公理 2/4 独立强迫 move 语义——引用语义使 `mut<S>` 系统性失真、aliasing bug 类对无人回路永久开放（B-110 否决理由与引擎无关）；Drop/RAII 强迫 move-only 类型存在。即便换 GC 引擎，所有权的用户面（5 个浮现点）几乎原样保留，省下的只有引擎层。
- **引擎层四收益**：① 无 runtime——C ABI FFI 零摩擦、二进制小、WASM/嵌入式/GPU（design.md §9 远期）路径不堵死；② 内存占用 = live set（GC 需 2-3× heap headroom，agent 并行 ×N 进程放大）；③ Perceus 特有——FBIP 原地复用、garbage-free 定理、D2 静态 verifier（"编译期证明 0 泄露"GC 给不了）；④ 竞争位——AI-native 同辈（Mojo/MoonBit/Zero）全选 ownership/no-GC；GC 化 = 进 Go/TS"够用就行"修罗场（效果推断差异化最弱处），no-GC 打的是"Rust 人体工学"这个公认无解痛点。
- **不可逆性不对称（最硬一条）**：GC→确定性 retrofit 史上无成功案例（D 的 @nogc 残废、finalizer ≠ destructor）；RC→GC 级人体工学 = 当前设计纲领且已基本兑现（所有权仅 5 浮现点、全部 fail-safe）。要错就错在 no-GC 这边。
- **可证伪锚点**：B-089 re-measure = Ring 首个 RC vs GC footprint 实测（native RC plateau vs V8 自编译基线）；若完整 RC 不优于 V8，此账重算。

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
| 内存 | Perceus RC + ownership 推断（无 borrow checker），零标注负担；bootstrap JS 后端暂用 V8 GC |
| 注释 | `//` 单行（无块注释），默认不写注释 |
| 编译目标 | LLVM native（推进中）；JS/V8 为 bootstrap 后端，LLVM 落地后归档 |
