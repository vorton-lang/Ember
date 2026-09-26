# Backlog

> 活的工作看板。做完的条目删除，只在 git commit message 留记录。
> 条目格式：`### B-xxx <标题> [类型] [优先级] [复杂度] [dispatch] [状态]`
> dispatch 标记：`mechanical`（DS 可执行）/ `judgment`（Claude 执行）
> 状态流转：`queued` → `planning` → `doing` → 删除
> 反馈分支：`doing` → `waiting-feedback`（Worker 遇到设计问题）→ Discussion 处理后 → `queued`（重新排队）
> 工作流规范见 `docs/workflow.md`

## Phase C 执行计划 （2026-05-23 确定）

**目标**：基础设施特性 + 中等特性全部完成，为层 3 重型特性铺路。

**层 1（基础设施，优先）**：
- ~~B-034 Effect Aliases [S]~~ ✅ 已完成（2026-05-23）
- ~~B-005 Supertrait 继承 [M]~~ ✅ 已完成（2026-05-23）
- ~~B-037 `mut<T>` Marker Effect [M]~~ ✅ 已完成（2026-05-23）
- ~~B-008 Default Effect Handler [M]~~ ✅ 已完成（2026-05-23）

**层 2（核心特性）**：
- ~~B-004 关联类型 [L]~~ ✅ 已完成（2026-05-24）
- ~~B-036 Iterator Trait [M]~~ ✅ 已完成（2026-05-24）
- ~~B-010 `delegate` 关键字 [M]~~ ✅ 已完成（2026-05-23）

**设计验证（Stabilize 前置，阻塞层 3）**：
- ~~B-042 Perceus 循环引用策略 [M]~~ ✅ 吸收（2026-06-04）：设计已在 design.md §7.9 定案（`Weak<T>`），实现归 B-002 (L2)；B-012 已完成，无独立 item 必要
- B-068 Borrow-by-default 参数传递模型 [L]——**引擎部分已拆出为 B-098（native-working 关键路径，2026-06-04）**；B-068 缩减为用户面（`fn(move T)` 语法 / lv2 标注 / fmt 策略 / pub 规则），仍 deferred、不阻塞 native
- ~~B-043 Refinement × Linear × Effects 交互矩阵 [M]~~ ✅ 已完成（2026-05-24）
- ~~B-044 Ring 语义规范 [M]~~ ✅ 已完成（2026-05-24）

**关键路径（2026-06-03 更新）**：
- ~~B-004~~ → ~~B-036~~ → ~~B-011 LLVM~~ ✅ → ~~B-012 Perceus RC L0 基础设施~~ ✅ → ~~B-082 RC 诊断~~ ✅ → ~~B-081 dup 架构迁移~~ ✅
- **当前目标：native 自举 + E2E + 双后端行为对比全过**（2026-06-03 规划，见下「Native 自举路线图」）
- **订正（2026-06-04，#134 证伪）**：「L0 owned-everywhere 即可自举」的原假设错误——L0 对「循环内条件 move」是 double-free（崩溃，非泄漏），不能干净自举。借用推断引擎（B-098，原 B-068 引擎部分）被提前到 native-working **之前**，是 native 自举关键路径。B-068 用户面仍不阻塞 native（B-042 已吸收入 B-002 L2）
- B-033 GADTs 推迟至 native 自举之后（无下游依赖）
- 层 3 在 native 自举 + 归档后启动。**排序（2026-06-05 Discussion 定）**：B-002 Drop/RAII(L2) → **async(B-007) 先**（设计已锁、自包含、风险低、宣发价值大）→ Refinement(B-001) 随后（需 Z3 + 先做 B-070 const generics）；M 项（B-072 Union / B-069 默认参数 / B-070 固定数组）当 XL 间换气穿插；P3 研究（GADTs/dyn/GATs）最后。B-002 的 abort-unwind 子集可能因 G-a 内存提前（待 B-102 内存实测定）
- **LLVM 落地后 JS 后端归档**（策略见 B-100，非简单废弃——先证 parity + golden 快照）

### Native 自举路线图（2026-06-03 规划）

> 来源：本次 Discussion 4 路只读调研（codegen gap / 差分覆盖 / RC gap / runtime 完整性）+ 亲自贴码核查 load-bearing 断言。子 agent 报告按核过的可信度分档落项；hedged 断言走差分验证（B-088）再修。

三个验收门：
- **G-a 内存**：带 RC pass 自编译，内存峰值从 no-GC 的 25.9GB 降至本机可运行。**本机可验，待实跑确认**（JS 编译器 compile-time 已观测几百 M；native runtime 峰值待 #133 修复后本机实跑确认——RC 已编入 .o，runtime 大概率同步回落）
- **G-b 双 bootstrap 一致**：native 二进制重编译编译器，字节级一致
- **G-c 双后端 parity**：native E2E + llvm_diff 全过，行为与 JS oracle 一致

| Item | 内容 | 门 | 优先级 |
|------|------|-----|--------|
| ~~B-083~~ ✅ | LLVM match guard 完整实现（codegen + perceus RC + diff）| G-c + G-a/b(RC) | P1 |
| ~~B-088~~ ✅ | 双后端差分覆盖扩展 — 锁 6 parity 用例 + 发现 6 处 LLVM 发散喂 B-087 | G-c | P1 |
| ~~B-084~~ ✅ | #130 闭包 owned-capture drop（typeid 15 CLOSURE_ENV + count-prefixed env + 通用 drop_closure_env；catch/handle + guard-false → B-096）| G-a/b | P2 |
| ~~B-085~~ ✅ | Perceus 发射 determinism（sort Set names before emit）| G-b | P2 |
| ~~B-086~~ ✅ | LLVM 缺失方法/runtime/dict（flat_map/find_index/fold/Ord dict/Option.to_fail）| G-c | P2 |
| ~~B-087~~ ✅ | LLVM codegen 双后端 parity — 6 确认 gap + tuple-literal pattern 全修（dict_closure_dicts / Wrapped dict / 闭包捕获 dict / range var for-in / #103 mut writeback / #132 print Int）；llvm_diff 39→46 | G-c | P2 |
| B-002 | abort-unwind drop（#2 TryCatch + handler abort）并入 Drop/RAII | G-a/c | P2 |
| B-096 | Perceus 闭包 RC 完整收口 A 波（borrowed建模+ring_try drop+#4 guard-false+Range/dict drop_T）| G-a | P3（本机可做）|
| ~~B-098~~ ✅ | 借用推断引擎 clone-all-escape（§7.11）— #134 系统性 double-free 崩溃类消除（a_empty.ring native EXIT 0 + 731/49×3 + double-bootstrap 一致）| G-a/b/c | ✅ 2026-06-04 |
| ~~B-101~~ ✅ | Type-DAG 所有权 = intern + 永不 drop — A1（never-drop）杀结构性 Type-DAG UAF + enum 构造器 call-arg sink（解锁空 prelude 真根因）落地；native E2E×3 已建 | G-a/c | ✅ 2026-06-05（A1+ctor-sink；A2/链→B-102）|
| **B-102** | **native over-free 链终结（ASan 驱动）+ A2 hash-cons — native 自举真 blocker：链≥3 层 pre-existing UAF（A1 修 2 层，剩 `TypeExpr` 等）用 ASan 收敛猎杀 + A2 intern 去重达 G-a（承 B-101 方案 A 另一半）** | **G-a/c** | **P1（native-working 硬前置，2026-06-05 立项）** |
| B-089 | Native 终验 capstone（G-a/b/c + 内存实测 + B-099）| 全部 | P1（依赖 B-102，B-102 后启动）|

依赖：B-089 依赖前述全部；B-088 是 G-c 的发现+锁定引擎（失败的 diff 用例喂给 B-083/B-087，通过的锁定 parity）。**关键认识**：编译器自身重度用 trait/泛型/dict 且 LLVM 自编译字节级一致——故 B-087 那些 dict/多态发散**不阻塞自举**（编译器不触发），只阻塞 G-c E2E parity（特定模式触发）。

---

## 类型系统

### B-001 Refinement Types [feature] [P2] [XL] [judgment] [queued]
design.md 1.2。类型附带谓词，编译期静态验证 + 运行时检查兜底。

```ring
type Positive = Int where it > 0
type Email = Str where it.matches(r"^[^@]+@[^@]+\.[^@]+$")
fn divide(a: Float, b: Float where b != 0.0) -> Float { a / b }
```

- **当前状态**：Parser 已能解析 `where` 子句（tokens 被消费后丢弃），checker 验证未实现
- **前置依赖**：Phase B 模块系统稳定后启动
- **复杂度**：极大（SSA 约束传播 + 可选 Z3 集成）
- **优先级**：Phase C 首要
- **交互规则（B-043 决策）**：refinement 是值级谓词，不允许引用可变绑定；跨 effect/await 边界恒成立；handler resume 值须满足 refinement 约束；`mut` 参数带 refinement 时每次赋值重新验证（SSA 流分析，复杂度归入本 item）。详见 design.md 1.5
- **含 const generic 参数谓词**（2026-05-25，原 B-003 吸收）：refinement predicates 作用于 const generic 参数（如 `where N > 0`）归入本 item 的 SSA 约束传播。详见 design.md 1.3

### B-002 Ownership + Drop（Rust 风格 RAII，无 borrow checker）[feature] [P2] [XL] [judgment] [queued]
Rust 的所有权模型减去 borrow checker。编译器做数据流分析追踪值的所有权，确保 Drop 恰好执行一次。

> **Perceus 分层角色 = L2**（见 §7.10 / B-012）：在 L0 RC 核心（B-012）之上实现用户 `impl Drop` + 正常/abort/cancel 全路径 RAII。**两个并入项**：(1) fail/catch 从 setjmp/longjmp 切换到 **drop-aware unwind**（longjmp 会跳过 drop → 改成栈展开时逐帧 drop）；(2) `Weak<T>` 库类型实现（`Rc.downgrade()` + `.upgrade() -> T?`，循环引用解法，设计见 §7.9）。
>
> **#2 TryCatch / handler abort 的 abort-unwind drop 泄漏并入本项（2026-06-03 决策）**：try body 中途 `fail.raise`（经 `ring_try` longjmp）绕过正常 drop 序列，已分配局部值 + 未调用的 resume 闭包 + handler param 捕获全泄漏（方向安全）。perceus 静态 pass 插不进 longjmp 边——必须靠上面的 drop-aware unwind 在栈展开时逐帧 drop。涉及 `perceus.ring`（TryCatch/HandleExpr 分支）+ `ring_runtime.cpp`（ring_try/raise unwind）+ codegen_llvm。影响 G-a 内存 + G-c 正确性。原 B-083 #2 退回后归此。

**模型**：
- 所有值 scope 结束自动 drop（RAII，正常路径 + abort 路径均自动）
- Move 语义：赋值/传参 = move，move 后原变量不可用
- `impl Drop` 的类型禁止 `impl Clone`（编译器拒绝，资源不可复制）
- `drop(x)` 提前释放，`leak(x)` 显式逃逸（不触发 Drop）
- `mut self` 方法 = 隐式借用（不消耗所有权）
- 共享访问 → `Rc<T>`（Ring 等价物），Rc 可 Clone，内部资源 Drop 在 Rc 归零时触发
- 无 `linear` 关键字——`impl Drop` 是唯一的 ownership 入口
- 容器持有 Drop 类型值 → 容器 Drop 自动 drop 所有元素，容器自身不因此获得 Drop 约束

**LLM 友好性**：本质是 Rust move/drop/RAII 语义，LLM 从 Rust 训练数据天然理解。自动浮现路径：LLM 正常写代码 → move 后使用原变量 → 编译器报 "value moved" → LLM 修。无新概念。

- **前置依赖**：`mut<S>` 稳定
- **复杂度**：大（ownership checker + Perceus RC 的前置条件）
- **优先级**：Phase C 与 refinement 穿插
- **交互规则（B-043 决策）**：RAII 模型——Drop 值在 abort/cancel 路径自动释放；Drop::drop 禁止 fail effect（允许 io）；spawn 为 move 语义，不可跨任务共享 Drop 值；`mut self` 调用 = 隐式借用（不消耗）。详见 design.md 1.5



### B-072 Union Type（匿名 enum 语法糖）[feature] [P2] [M] [judgment] [queued]
`A | B | C` 作为匿名 enum 的语法糖。纯编译期展开，不引入子类型，HM 推断不受影响。详见 design.md 1.1b。

**核心用例**：
1. 错误组合：`fail<IoError | ParseError>` — 消除手写包装 enum 的 boilerplate
2. Row poly 签名显示：`fn greet(person: User | Company)` — 单态化后的具体类型展示
3. 多类型参数：`fn process(x: Str | I64)` — 轻量级 sum type

**语义规则**：
- 展开为匿名 enum（tagged，同 enum codegen）
- 归一化：按类型名字典序、去重、扁平化
- 结构等价：两处 `Str | I64` = 同一类型
- 调用点隐式包装：传 `Str` 到 `Str | I64` 时编译器自动插入构造

**待定**：match 语法——用类型名做 pattern（`Str(s) => ...`）的消歧规则，需后续 discussion 细化

**涉及修改**：
1. `parser.ring`：类型语法支持 `A | B`
2. `types.ring`：`UnionType` 或复用 `EnumType` + 匿名 enum 生成
3. `infer.ring`：调用点隐式包装推断
4. `codegen.ring`：同 enum（tag + payload）

**验收标准**：
- `Str | I64` 可声明为参数/返回/变量类型
- `fail<IoError | ParseError>` 可编译，catch 可按类型 match
- 调用点自动包装
- 归一化 + 去重 + 扁平化正确
- 不影响 HM 推断
- 全部 E2E 测试通过
- 自举编译器正常编译自身

### B-033 GADTs（Generalized Algebraic Data Types）[feature] [P3] [L] [judgment] [queued]
> 2026-05-24 从层 2 移出：无下游依赖，编译器自身不需要，推迟至 LLVM 之后。
enum 变体可指定不同的返回类型约束，match 分支内编译器自动获得类型等式约束（完整方案：scoped unification）。

```ring
enum Expr<T> {
    Lit(Int): Expr<Int>,
    Add(Expr<Int>, Expr<Int>): Expr<Int>,
    IsZero(Expr<Int>): Expr<Bool>,
}

fn eval<T>(e: Expr<T>) -> T {
    match e {
        Lit(n) => n,                      // 分支内 T = Int，n: Int 满足 -> T
        Add(a, b) => eval(a) + eval(b),   // 分支内 T = Int
        IsZero(x) => eval(x) == 0,        // 分支内 T = Bool
    }
}

// 类型安全的异构列表
enum HList<T> {
    Nil: HList<Unit>,
    Cons(T, HList<U>): HList<(T, U)>,
}
```

**当前状态**：未实现

**前置依赖**：无硬依赖（但 union-find 需要扩展 snapshot/rollback）

**涉及修改**：
1. `ast.ring`：enum 变体声明扩展——`EnumVariant` 新增可选字段 `result_type: TypeExpr?`（`: Expr<Int>` 部分）
2. `parser.ring`：`parse_enum_variant()` 在字段列表后检查 `:` token → 解析返回类型约束。无 `:` 时为普通 enum（向后兼容）
3. `types.ring`：`EnumType` 的 variants 信息需要携带每个变体的类型约束（`variant_constraints: Map<Str, List<(Int, Type)>>`——类型参数 → 具体类型的绑定）
4. `infer_register.ring`：注册 enum 时，对有返回类型约束的变体，解析约束并验证——约束必须是 enum 自身的实例化（`Lit(Int): Expr<Int>` 中 `Expr<Int>` 是 `Expr<T>` 的实例化，绑定 T=Int）
5. `union_find.ring`：新增 `snapshot() -> Snapshot` 和 `rollback(Snapshot)` 方法——记录当前状态，分支结束后恢复
6. `infer.ring`：match 表达式推断时，若 scrutinee 类型是 GADT enum：
   - 每个分支进入前 `snapshot()`
   - 从变体的类型约束提取等式（如 T=Int），调用 `unify()` 注入
   - 推断分支体
   - 分支结束后 `rollback()` 撤回约束
   - 各分支返回类型在原始（未约束）环境中统一
7. `codegen`：无特殊改动——GADT 是纯编译期类型约束，JS 层面 enum 仍然是 tagged union

**交互规则（design.md 1.5）**：
- GADTs × Or-Pattern：or-pattern 合并的 GADT 变体必须携带兼容的类型等式，不兼容则编译错误
- GADTs × Effects：正交，无需特殊规则（scoped type equality 是编译期，evidence 是运行时）

**验收标准**：
- `enum Expr<T> { Lit(Int): Expr<Int> }` 语法可解析
- match 分支内类型等式自动生效——`eval` 函数可类型检查通过
- 无返回类型约束的 enum 变体行为不变（向后兼容）
- 类型约束与 enum 类型不匹配 → 编译错误（如 `Foo(Int): Bar<Int>`）
- 分支约束不泄漏到分支外
- 穷尽性检查对 GADT enum 正常工作
- or-pattern 合并不兼容 GADT 约束的变体 → 编译错误
- 全部 E2E 测试通过
- 自举编译器正常编译自身

### B-006 `dyn Trait`（动态分发）[feature] [P3] [L] [judgment] [queued]
运行时多态，默认静态分发（泛型单态化），`dyn` 是主动选择动态分发的标志。

```ring
fn process_all(items: List<dyn Describable>) { ... }
```

- **当前状态**：未实现
- **前置依赖**：无硬依赖
- **优先级**：Phase C 或 D

### B-038 GATs（Generic Associated Types）[feature] [P3] [L] [judgment] [queued]
关联类型可带自己的泛型参数，本质是 HKT-lite（类型构造器作为关联类型）。

```ring
trait StreamingIterator {
    type Item<'a>                    // Rust 风格（带 lifetime）
    fn next(mut self) -> Item<Self>? // Ring 不需要 lifetime，用 Self 参数化
}

// Ring 版本（无 lifetime，用类型参数替代）：
trait Lending<T> {
    type Output<U>                   // 关联类型带泛型参数
    fn lend(self, x: T) -> Output<T>
}

// HKT-lite：Functor
trait Functor {
    type F<A>                        // F 是类型构造器
    fn map<A, B>(self: F<A>, f: fn(A) -> B) -> F<B>
}
```

- **当前状态**：未实现
- **前置依赖**：B-004（关联类型）
- **复杂度**：大（关联类型的泛型化 + kind 检查）
- **优先级**：Phase D（研究向）。Ring 的 effect system 覆盖了 Monad 主要用例，GATs 紧迫度低

## Effect 系统

### B-007 `async` Effect + 结构化并发（设计已确定 2026-05-23）[feature] [P2] [XL] [judgment] [queued]
async 作为 effect，handler 决定执行策略。Generator-based 实现，支持 sync handler（测试场景）。

```ring
effect async {
    fn spawn<T>(task: fn() -> T with {async}) -> Future<T>
    fn await<T>(f: Future<T>) -> T
}

// 结构化并发：spawn 必须在 scope 内
fn fetch_both() -> (Data, Data) with {async} {
    scope {
        let a = spawn { fetch_stocks() }
        let b = spawn { fetch_bonds() }
        (await(a), await(b))
    }  // scope 结束：等待所有子任务完成，未完成的自动取消
}

// 取消 = await 点注入 Cancelled fail，可 catch 补偿
fn transfer(from: Account, to: Account, amount: Int) with {async} {
    from.debit(amount)
    await(to.credit_async(amount))
} catch {
    Cancelled => from.refund(amount)  // 补偿逻辑
}

// Sync handler（测试）：
fn test_fetch() {
    let data = handle fetch_both() with {
        async.spawn(task) => task(),          // 立即执行
        async.await(f) => f,                  // 直接返回（已 resolved）
    }
    assert(data.0 == expected_stocks)
}
```

**已确定的设计决策（2026-05-23）：**

1. **实现策略：Generator-based**
   - async-effected 函数编译为 JS `function*`（generator）
   - Handler = driver，决定同步/异步驱动 generator
   - 默认 handler（生产）：async driver（`yield` Promise → 外层 `await`）
   - 自定义 handler（测试）：sync driver（`yield` mock value → 立即 `.next()`）
   - 模块导出自动包装为 JS `async function`（对 JS 消费者透明）
   - 后续优化选项：方案 C 双模编译（默认 handler → native async，仅需性能时再引入）

2. **强制结构化并发**
   - `spawn` 必须在 `scope { }` 内
   - scope 结束时：等待所有子任务完成
   - scope 提前退出（error/return）：取消所有未完成子任务
   - 无 `detach()`——所有任务生命周期由 scope 管理
   - 未来如需长命任务，在顶层 scope 或独立 handler 中 spawn

3. **取消机制：await 点 fail 注入**
   - Scope 退出触发子任务取消
   - 被取消的任务在下一个 `await` 点收到 `Cancelled` fail effect
   - 两个 await 之间的同步代码一定完整执行（不中断原子操作）
   - `Cancelled` 可被 `catch` 捕获做清理/补偿
   - 未 catch 的 `Cancelled` 向上传播直到 scope 捕获

**与 Rust 的差异（避坑）：**
- ❌ Rust：drop Future = 静默取消，任务不知道被取消了
- ✅ Ring：Cancelled fail = 显式通知，可 catch 补偿
- ❌ Rust：Pin/Unpin 复杂度（自引用 state machine）
- ✅ Ring：GC 托管，无 Pin 问题
- ❌ Rust：async trait 需要 boxing（直到 RPITIT）
- ✅ Ring：effect + 推断，trait 中 async 方法自然支持
- ❌ Rust：runtime 碎片化（tokio vs async-std）
- ✅ Ring：一种标准 handler/runtime

**前置依赖**：B-037（mut<T> marker effect）+ B-008（Default Effect Handler）
**复杂度**：极大（generator codegen + scope 管理 + 取消传播 + 标准库 async 原语）
**优先级**：层 3（Phase C 层 1+2 完成后启动）
**宣发价值**：直接解决 function coloring + cancellation safety——带 async effect 的函数可在同步 handler 下测试，取消可补偿。设计已确定，实现前可作为已解决的设计卖点讲

## 迭代与集合

### B-095 List.enumerate 方法 [feature] [P3] [M] [judgment] [queued]

> 2026-06-03 立项备忘，低优先（B-086 #1 决策）。当前拿索引迭代只能 `for i in 0..xs.len()` 再索引，啰嗦。enumerate 是高频糖但不阻塞自举（全代码库零调用），按需再做。与 B-094（清死映射）耦合：B-094 删了 LLVM 死映射，本项真做时需重新补齐 checker + runtime + codegen 全套。

`List.enumerate() -> List<(Int, T)>`：返回带索引的元素对。

**涉及修改**：
1. `compiler/builtins.ring`：注册 `List.enumerate` 方法签名 `(self) -> List<(Int, T)>`
2. `ring_runtime.cpp`：实现 `ring_list_enumerate`（构造 `(Int, T)` tuple 列表）
3. `compiler/codegen.ring`：JS 后端映射
4. `compiler/codegen_llvm_expr.ring`：LLVM 映射（恢复 B-094 删除的行）
5. `tests/cases/llvm/`：差分用例

**验收标准**：
- `for (i, x) in xs.enumerate()` 两后端可用且行为一致
- 全部 E2E + llvm_diff 通过；自举一致

## 性能优化（愿景：语义驱动的编译优化）

> **核心论点**：Ring 的类型系统（effect + refinement + linear）不仅用于安全性，还为编译器提供其他语言没有的优化信息。性能是 Ring 的核心卖点之一——目标不是"接近 C++/Rust"而是在特定场景**超越**。
>
> 优化分两层：AOT（LLVM 编译期）和 JIT（运行时 PGO），很多优化两层都可以做。
> 前置依赖链：LLVM backend → Perceus RC → 各项优化 pass → JIT（远期）。

> **B-011 LLVM Native Backend 已完成（2026-06-01）** — 前端自举打通：ring.exe 单文件产出与参考编译器字节级一致，多模块端到端跑通，所有 codegen bug + fail/catch 已修（见 `tests/cases/llvm/` 回归套件）。**完整 native 自举的剩余两条验收（二次自举一致性 + native E2E 全过）受内存墙（25.9GB，no-GC）阻塞，已并入 B-012——Perceus RC 是解锁它们的唯一路径。**

### ~~B-012 Perceus RC 核心 (L0)~~ ✅ 已完成（2026-06-01）

基础设施全部落地：runtime RC（ring_alloc/dup/drop + typeid dispatch + builtin drops）、HIR Drop/Dup 节点、Perceus pass（backward liveness + branch-balancing）、LLVM codegen 集成。不带 RC pass 可自举且功能正常。728 E2E + 11 LLVM diff 全过。

**Perceus 分层**：L0 ✅ → **L1 借用推断引擎（B-098，native-working 关键路径）** → L1 用户面（B-068，deferred）→ L2 Drop/RAII（B-002）→ L3 reuse/FBIP（B-079）→ L4 标量 unboxing（B-080）。注：原「L0 单独解锁全自举」被 #134 证伪，L1 引擎提前。

**L0 剩余收尾**（从 B-012 拆出为独立 item）：
- B-082：RC 诊断基础设施（runtime 断言 + codegen 警告）
- B-081：dup 从表达式层 Block 包装迁移到语句层 emit
- B-083：RC pass 正确性修复（闭包捕获 / try-catch / 循环+闭包 / match guard）
- 全部完成后：带 RC pass 编译编译器自身，验证内存下降 + 二次自举一致性

### B-079 Perceus Reuse Analysis / FBIP (L3) [feature] [P3] [XL] [judgment] [queued]
就地复用分析（functional but in-place）：`rc == 1` 时 match 解构 + 同尺寸重构 → 就地改写，drop-reuse 配对消除分配。Perceus 的性能核爆点（函数式写法零拷贝：list map、tree rebalance/insert）。含 reuse specialization（为有/无 reuse token 特化函数）+ COW（`rc > 1` 时 clone-on-write，内部优化非用户可见语义）。
- **前置依赖**：B-012（L0 RC 核心）
- **参考**：Koka Perceus reuse pass
- **验收**：典型 FBIP 模式（list map/filter、tree insert）生成就地改写而非新分配；基准显示分配数下降；全 E2E + `llvm_diff` 不回归；自举一致

### B-080 标量 Unboxing (L4) [feature] [P3] [L] [judgment] [queued]
Int/Float/Bool 从 uniform-boxed 堆 ptr 改为寄存器内联值，消除标量的 alloc + RC 流量。当前 uniform boxing 一切皆 `void*`（含标量）。
- **前置依赖**：B-012（L0）。与 L1/L3 正交
- **注**：内存墙主要由结构体/list/string 主导（box_int 缓存实测无效），unboxing 是性能优化，非内存墙解法
- **验收**：标量不再堆分配；算术热路径无 box/unbox；全 E2E + `llvm_diff` 不回归；自举一致

### 语义驱动优化（AOT + JIT 共享）

以下优化利用 Ring 类型系统提供的**独有语义信息**，是 C++/Rust 编译器做不到或需要手动标注才能做到的：

| 优化 | 依赖的语义信息 | AOT | JIT | C++/Rust 对等物 |
|------|--------------|-----|-----|---------------|
| **Bounds check 消除** | Refinement types（编译器已证明 `i < len`） | ✓ | — | 无（需 unsafe） |
| **RC 省略** | Linear types（证明唯一持有） | ✓ | ✓ | Rust `&mut`（手动标注） |
| **就地修改保证** | Linear types + Perceus reuse analysis | ✓ | — | Rust `&mut`（手动标注） |
| **纯函数优化** | Effect purity（`with {}`） | ✓ CSE/DCE/重排 | ✓ 自动并行 | `constexpr`（有限） |
| **Evidence 特化** | Effect 单态调用点 | ✓ | ✓ | N/A |
| **Dictionary 反虚化** | Trait dispatch 热路径 | ✓ | ✓ speculative | Rust 单态化（编译期全量） |
| **融合（Deforestation）** | 纯函数管道 + Effect purity | ✓ | — | 手动循环合并 |
| **逃逸分析 → 栈分配** | 数据流分析 | ✓ | ✓ 更精确 | 手动控制 |
| **热路径单态化** | 泛型 + row-poly 函数 | 部分 | ✓ profile 驱动 | C++ 模板（编译期全量） |
| **闭包合并** | 管道中多个小闭包 | ✓ | — | 手动合并 |

### B-041 JIT 编译（LLVM ORC）[feature] [P3] [XL] [judgment] [queued]
AOT native 基础上，运行时 JIT 重编译热路径。利用运行时 profile 做 AOT 无法做的优化。

- **先例**：Julia（LLVM ORC JIT）；Java HotSpot（服务端追平 C++）；Cling（C++ 解释器）
- **前置依赖**：B-011 + 基础 AOT 优化 pass 稳定
- **优先级**：远期愿景（Phase D/E）
- **独特优势**：Ring 的 effect/refinement/linear 信息给 JIT 提供其他语言没有的优化燃料

### 类型系统驱动的控制力（远期愿景）

> 设计原则：控制力通过类型系统表达，不通过 `unsafe` 逃逸口。程序员声明意图，编译器保证正确性。
> 等性能优化阶段（LLVM backend 稳定后）再逐项实现。

**Region Effect（内存分配策略）**

`region<R>` 作为 effect，handler 决定分配策略（arena / pool / bump）。块内分配零 RC 开销，块结束一次性释放。Linear types 保证引用不逃逸 region 生命周期。

```ring
handle {
    let tmp = entities.map(|e| alloc(e.pos))
    process(tmp)
} with region { arena(64 * 1024) }
```

应用场景：游戏帧循环、HTTP 请求处理、批处理管道。

**Value Types（unboxed 内联存储）**

`@value struct Point { x: Float, y: Float }` — 保证无 RC、按值传递、内联存储。编译器验证 value type 不含引用类型字段（或所有字段也是 value type）。

应用场景：数学向量/矩阵、颜色、坐标、小型不可变数据。

**Refinement 驱动的检查消除**

`fn get_unchecked(list: List<T>, i: Int where i >= 0 && i < list.len()) -> T` — refinement 证明已涵盖安全条件，编译器跳过运行时 bounds check。不需要 `unsafe`，类型系统保证安全。

应用场景：HPC 紧循环、图像像素遍历、矩阵运算。

**声明式优化 Hint**

| Hint | 作用 |
|------|------|
| `@align(N)` / `@packed` | 内存布局控制（cache line 对齐、紧凑存储） |
| `@specialize(T = Int)` | 强制泛型函数单态化 |
| `@vectorize` | 结合 effect purity 安全自动向量化 |
| `@inline` / `@noinline` | 内联控制 |

**不做的控制力**

| 机制 | 不做的原因 |
|------|-----------|
| 原始指针 / 手动 malloc | 破坏 RC/linear 保证 |
| 手动 SIMD intrinsics | 不可移植，由编译器 + hint 处理 |
| `unsafe` 块（Rust 风格） | Ring 用类型系统消除 unsafe 的需求 |
| 无 RC 模式 | 和 Perceus 架构冲突 |

## 工具链

### B-016 LSP 移植 [feature] [P2] [L] [judgment] [queued]
原 TS 实现未移植到 Ring 自举编译器。需要重新实现。

- **当前状态**：VSCode 插件仅提供语法高亮
- **前置依赖**：无硬依赖（但 formatter 完成后 LSP 可复用其 AST 处理）
- **复杂度**：大
- **优先级**：Phase B 之后，用户需求驱动

### B-017 CI 管线 [feature] [P3] [S] [mechanical] [queued]
测试全靠手动 `npm test`。

- **当前状态**：无 CI
- **前置依赖**：无
- **复杂度**：小
- **优先级**：按需（"仅跨平台时需要"——flywheel memory）

### B-018 Debugger [feature] [P3] [L] [judgment] [queued]
source-map 支持 + 断点调试。

- **前置依赖**：LSP
- **复杂度**：大
- **优先级**：Phase D/E

## 设计验证（Stabilize 前置）

> 非实现任务，而是设计探针。在对应 XL 特性实现前完成，防止特性交互导致事后 breaking change。



## 架构改进


## 语法增强

### B-069 默认参数 [feature] [P2] [M] [judgment] [queued]
函数参数支持默认值。调用时可省略有默认值的参数。

```ring
fn connect(host: Str, port: Int = 8080, timeout: Int = 30) with {io} { ... }

connect("localhost")           // port=8080, timeout=30
connect("localhost", 3000)     // timeout=30
```

**设计约束**：
- 默认值必须是编译期可求值的纯表达式（无 effect）
- 只能从参数列表末尾开始省略（无命名参数时）
- 默认值是签名的一部分，lv2 标注展示
- 与 borrow/move/effect 系统无冲突

**命名参数（待定）**：
- 配合默认参数可实现"跳过中间参数"：`connect("localhost", timeout = 60)`
- 参数名成为 API 一部分（改名 = breaking change）
- 推迟到实现默认参数时重新评估是否需要

**前置依赖**：无
**复杂度**：M（Parser 扩展 + Checker 参数匹配 + Codegen 展开）


## 已知 Bug / 技术债

### B-094 清理 to_int/to_float/enumerate 死映射 [refactor] [P3] [S] [mechanical] [queued]

> 2026-06-03 立项（B-086 #1 决策）。`.to_int()/.to_float()/.enumerate()` 在 checker 未注册为方法（`builtins.ring` 无），任何调用必报 E0305，全代码库（编译器/std/tests/examples）零调用，但 LLVM codegen 仍留死映射。`to_int/to_float` 与 `parse_int/parse_float`（`std/num.ring`，返回 `Option` 失败安全）冗余，**确定不加**；`enumerate` 暂不加（备忘见 B-095）。清掉死映射避免误导后续。

**涉及修改**：
1. `compiler/codegen_llvm_expr.ring`：删行 1405（`Str.to_int`→`ring_str_to_int`）、1406（`Str.to_float`→`ring_str_to_float`）、1450（`List.enumerate`→`ring_list_enumerate`）
2. 核查 JS 后端 codegen（`codegen_expr.ring` / `codegen.ring`）是否有对应死映射，一并删
3. 若 `ring_runtime.cpp` 残留 `ring_str_to_int`/`ring_str_to_float`/`ring_list_enumerate` 声明，确认无引用后清理

**验收标准**：
- 三处死映射移除，两后端无残留映射
- 全部 E2E + llvm_diff 通过
- 重新编译 dist + 自举一致



### B-073 Row poly 降级为语法糖 + 单态化 [refactor] [P3] [M] [judgment] [queued]
Row poly 从类型系统一等概念降级为语法糖（design.md 1.4，2026-05-25 决策）。编译期通过单态化消除 `RecordType`，pub fn 禁止 row poly 参数。

**涉及修改**：
1. `unify.ring`：移除 row unification（~260 行），替换为"检查 struct 是否有所需字段"
2. `types.ring`：`RecordType` 降级为 desugar 中间表示，不出现在最终类型
3. `infer.ring`：row poly 函数标记为需单态化，收集调用点具体类型
4. `codegen.ring`：为每个具体类型生成特化版本（同泛型单态化）
5. `checker.ring`：pub fn 使用 row poly 参数 → 编译错误

**验收标准**：
- 现有 row poly 测试（row_basic/multi_field/generic/reject）全部通过
- pub fn 使用 row poly → 编译错误
- `RecordType` 不出现在 HIR 最终类型中
- 如存在匹配 trait → trait 归化（可选，增量实现）
- 全部 E2E 测试通过
- 自举编译器正常编译自身

### B-054 Parser expression-level 错误恢复 [feature] [P3] [M] [judgment] [queued]
Parser 有声明级错误恢复，但 `handle...with` 等复合表达式无恢复机制，单个 malformed 表达式会 poison 整个声明的解析。

**涉及修改**：
1. `parser.ring`：在 `handle`/`match`/`if` 等复合表达式解析失败时，尝试跳到 `}`/`)` 等闭合 token 恢复

**验收标准**：
- malformed `handle` 表达式不阻止后续声明的解析
- 错误报告质量不下降
- 全部 E2E 测试通过

### B-055 Match 表达式统一 labeled block 替代 IIFE [refactor] [P3] [S] [judgment] [queued]
不含 `return` 的 match 表达式用 IIFE `(function() { ... })()`，含 `return` 的已用 labeled block + temp variable。统一为后者，避免闭包分配。

**⚠️ 已知阻塞（2026-05-24）**：temp variable 方案在 lambda body 中使用 match 时失效——`emit` 语句被写到 lambda 外部作用域，lambda 参数变量脱离作用域（如 `.any(fn(d) { match d.severity { ... } })`）。需要先解决 codegen 的 statement/expression 上下文区分问题。

**涉及修改**：
1. `codegen_expr.ring`：match 表达式统一使用 `__ring_blkN` temp variable 方案
2. **前置条件**：codegen 需要感知当前是否在表达式上下文中，以决定 emit 策略

**验收标准**：
- 生成的 JS 中 match 表达式不再出现 IIFE
- lambda 内部的 match 表达式仍正常工作
- 全部 E2E 测试通过
- 自举编译器正常编译自身

### B-056 闭包捕获 `let mut` 变量时注入 `mut<T>` effect [feature] [P3] [M] [judgment] [queued]
B-048 遗留。闭包捕获 `let mut` 变量时，应在闭包签名注入 `mut<T>` effect，使 effect 追踪完整。核心的 local effect cancellation 已在 B-048 完成。

**涉及修改**：
1. `infer.ring`：lambda 推断时分析捕获列表，对捕获的 `let mut` 变量注入 `mut<T>` effect

**验收标准**：
- 闭包捕获 `let mut` 变量 → 闭包类型携带 `mut<T>` effect
- 闭包内修改捕获的 mut 变量 → `mut` effect 正确传播到调用者
- local cancellation 规则仍生效（局部变量 mutation 不传播）
- 全部 E2E 测试通过

### B-071 推断失败错误信息 UX [feature] [P2] [M] [judgment] [queued]
> ✅ Phase 1 已完成（2026-05-29）：基础设施 + 10 个关键 unify 调用点 + notes 渲染。剩余场景（空集合、row poly、effect 不匹配专用消息）后续迭代。

**已完成**：
- `type_error_with_notes()` + `unify_at_noted()` 基础设施
- 10 个 unify 调用点加了约束来源 notes（let/var/assign/return/call/method/struct-field/match/if-else）
- `format_human` 渲染 `= note:` 行，`format_llm` 输出 `notes` 数组
- 5 个新测试验证 notes 功能

**待做（后续迭代）**：
- 空集合推断失败 → 建议加类型标注
- Row poly 字段缺失 → 指向字段访问点
- Effect 不匹配 → 说明缺少的 effect + handler
- `--error-format=llm` 修复建议增强





### B-070 固定长度数组 `[T; N]` [feature] [P2] [M] [judgment] [queued]
栈分配固定长度数组，值类型语义。密码学、音视频、矩阵运算、协议头等场景必备。

```ring
let key: [U8; 32] = [0; 32]
let matrix: [F64; 16] = [0.0; 16]

fn dot<N>(a: [F64; N], b: [F64; N]) -> F64 {
    let mut sum: F64 = 0.0
    let mut i: USize = 0
    while i < N { sum = sum + a[i] * b[i]; i = i + 1 }
    sum
}
```

**语义**：
- 栈上分配，内联存储（值类型）
- 赋值 = memcpy（值语义，零 RC）
- 越界 panic（和 `List` 一致）
- `N` 为编译期整数常量（const generic 最简子集）
- `.to_list() -> List<T>`（拷贝到堆），`List.to_array<N>() -> [T; N]?`

**涉及修改**：
1. `parser.ring`：类型语法 `[T; expr]` 解析
2. `types.ring`：新增 `ArrayType { element: Type, length: I64 }`
3. `infer.ring`：const generic 参数追踪 + 常量求值
4. `codegen.ring`：JS 后端映射为普通 Array（语义近似）
5. `codegen_llvm.ring`：LLVM `[N x T]` 数组类型，直接映射

**验收标准**：
- `[U8; 32]` 类型可声明、初始化、索引
- `fn f<N>(a: [T; N])` const generic 可推断
- 越界 panic
- 值语义（赋值 = 拷贝）
- 全部 E2E 测试通过
- 自举编译器正常编译自身

**等式约束（2026-05-25，原 B-003 吸收）**：const generic 参数支持等式 unification——`fn zip<T, U, const N>(a: [T; N], b: [U; N])` 要求两个 `N` 相等，由 HM unification 自然处理。用户自定义类型的 const generics（如 `struct Mat<const M, const K>`）为远期扩展。

**前置依赖**：无
**复杂度**：M（Parser + Checker const generic + Codegen）

## 关联类型修复依赖序（audit 建议）

~~B-062（#124 约束验证）~~ ✅ → ~~B-063（#125/#128 delegate 转发）~~ ✅ → ~~B-064（#129 scope 区分）~~ ✅ → ~~B-058（#115 bound 验证）~~ ✅ → ~~B-065（#121 显示改善）~~ ✅

## LLVM 后端质量

### B-097 自定义 effect handler LLVM — phase 2（custom-abort / default / delegate / nesting）[feature] [P2] [M] [judgment] [queued]
> 2026-06-03 从 B-090 拆出（D3 分期）。B-090 核心（单 effect multi-op tail-resumptive）落地后的全 parity 收口。复杂度 M-L。**依赖 B-090**。

承接 B-090 的 evidence 派发机制，补齐剩余 custom-effect parity 场景：

1. **custom-abort effect（非 fail 的 abort）**：用户 `effect Exc { fn throw(...) }` 当 abort 用。JS 靠 `EffectAbort` + effect-name 匹配；LLVM 当前只有 `fail` 接了 `ring_try`/`ring_raise`。需 per-abort-effect 的 setjmp 落点（泛化 `ring_try` 带 effect tag，或 per-effect handler 栈帧），与 tail-resumptive 是两套机制。
2. **default body（#72）**：op 带默认 handler 时，无 `handle...with` 也能调用——需自动注入默认 evidence（默认 op 闭包）。对照 JS 默认 handler 注入。
3. **delegate 转发 effect（B-088 #4）**：delegate 方法转发 effect 时正确传递 evidence（同 handler dispatch 根因的 delegate 表现）。
4. **nested / multi-effect evidence scoping edge**：B-090 核心吃掉 lexical scoping 自然涵盖的部分后，剩余的嵌套 handler / 同时 handle 多 effect 的 evidence shadowing 边角。

**涉及修改**：
1. `compiler/codegen_llvm_expr.ring`：custom-abort 的 handle/effect-op lowering；default evidence 注入；delegate evidence 转发；nested scoping
2. `ring_runtime.cpp`：泛化 `ring_try`/`ring_raise` 支持 custom-abort effect tag（或 per-effect handler 栈）

**验收标准**：
- custom-abort effect（用户 `effect Exc`）handle + raise JS/LLVM 一致
- 带 default body 的 op 无 handler 调用两后端一致
- delegate 转发 effect（B-088 #4 复现）JS/LLVM 一致
- 嵌套 handler / multi-effect handle 差分用例锁 parity
- 全 E2E + llvm_diff 通过；自举一致

### B-096 Perceus 闭包 RC 完整收口（A 波）[bugfix] [P3] [L] [judgment] [queued]

> 2026-06-03 从 B-084 拆出。B-084 的 #130 C 增量落地后的完整收口。**本机可做**（native 实跑即可观测 double-free / 内存峰值，放心动 `ring_try` 闭包 drop）。纯泄漏方向，差分测试比输出非内存，抓不到对错——做了之后差分全绿。见 design.md §7.10 闭包 capture 所有权。

B-084 C 增量只修普通闭包 owned-capture drop，catch/handle 闭包仍整体泄漏。A 波收口剩余四块：

1. **borrowed capture 正式建模**：perceus 区分 owned vs borrowed capture（#131 给 catch env 塞的 borrow-for-drop），borrowed 不进 env 或标记 no-drop。
2. **ring_try 闭包 drop**：`ring_try`（`ring_runtime.cpp:1517`）调完 body/catch 闭包后 drop 两者（连 env），消除整体泄漏。**必须与 borrowed capture 建模配套**，否则 double-drop catch arm 的 `f`。
3. **#4 guard-false 边泄漏**（B-083 残留）：带 guard 的 arm，pattern 绑定被 body dup 但 guard 假 fall-through → 该 dup 无人 drop（泄漏）。B-083 为消除 UAF 选保守策略（match 消费变量跨 guard fork 全程 dup 不 move），代价即此。修：perceus 产出 guard-false 边 drop 列表 + codegen 在 guard cond-false 目标前插 cleanup block 绑定并 drop。纯泄漏无 UAF。
4. **#3 残留 drop_T**：Range struct（start/end）+ Eq/Ord-dict struct（2 closures）当前共用 no-op TUPLE typeid，process-lifetime 极小泄漏。给各自专属 drop_T（与 env typeid 方案一并设计）。
5. **B-090 evidence struct + handler 闭包 drop**（2026-06-03 D2 吸收）：B-090 的 tail-resumptive handler 在 `gen_handle_expr` 分配 evidence struct（N slot 闭包）后暂泄漏（同 #2 的 `ring_try` 闭包策略）。本波给 evidence struct 专属 typeid + `drop_T`（drop 时递归 drop 各 slot 的 handler 闭包及其 env），perceus 在 handle scope 末尾发 drop。与 #1 borrowed capture 建模配套（handler op body 捕获外层的 owned vs borrowed 区分）。

**涉及修改**：
1. `compiler/perceus.ring`：owned/borrowed capture 区分；guard-false 边 drop 列表；handle scope 末尾发 evidence struct drop
2. `ring_runtime.cpp`：`ring_try` 后 drop body/catch 闭包；Range/dict struct 专属 drop_T；evidence struct 专属 typeid + drop_T
3. `compiler/codegen_llvm_expr.ring`：borrowed capture env 处理；guard cond-false cleanup block

**验收标准**：
- catch/handle 闭包 env 无泄漏；`ring_try` 后两闭包释放，无 double-drop（catch arm `f` 仅释放一次）
- guard-false 边 pattern 绑定 dup 正确 drop
- Range/dict struct 有注册的专属 drop_T
- B-090 evidence struct + handler 闭包在 handle scope 末尾正确 drop，无泄漏无 double-free
- 大内存机实测无 double-free；带 RC 自编译内存峰值进一步下降
- 全部 E2E + llvm_diff 通过；自举一致

### B-102 native over-free 链终结（ASan 驱动）+ A2 hash-cons [bugfix] [P1] [L] [judgment] [doing]

> **✅ 2026-06-05 Worker Wave A：Phase 1 DONE（git `1a6b1d7`）。剩 Phase 2（A2 hash-cons），现已 unblocked。**
> head-start worktree `dabccab` 半成品修复经 orchestrator 重验后落地（原 subagent 进程退出丢失、源码完好未提交）：
> - **layer-3/4/5 over-free 终结**：perceus `rc_block_inner` owned 集改增量可见（binding 只从 `let` 起进 visible_owned 且可 drop，新 `stmt_droppable_locals`；`concat([])` 防别名；shadow 名不重复 drop）；runtime `ring_list_extend` 元素 escape-dup。根因 = codegen 同名 local 共享 function-entry alloca，旧的「整块 locals 一次性纳入 owned + 全 drop」在「该名未构造的分支」over-free（resolve_type_expr 读已 free 的 TypeExpr）。
> - **验证全绿**：native `real_program.ring` EXIT 0 ×3 + 精确输出 + **ASan-clean（orchestrator 独立 ASan 跑确认，无 UAF/heap-overflow）**；JS 731×3 / llvm_diff 51×3 / double-bootstrap 字节一致。
> - **native 自编译已清掉全部 prelude/parse/resolve UAF**，推进到 exhaustiveness check 真实声明；**余下 self-compile 唯一 blocker = OOM（无界分配，ASan 跑到 9GB 无任何 UAF 报告即被手动打断）= 已知 G-a 泄漏（Type never-drop），正是 Phase 2 A2 hash-cons 的修复对象。over-free 链（UAF 类）已终结。**
> - ASan 构建配方（供 Phase 2/后续复用）：`clang -fsanitize=address -D_DISABLE_STRING_ANNOTATION -D_DISABLE_VECTOR_ANNOTATION -c ring_runtime.cpp`（关 STL 注解避开 `stl_asan.lib` 缺失）+ link main.o；运行需把 `<llvm>/lib/clang/22/lib/windows`（含 `clang_rt.asan_dynamic-x86_64.dll`）加进 PATH。
> **Phase 2（A2 hash-cons Type intern → G-a 内存门）= 本项剩余工作**，详见下方 Phase 2 节 + 方案 (A) A2。B-089 的 G-a 仍 gate 在此。
>
> **⏳ 2026-06-07 Worker：Phase 2 步 1+2 落地（git `68a56e9`）但内存门 FAIL → pivot lookup-before-build（详见下「A2 重设计」）**：`UnionFind.intern_table` + `type_intern_key`（逐 arm 对齐 types_equal）+ `apply_subst` 5 个复合 arm 走 `intern_type`（排除 Struct/Enum）。JS 731×3 + llvm_diff 51×3 全绿、dist fixpoint、native real_program ×3 EXIT 0。**但步 3 native peak RSS 实测 = G-a FAIL**：5-arm **和** 7-arm（诊断版）**都 20-21s 线性爬到 15GB 被 kill（~0.43GB/s，曲线重合）** → intern 零内存收益。**根因（关键发现）**：intern 写成 **wrap-after-build**（`intern_type(subst, Type::FnType{...})` 父节点先构造再查表），A1 never-drop 下命中时丢弃的副本永不释放 → 2.51 亿次分配照旧全泄漏，intern 只去重可达性（O(1) 相等）不去重分配。**修法已锁（用户拍板，方案 A fix-forward）= lookup-before-build hash-cons**（见下「A2 重设计」节）。

> 2026-06-05 立项（Discussion，B-101 收口拆出）。**native-working 真 blocker**——解锁 B-089 G-a/G-c。**B-101 已收口 done**（A1 Type-DAG never-drop + enum 构造器 call-arg sink 落地，git `ade6266`/`bedf4a0`；结构性 Type-DAG UAF 消除，设计见 design.md §7.11）。本项接力剩余 native over-free 链 + A2 内存门。

> **背景：native self-compile 是 over-free 链**（≥3 层 pre-existing L0 RC bug，每层被前一层崩溃掩盖，native 自编译从未成功）：① Type-DAG shallow-dup/deep-drop（**A1 已修**）② enum 构造器 call-arg owned-不-dup（**ctor-sink 已修**，是空 prelude 真根因——`find_std_dir` 的 `some(dir)` 载荷被提前释放）③ `resolve_type_expr` 读 freed `TypeExpr`（**未修**，间歇堆损坏，已证伪非前两类）④ 大概率还有（每修揭下一层）。clone-all-escape + 逐 patch = whack-a-mole，但**有界收敛**（固定代码库，每层真 bug + 回归保护，同原 #134 修 7 个）。

**Phase 1 — native over-free 链终结（ASan 驱动）**：
- **用 ASan 建 native ring.exe**（`-fsanitize=address`，clang 自带免费）：把「十亿级垃圾 tag + ring.map RVA + 最小 repro」的开放式 bisect 变成「run → ASan 精确报 UAF 站点 + 分配/释放栈 → 修 → 重复」的收敛流程（替代原 #134 的手工仪表）。
- 每层 over-free 定位后修（多为 perceus escape-分类 / ownership-mismatch 站点，如 ctor-sink 那类），**补 native 回归**（复用 `tests/native_selfcompile.test.mjs` + 加最小 repro 进 `tests/cases/llvm/`）。当前已知下一层 = `resolve_type_expr` 的 `TypeExpr` over-free。
- **⚡ ASan head-start（2026-06-05，前次 worker 崩溃前进度，未验证）**：ASan native build 已跑通（`ring_full.ll` + `clang -fsanitize=address`），**精确定位 layer-3** = `ring_drop`（`ring_runtime.cpp:122`，读 freed 块 typeid 头）+ `std::vector::size` heap-use-after-free（某 List 被 free 后又读 `.size`）。半成品修复（`perceus.ring` +81 / `ring_runtime.cpp` +22，**未验证、未跑测试**）+ ASan 原始报告（含分配/释放栈）保存在 **worktree 分支 `worktree-agent-a33863947e108b385`（commit `dabccab`）**。resume 时从此起点接，但 ⚠️ 半成品可能不完整/有误，需重验 731×3/llvm_diff/double-bootstrap。
- 跑到 native 编 `tests/native/real_program.ring` EXIT 0 **3×** + native 自编译推进/完成。
- **若 ASan 显示链异常深（十几层+）→ 回方案 D**（原则化 escape/alias 分析，Koka borrowing+reuse，L3/原 B-096）一次性关整类，届时重估。

**Phase 2 — A2 hash-cons Type intern（G-a 内存门，承 B-101 方案 A 的另一半）**：
- **native 正确性打通后做**（否则无法实测 peak RSS）。2.51亿 Type（`apply_subst` 每次无条件重建 spine）塌缩成有界类型集 → peak RSS << 25.9GB（A1 永不 drop 不去重、内存仍 ~25.9GB，靠 A2 去重才达 G-a）。附赠 O(1) 类型相等。
- **设计决策已锁（2026-06-07 Discussion，贴码核定）**：
  - **D1 var 边界 = 含未解析 TypeVar 就不 intern**：⚠️ **订正 spec 旧述「apply_subst 输出已 resolve」——不成立**。`apply_subst`（`env.ring:515` TypeVar arm）会原样穿出未绑定 var（`root==id` 返回 `t`，否则 `TypeVar{id:root}`），上层 StructType/FnType arm 无条件重建 spine → **输出可含残留 var**。故 `intern_type` 递归检查，类型里有未解析 TypeVar 就返回新建节点**不入表**；只 ground/resolved 入表（仍吃掉洪流主体）。备选「var 按 union-find root id 也 intern」仅当 D1 未达内存门再上（var root 随 union 漂移，多重复节点，正确但少省）。
  - **D2 intern key = 规范化字符串**：Ring Map key 走 JS `===`（不能拿 Type 当 key，否则废掉 intern）→ 新增 `type_intern_key(t) -> Str?`（含未解析 var 返回 `none`，与 D1 合成单次遍历），满足 `key(a)==key(b) ⟺ types_equal(a,b)`，配 `Map<Str, Type>`。key 须逐字对齐 `types_equal`：① **RecordType / EffectRowType 是无序集**（`types_equal` 用 `.all/.any`，`types.ring:340/350`）→ key 先按名/kind 排序 ② **⚠️ FnType effects 是有序**（`types_equal` FnType arm 走 `effects_list_equal` 按位比较，`types.ring:308-316`，**非无序**——实现中订正 spec）→ 不排序 ③ **不复用 `type_to_string`**（有损、非 injective）。
  - **D3 范围 = 只在 apply_subst 的 5 个复合 arm intern（排除 Struct/Enum）**：洪流主体 `let x=apply_subst`（167 处），intern **FnType / GenericType / RecordType / EffectRowType / TupleType**。**⚠️ Struct/Enum 排除（2026-06-07 实现中发现并经用户拍板，方案 A）**：原计划 nominal-shallow（key 只 `name+type_params`，忽略 variants/fields）**不健全**——`apply_subst` 不代换 variants/fields（`variants: variants`），但 `exhaustive.ring:128` **结构化读 variants** 拿 payload 类型，intern 按 `name+type_params` 任选一份缓存 → stale 泛型 `T` payload 泄漏进穷尽检查 → 回归 `tuple_option_sugar.ring`（`E0601 missing some(_)`）。排除 Struct/Enum 后 731 全绿；**dedup 损失边际**——被排除的只是 Struct/Enum 薄外壳，其 `type_params`（深层嵌套大头）仍经递归子节点 intern。否决「让 apply_subst 代换 variants/fields」（撞 design.md 决策表 line 2105：补 fields 遍历致递归类型栈溢出）+「deep key」（违反 key==types_equal + O(size²) 无限递归）。「全构造点 intern 拿 O(1) 类型相等」另立项、与内存门解耦。
  - **D4 intern 表放 `UnionFind` 结构内**：subst 已穿到每个 apply_subst + 递归，零额外线程化（不动 167 调用点签名）；表 arena 生命周期到进程退出，合 A1 never-drop 模型。备选全局单例/显式加参数均更差。
  - **🚦 前置不变量门（动手前必验，否则 intern 引新 bug）**：代码库不得有 (1) 就地 mutate 一个 Type，或 (2) 用 `===` 身份比较 Type——intern 让等价类型共享同一指针，违反 (1) 会串改别名、违反 (2) 行为变。实跑 + 搜码确认「Type 是不可变共享 DAG」这一硬前提成立后再 intern。✅ **已过**（两轮只读核查，2026-06-07）。

**A2 重设计 = lookup-before-build hash-cons（2026-06-07，wrap-after-build 内存门 FAIL 后 pivot，用户拍板方案 A）**：

> **为何 pivot**：D1-D4 的「构造点走 intern_type」被实现成 wrap-after-build（父节点先构造再查表）。A1 never-drop 下命中时丢弃的副本永不释放 → intern 零内存收益（5-arm/7-arm native 自编译都线性爬 15GB）。**保留**：D1 var 边界、D2 key（对齐 types_equal、FnType effects 有序）、D4 表位置。**改**：intern 时机 + 范围。

- **核心 = lookup-before-build**：apply_subst 各复合 arm 改为「先 apply_subst 子节点（已 intern）→ 从子节点算 key → 查表 → **命中返回缓存（零分配）/ miss 才构造父节点 + 插表**」。只在 miss 分配 → 内存 bound 在 distinct-type 集。这才是 hash-cons 本义（never-drop 正好契合不可变驻留）。
- **必须 sound 地 intern Struct/Enum**（诊断确认是洪流主体，排除即零收益）。**健全性洞**：apply_subst 不代换 variants/fields，而下游结构化读（exhaustive.ring:128 等）→ nominal-shallow 缓存任选一份致 stale payload。**候选修法**：① principled —— 修所有 variants/fields 结构化读取者改用 inst_map 按需代换（复用决策表 2105 已存在的「字段实例化走局部 inst_map 不写回」pattern），解耦后 nominal-shallow intern 健全；② intern 时一次性规范化 variants（recursive enum 需 cycle-guard）。**正在 scoping 穷举读取者 + 评估 ①** → 定方案后写入。
- **待核实（scoping 中）**：intern 表作用域 —— UnionFind 全程一个还是 per-decl 重建？若频繁重建需把表移到更长生命周期（TypeEnv/全局）才最大化跨-decl 去重。
- **key memoize**：lookup-before-build 下 key 计算 O(size²) 风险，可能需 memoize（interned 节点旁存 key / 返回 (Type,key)）。
- 实现前先看 scoping 结论定 Struct/Enum 方案 + 表作用域，再生成 plan。

**涉及修改**：
1. native 构建脚本：ASan 变体（`-fsanitize=address`）。
2. `compiler/perceus.ring` + 相关：逐层 over-free 修（escape-分类 / ownership-mismatch）。
3. `compiler/union_find.ring`：`UnionFind` 结构加 intern 表字段（D4）。
4. `compiler/types.ring`：`type_intern_key(t) -> Str?`（D2，对齐 `types_equal`：Record/EffectRow 无序排序、FnType effects 有序、含 var 返回 none）。
5. `compiler/env.ring`：`intern_type(uf, t)`（D1 含-var-不入表）+ `apply_subst` 的 **5 个**复合 arm 走 `intern_type`（FnType/Generic/Record/EffectRow/Tuple，**排除 Struct/Enum**，D3）。
6. `tests/`：每层 over-free 的 native 回归 + Phase 2 peak RSS 观测/断言。

**验收标准**：
- native ring.exe 编 `real_program.ring`（print/list/map/str）EXIT 0 + 输出对 **3× 稳定**
- native 自编译推进过链 / 理想完整自编译
- G-a 内存实测 **<< 25.9GB**（Phase 2 intern 后；本机实跑 peak RSS）
- JS 731×3 + llvm_diff 零回归；double-bootstrap 字节一致
- **intern 不破坏类型语义**：`types_equal` / 推断 / unification 行为不变（前置不变量门已验：无就地 Type mutation、无 `===` Type 身份比较）
- 全程无 UAF（ASan clean）

**注**：native 终验（G-a/b/c 全过）仍归 B-089，本项解锁之。下方为 B-101 收口前的设计史归档（Type-DAG 根因 + 方案 A 选型 + Wave A 死路教训），保留作 Phase 2 A2 实现参考。

---
**【以下：B-101 设计史归档，已收口】**

> **⚠️ WAVE A 结论（2026-06-05 Worker，subagent 静态逐-arm + orchestrator 主仓 native 实证）——务实白/黑名单是死路，转 `waiting-feedback` 等 /discussion 锁架构方案。用户已拍板「simple fix 有问题→直接 full implementation 彻底解决」。详见 `worker_feedback.md` [决策] B-101。**
> - **白名单必空**：`apply_subst`/`apply_subst_map`/`apply_subst_row`/`zonk` 全族无一满足「全 arm fresh」——都有 alias-返回 arm（scalar `=> t`、TypeVar 透传、`StructType{fields:fields}`/`EnumType{variants:variants}` 共享子结构）。Type tree 是故意不可变共享的 **DAG**，函数级粒度不可能判 fresh → 泄漏关不掉。
> - **黑名单是假命题**：「`let x = list[i]` 被 drop 而底层是 borrow」**不存在**——owner-bearing init 已经 `rc_escape`→`HExpr::Clone`（`ring_dup`），scope-end drop 平衡。
> - **native UAF 实证锁定**（ring.exe 编真实程序 3×）：崩在 `ring_env$$_apply_subst` 读 `Type` enum，tag 每次不同的十亿级垃圾 = UAF 铁证（Run3 段错误）。**真 over-free 在 Type-DAG 子结构 drop，不在 element-read**。
> - **根因 = Type-DAG 所有权结构性不健全**：`ring_dup` 浅 RC bump（只 +1 最外层）vs `Type` 的 `drop_T` 深递归 drop（drop type_params/fields/variants）+ apply_subst 故意共享子结构 → droppable Type 绑定 drop 时 over-free DAG 共享子结构 → apply_subst 后续 `uf_lookup` 读悬垂 Type。
> - **方案已锁（2026-06-05 Discussion）= (A) Type intern/hash-cons + 永不 drop**（同杀 UAF+泄漏）。否决 (B) 全子结构 RC（侵入广 + un-share DAG + 深拷成本）/ (C) 逃逸深 clone（打垮 G-a）/ (D) 原则化 escape 分析（L3 范畴、工作量最大）。详见下方「方案 (A)」节。
> - **已落地**：native E2E 回归网 `tests/native_selfcompile.test.mjs` + `real_program.ring`（本次即实证抓到此 bug）；perceus `is_fresh_owned_returning_call` 空 hook + DAG-aliasing 死路文档（in-code，防后人重试函数级白名单）。净行为变化 ZERO。

> ~~2026-06-05 早先：采用务实白/黑名单路线（fix-forward；原则化 alias 分析留 B-096/L3）。~~ **已被 Wave A 证伪。**

**根因（Wave A 实证锁定，订正 subagent-1 早先的 element-read 框架）**：`ring_dup` 浅 RC bump（只 +1 最外层 Type）vs `Type` 的 `drop_T` 深递归 drop（type_params/fields/variants），两者只在「构造时 dup 了所有 children」才平衡——而 `apply_subst` 故意**共享** children 不 dup（不可变 Type-DAG）。于是某 droppable Type 绑定 scope-end-drop 深递归 **over-free DAG 共享子结构** → apply_subst 后续 `uf_lookup` 读悬垂 Type → 崩（pre-existing L0 bug，自 B-012；B-098 把硬崩软化成静默 corruption）。同一不健全的另一面：为躲 UAF 保守「Call 结果一律不 drop」→ apply_subst 167 处 `let x=apply_subst()` 全不回收 → **无界泄漏**，G-a 主因未省。**两面同根 = Type-DAG 所有权模型，方案 (A) 一举两杀**（永不 drop 杀 UAF + intern 去重杀泄漏）。

## 方案 (A)：Type intern (hash-cons) + 永不 drop（2026-06-05 Discussion 锁定）

**核心**：Type 作不可变驻留值——构造走 intern 表（结构相同共享一份指针），且 Type 排除出 RC drop（interned 值有多 owner、RC 无意义、永不个体释放、arena 生命周期到进程退出）。**永不 drop → 结构性消除 UAF；intern 去重 → 内存有界。** Type 是故意不可变共享的 DAG（worker 实证），不可变 → intern 安全；这正是 GHC/OCaml/LLVM 的标准做法。

**分两步落地（A1 解锁 G-c 正确性，A2 达 G-a 内存门）**：

**A1 — Type 排除 RC drop（修 UAF，解锁 native 编真实程序）**
- Type typeid 的 drop dispatch 变 **no-op**：`ring_drop` 对 Type 不递归不 free（`drop_table[Type typeid]=noop`），或/并 perceus 对 Type-typed 值不发 `Clone`/`Drop`。
- 效果：深递归 over-free 共享子结构的路径消失 → native prelude UAF 消除 → native 编含 std 调用的真实程序不再崩。
- 代价：Type 仍每次 apply_subst 新建、永不释放 → 内存暂仍 ~25.9GB（泄漏不变）。**G-c 正确性解锁，G-a 未达**。
- A1 验收：native E2E（real_program.ring）EXIT 0 + 输出对 **3×**；native 自编译推进过 prelude。

**A2 — hash-cons Type 构造（去重 → 内存有界 → 达 G-a）**
- 新增全局 intern 表，Type 构造点（env.ring `apply_subst` 各 arm 的 StructType/EnumType/FnType/TupleType/…、types.ring 构造器、infer.ring）走 `intern_type(t)`：算结构 key → 命中返回旧 ptr / 否则插入返回。
- TypeKey = 结构哈希 + 结构相等（复用/扩展 `types.ring` 类型相等：nominal 部分 name+type_params，结构部分 FnType params/ret 等递归）。
- **⚠️ A2 主设计风险 = unification var**：HM 推断期 Type 含未解析 `TypeVar`（会 resolve），intern 可变结构有讲究。**边界已锁（2026-06-07 Discussion，见上方 Phase 2 D1）**：含未解析 TypeVar 就不 intern（订正旧述「apply_subst 输出已 resolve」——`env.ring:515` 证明未绑定 var 会原样穿出）；只 ground/resolved 入表。备选 var-by-root-id 作后备。
- 效果：2.51亿棵塌缩成不同类型集（有界）→ peak RSS << 25.9GB。附赠 O(1) 类型相等（推断提速）。
- A2 验收：native 自编译 peak RSS **<< 25.9GB**（本机实跑）。

**涉及修改**：
1. `ring_runtime.cpp`：Type typeid 的 drop dispatch 改 no-op（A1）。
2. `compiler/perceus.ring`：Type-typed 绑定不发 Clone/Drop（A1，与 runtime no-op 配合）；**撤销 Wave A 落的 `is_fresh_owned_returning_call` 空 hook**（死路，保留 in-code 死路文档作后人警示即可）。
3. `compiler/env.ring` / `types.ring` / `infer.ring`：Type 构造点走 `intern_type`（A2）；定义 TypeKey 结构哈希 + 相等；处理 unification var 边界。
4. `tests/`：复用已落地的 native E2E harness（`native_selfcompile.test.mjs` + `tests/native/real_program.ring`）；A2 加 peak RSS 观测/断言。

**验收标准**：
- native ring.exe 编含 std 调用（print/list/map/str）的真实程序 EXIT 0 + 输出正确，**3× 稳定**（harness 已建，间歇 bug 防假绿）
- native 自编译推进过 prelude（A1）；理想完整自编译
- G-a 内存实测 **<< 25.9GB**（A2 intern 去重后；本机实跑 peak RSS）
- JS 731×3 + llvm_diff 49×3 零回归；double-bootstrap 字节一致
- 全程无 UAF；Type 相等语义不变（intern 不破坏推断/unification）

**注**：A 把「Type 是不可变共享 DAG」从负债变资产。其余共享返回（InferResult.subst / UnionFind / HIR pass-through）继续保守不 drop（泄漏 crash-free，远小于 Type-DAG，不威胁 G-a）——它们的原则化 alias 分析仍留 **B-096/L3**。**可先交 A1（解锁 native 正确性，harness 验证），再 A2（达内存门）**。

### B-089 Native 自举终验 capstone [bugfix] [P1] [L] [judgment] [queued]

> **本机可做**：依赖 B-083/B-084/B-085/B-086/B-087/B-088 + #133 + **B-098（✅ 2026-06-04 done）** + **B-101（✅ A1 Type-DAG done）** + **B-102（native over-free 链 + A2，native-working 真 blocker）** 落地。

> **B-098 落地后的起点（2026-06-04 验证态）**：clone-all-escape 借用引擎落地，**#134 系统性 double-free 崩溃类消除**——native ring.exe 编 `a_empty.ring` EXIT 0（register_impl_method 崩点消除）、JS 731×3 + llvm_diff 49×3 全绿、dist double-bootstrap 字节一致。本项从「native 能编平凡程序」起步推进全自举。

> **B-098 暴露、归入本项的新 blocker（按 fix-forward 就地接力）**：
> **根因已查实（2026-06-05 两个诊断 subagent，决定性 revert 实验 + 静态 167 调用点核查）**：#1 与 #2 是**同一根因的两面** = perceus 分不清「Call/读取结果 alias 共享态」（不该 drop，否则 UAF）vs「fresh unshared」（该 drop，否则泄漏）。**修复：B-101（✅ A1 Type-DAG never-drop + ctor-sink done，2026-06-05）+ B-102（剩余 over-free 链 ASan 猎杀 + A2 内存门，native-working 真 blocker），B-089 依赖 B-102。**
> 1. **native prelude RC over-free（最关键，是 pre-existing L0 bug 不是 B-098 引入）**：`print` 是 `std/io.ring` 的 extern fn，native 编译报错时**整个 prelude env 为空**（`List.len`/`Str.len` 同挂），由 `infer.ring:1080` 发出。node(GC) 全 OK、native(RC) 全挂 + 探针敏感 + 每次变的十亿级 enum tag = **UAF 铁证**。**决定性 revert 实验**：回退到 pre-B-098（L0）**仍挂、且挂得更硬**（`use-after-free, last_fn=list_get, drop on freed`，编 `list.ring` 确定性触发）→ **bug 自 L0 RC（B-012）就在，B-098 只把硬崩软化成静默 corruption（list_get 改纯 borrow）、没消除**。over-free 值类 = list/map 元素读取结果（alias 容器内部）+ path_*/字符串 Call 返回。native 自编译**从来没成功过**——a_empty 不碰 prelude 故 GATE 1 漏检、llvm_diff 用 node 编译器漏检。
> 2. **`is_droppable_init` 无界泄漏（同根因另一面）**：clone-all-escape「Call 结果 fresh owned」对共享 DAG 不成立。subagent 2 核查 25.9GB 主因 `apply_subst` 的 **167 处调用全是 `let x = apply_subst(...)`**（Call 结果）→ 全落「永不 drop」→ **无界泄漏（正比编译步数，结构同 no-GC）**。RC 在主内存路径省到 ≈ 0 → **G-a（<<25.9GB）近乎注定失败**。修法见 B-102 Phase 2 A2（hash-cons Type intern 去重 → 有界；**非白名单**——Wave A 已证伪函数级白名单）。
> 3. **~247 条 `[rc-warn] Drop: variable not found`**：perceus block 作用域 vs codegen flat-named_values 未对齐（shadowed 名 / 分支局部），fail-safe 跳过=泄漏非崩，GATE 全绿证无误编。属内存优化精化。
> 4. **`--target=llvm` 自举依赖 B-099**：native 二进制未链 LLVM-C（`LLVMInitializeX86TargetInfo` missing）→ native 产 native 代码不可能，G-b/G-c 走 --target=llvm 需 B-099 先落地。
> 详见 `docs/worker_feedback.md` B-098 实现 [通知]/[观察]。

合 B-012 遗留的两条验收 + 内存门。三门：
- **G-a 内存**：带 RC pass 自编译，内存峰值降至机器可运行（验证 RC 有效）
- **G-b 双 bootstrap**：native 二进制重编译编译器，与参考产出字节级一致（依赖 B-085 determinism）
- **G-c parity**：native E2E + llvm_diff 全过，行为与 JS oracle 一致

**验收标准**：
- 带 RC pass native 自编译跑通且内存峰值 << 25.9GB
- double-bootstrap 字节级一致
- native E2E + llvm_diff 全过
- 全过后：CLAUDE.md 标 native 自举完成，启动 JS 后端归档 + 层 3

> fix-forward：跑通过程中暴露的新泄漏/发散就地开 audit/backlog，不预设"全绿才动"。

### B-099 native 自托管 LLVM 后端（Node 消除 / JS 归档最后一公里）[feature] [P3] [XL] [judgment] [queued] [deferred: B-098+B-089]

> 2026-06-04 立项（Discussion，从 worker_feedback #134 架构 gap 转入）。**deferred——严格在 native-working（B-098）+ B-089 三门验收之后**。**不阻塞 native-working**：native ring.exe 跑 `--target=js` 即可自托管前端（内存墙在前端，G-a/b/c 全可用 js 路径达成），本项只挡「native 二进制自己产 native 代码、Node 从工具链彻底消除、JS 后端归档」这最后一公里。

**gap 精确形态**：native codegen 对 extern fn 分两类——ring_runtime C ABI fn 走 allow-list（`get_or_declare_runtime_fn`）emit `declare` + 链接 `ring_runtime.o`，原生可用；LLVM-C extern fn（`LLVMBuildRet`/`LLVMConstInt`…）不在 allow-list 且 `HDecl::ExternFn` 在 forward-declare 被跳过（`codegen_llvm.ring:347`）→ 调用塞 panic stub。JS 后端由 N-API addon（`compiler/llvm-addon/`）在 Node runtime 满足。故 native `ring.exe build x --target=llvm` panic。

**真实 scope（非仅 link libLLVM）**：N-API addon 现在在 JS 里做 C-ABI marshalling——`List<T>`→`T*+count`（count 省略、addon 重建）、`Str`→`const char*`、opaque ref 透传、output 参数折进返回值（`llvm_ffi.ring:9-15`）。native 路径需把这套 marshalling 从 JS 搬成 codegen 内联 native glue（uniform-boxed Ring 值 ↔ C ABI）+ 链接 LLVM-C 22。

**涉及修改**：
1. `compiler/codegen_llvm.ring` / `codegen_llvm_decl.ring`：LLVM-C extern fn 改 emit 真实 `declare`（external 符号）而非跳过/panic；扩展 extern fn 处理覆盖 LLVM-C 全集。
2. codegen：emit C-ABI marshalling glue（List↔array+count、Str↔char*、output-param 折叠），对照 addon 当前 JS marshalling。
3. 构建/链接：native ring.exe 链接 libLLVM-C（22）。
4. addon 退役路径：marshalling 移入 codegen 后，N-API addon 仅剩 bootstrap 用途。

**验收标准**：
- native `ring.exe build x.ring --target=llvm` 产出可链接运行的 .o（不 panic）
- native 二进制自编译 native（`ring.exe build compiler/main.ring --target=llvm`）产出与参考一致
- 工具链全链路无 Node（除 bootstrap 历史）
- 全 E2E + llvm_diff 通过；自举一致

**依赖**：B-098（native 能跑）+ B-089（native 自举三门验收通过）。两者完成前不启动。

### B-100 JS 后端归档（parity 认证门 + golden 快照 + 删除）[feature] [P3] [L] [judgment] [queued] [deferred: B-099]

> 2026-06-04 立项（Discussion）。**deferred——排在 B-099 之后**，删 JS 前提是 native 工具链已自立。**归档策略 = (Z) 证明 parity → 快照 golden → 删除**。核心论点：差分 oracle 价值 = 抓两后端发散；一旦两后端被**证明** feature 完全一致且零 bug，oracle 对当前 feature 集已用尽，删除不损失测试价值。**删除点选「层 3 之前」**：golden 快照保存量回归网，层 3 新 codegen（async generator / Drop unwind / refinement 运行时检查）靠手写 E2E 期望值（无活 oracle——可接受，JS 后端实现层 3 也可能有 bug，oracle 非真值，且为层 3 维护两遍 codegen 成本过高）。

**前置**：B-099（native 自托管，Node 消除）+ B-097（custom-effect handler parity）+ B-096（闭包 RC 收口）——即「两后端 feature 完全一致」的剩余工作。

**Phase 1 — parity 认证门**（删除前置，可验收）：
1. **feature 覆盖矩阵**：穷举语言面，每个特性 ≥1 个 llvm_diff 用例断言两后端输出一致（不抽样）。补齐当前 llvm_diff 未覆盖的特性。
2. **关闭残留 G-c gap**：B-097（custom-abort / default / delegate / nesting）+ B-096（闭包 RC 泄漏）全绿。
3. **复数轮对抗 review**：`/full-audit` + `/code-review` 多轮交叉验证，每轮喂边角/对抗用例，loop-until-dry——连续 ≥2 轮零新发散方算通过（参照间歇 bug 的 3x 经验）。
4. 全 llvm_diff **×3** 零失配 + native E2E 全过 + 双 bootstrap 字节一致。

**Phase 2 — golden 快照 + 删除**（认证通过后）：
1. 把 parity 认证的 llvm_diff 语料**快照成 golden 输出**，存为回归基准（取代 JS-oracle 的活对照）。
2. 删 JS 后端：`codegen.ring` / `codegen_expr.ring` / `codegen_stmt.ring` / `runtime.ring`（JS runtime 拼接）+ llvm-addon 残留 + `--target=js` 路径 + llvm_diff 的 JS-oracle 执行（改 golden 对照）。
3. `CLAUDE.md` / `design.md` 更新：JS 后端标归档；测试策略改 golden + 手写 E2E 期望值。
4. Web playground 若仍需 JS/WASM，单独评估（已排除 WasmGC，Web 由 LLVM→WASM 覆盖）。

**验收标准**：
- parity 认证门 4 条全过（穷举矩阵 + G-c gap 清零 + 复数轮零新发散 + ×3 零失配）
- golden 快照建立；删 JS 后端后全测试套件仍通过（对照 golden）
- native 工具链无 JS/Node 依赖
- 删除点 = 层 3 启动之前

**已知取舍**：层 3 codegen 失去活差分 oracle，靠手写 E2E 期望值 + golden 回归验证（(Z) 策略的代价，已确认接受）。

## 性能优化



## 架构：后端策略（2026-05-23 更新）

**JS 后端定位为 bootstrap 后端，LLVM 为目标后端。**

| 后端 | 定位 | 生命周期 |
|------|------|---------|
| **JS (V8)** | Bootstrap + 差分 oracle | 当前唯一后端，支撑自举 + 当 LLVM codegen 的差分 oracle。归档走 B-100（(Z) 证明 parity → golden 快照 → 删除），不是简单废弃 |
| **LLVM** | 目标后端 | Ring 语言特性（linear types、Perceus RC、full AE）的完整实现平台 |

### JS 后端归档策略（2026-06-04 确定，B-100）

JS 后端不只是 bootstrap，还是 **LLVM codegen 的差分 oracle**（llvm_diff 用 JS 输出当真值）。因此「归档」≠ 随手删——简单删会摧毁这个 oracle，而层 3（async/unwind/refinement）恰是 codegen 最复杂处。

**策略 (Z)**：删除前先**证明**两后端 feature 完全一致且零 bug（parity 认证门：穷举覆盖矩阵 + 关 B-097/B-096 + 复数轮对抗 review，loop-until-dry），此时 oracle 对当前 feature 集已用尽；再把 llvm_diff 语料**快照成 golden**保留存量回归网，然后删 JS 后端。删除点 = **层 3 之前**——层 3 新 codegen 靠手写 E2E 期望值 + golden 回归（接受失去活 oracle，因 JS 实现层 3 亦可能有 bug 且双实现成本过高）。详见 B-100。

### 生态策略：RIIR（Rewrite It In Ring）

不依赖外部包管理生态（npm/crates.io），通过逐步用纯 Ring 重写标准库和核心库建立自有生态。底层原语（syscall、crypto、压缩）通过 C FFI 接入。

**FFI 边界是退缩前线**：标准库从 `extern fn` 包装 JS → 纯 Ring 实现。纯 Ring 代码天然跨后端——RIIR 进度 = 后端迁移就绪度。

### LLVM 后端引入路径

1. 语言特性完善（Phase C 层 1+2）
2. Codegen 接口抽象化（从 JS 单体中提取共享 HIR 优化 pass）
3. LLVM codegen 实现（HIR → LLVM IR）
4. 标准库底层原语移植（extern fn JS → extern fn C ABI）
5. 编译器自身 native 化（B-098 借用引擎 → B-089 自举三门 → B-099 native 自托管 LLVM / Node 消除 → B-100 parity 认证门 + golden 快照 + 删 JS 后端）

### 已排除的后端

- **WasmGC**：独立后端投入产出比不合理。Web 场景由 LLVM→WASM 路径覆盖。
- **QBE(Ring)**：编译器自包含是远期愿景，不主动规划。

## 已取消特性

### `or` 兜底表达式
design.md 2.3 层级 1。已被 Option 方法（`unwrap_or` / `unwrap_or_else`）取代，不再实现。

### Dependent Types Lite（B-003）
取消原因：功能与 Refinement Types（B-001）+ Const Generics（B-070）完全重叠。"依赖类型"的三个核心能力——值参数化类型（= const generics）、等式约束（= const generic unification）、值谓词约束（= refinement on const params）——已分别归入 B-070 和 B-001。不引入"依赖类型"概念，降低用户认知负担。

### Full Algebraic Effects（B-009）
Post-resume handler + multi-resume。取消原因：tail-resumptive + abort 覆盖 95%+ 实际需求，剩余用例用 async effect + defer 解决更好。实现复杂度（delimited continuation + 资源安全）与工程价值不成比例。

---

> 本文档随 Phase 推进更新。每个 Phase 启动时，从此处挑选特性进入该 Phase 的 spec。
