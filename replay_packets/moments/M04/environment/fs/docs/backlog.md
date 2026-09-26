# Backlog

> 活的工作看板。做完的条目删除，只在 git commit message 留记录。
> 条目格式：`### B-xxx <标题> [类型] [优先级] [复杂度] [dispatch] [状态]`
> dispatch 标记：`mechanical`（DS 可执行）/ `judgment`（Claude 执行）
> 状态流转：`queued` → `planning` → `doing` → 删除
> 反馈分支：`doing` → `waiting-feedback`（Worker 遇到设计问题）→ Discussion 处理后 → `queued`（重新排队）
> 工作流规范见 `docs/workflow.md`

## Phase C 执行计划 （2026-05-23 确定）

**目标**：基础设施特性 + 中等特性全部完成，为层 3 重型特性铺路。

**已完成（2026-05-23→06-05，明细见 git）**：层 1（B-034/B-005/B-037/B-008）+ 层 2（B-004/B-036/B-010）+ 设计验证（B-043/B-044；B-042 吸收——设计在 design.md §7.9 定案 `Weak<T>`，实现归 B-002 L2）+ 关键路径 B-011 LLVM → B-012 RC L0 → B-082 RC 诊断 → B-081 dup 架构迁移 全部落地。

**现状 / 未完成项**：
- **当前目标：native 自举 + E2E + 双后端行为对比全过**（见下「Native 自举路线图」与「⭐ native on-par 统一规划」）
- B-068 Borrow-by-default 参数传递模型 [L]——**引擎部分已拆出为 B-098（✅）**；B-068 缩减为用户面（`fn(move T)` 语法 / lv2 标注 / fmt 策略 / pub 规则），仍 deferred、不阻塞 native
- **订正（2026-06-04，#134 证伪）**：「L0 owned-everywhere 即可自举」的原假设错误——L0 对「循环内条件 move」是 double-free（崩溃，非泄漏）。借用推断引擎（B-098）被提前到 native-working 之前并已落地
- B-033 GADTs 推迟至 native 自举之后（无下游依赖）
- 层 3 在 native 自举 + 归档后启动。**排序（2026-06-05 Discussion 定）**：B-002 Drop/RAII(L2) → **async(B-007) 先**（设计已锁、自包含、风险低、宣发价值大）→ Refinement(B-001) 随后（需 Z3 + 先做 B-070 const generics）；M 项（B-072 Union / B-069 默认参数 / B-070 固定数组）当 XL 间换气穿插；P3 研究（GADTs/dyn/GATs）最后。B-002 的 abort-unwind 子集可能因 G-a 内存提前（待 B-102 内存实测定）
- **LLVM 落地后 JS 后端归档**（策略见 B-100，非简单废弃——先证 parity + golden 快照）

### Native 自举路线图（2026-06-03 规划）

三个验收门：
- **G-a 内存**：带 RC pass 自编译，内存峰值从 no-GC 的 25.9GB 降至本机可运行
- **G-b 双 bootstrap 一致**：native 二进制重编译编译器，字节级一致
- **G-c 双后端 parity**：native E2E + llvm_diff 全过，行为与 JS oracle 一致

铺垫已全部完成（B-083 match guard / B-088 差分覆盖 / B-084 闭包 owned-capture drop / B-085 发射 determinism / B-086 缺失方法 / B-087 双后端 parity / B-098 clone-all-escape / B-101 ctor-sink，明细见 git）。余项：

| Item | 内容 | 门 | 优先级 |
|------|------|-----|--------|
| B-002 | abort-unwind drop（#2 TryCatch + handler abort）并入 Drop/RAII | G-a/c | P2 |
| B-096 | Perceus 闭包 RC 完整收口 A 波（borrowed建模+ring_try drop+#4 guard-false+Range/dict drop_T）| G-a | P3（本机可做）|
| B-102 | native Type-DAG RC 正确性（R-clean）——over-free 链已终结、本质 done，终验待 B-104（见条目）| G-a/c | P1 |
| B-089 | Native 终验 capstone（G-a/b/c + 内存实测 + B-099）| 全部 | P1（依赖 B-104，其后启动）|

**关键认识**：编译器自身重度用 trait/泛型/dict 且 LLVM 自编译字节级一致——故 B-087 那些 dict/多态发散**不阻塞自举**（编译器不触发），只阻塞 G-c E2E parity（特定模式触发）。

---

## ⭐ native on-par 统一规划（2026-06-08 Discussion 定，终点 = Level 1）

> 用户拍板：绕过中间碎波，把剩余工作统一规划成直达 **native 与 node 版前端+JS 后端对等（Level 1 on-par）** 的连贯路径。
>
> **⚠️ 更新（2026-06-09）：G-a 真解从「标记指针」改为「完整 Perceus RC」**——数据推翻标记指针（只消 ~21% BOOL+INT、非墙驱动；墙主体 74.5% 是非标量临时）。P1 改为 **完整 total drop pass + 静态 leak verifier（B-104）**，地基 B-103；标记指针（B-080）降级为后续 peak/perf 优化。详见 design.md §7.11「完整 Perceus RC」节 + B-104。

**Level 定义**：
- **Level 1（本次终点）**：native ring.exe 能做 node 版的全部前端 + JS 后端工作，自编译产出与 node 版一致的 dist（JS），三门（G-a/b/c）走 **js 路径** 全绿。产 .o 仍可借 node。
- **Level 2（不在本次范围，= B-099）**：native 自产 .o、native-native 自举、Node 从工具链彻底消除、JS 后端归档。**Level 1→Level 2 的分界 = B-099**，deferred。

**现状基线（已绿，不再碰）**：前端跑通、ASan 全清、能编真实程序、JS 731 / llvm_diff 53× parity、js 路径 double-bootstrap 字节一致。唯一硬墙 = G-a 内存（native 自编译 OOM）。

**统一阶段（依赖序，碎波已收编）**：

| 阶段 | 内容 | 收编/取代 | item |
|------|------|----------|------|
| **P0 决定性诊断** | call-site 归因，确认残留 INT 来源（边界 box / RC gap / 工作集膨胀），锁定标记指针兑现幅度，避免第四次误判 | — | B-080 前置步 |
| **P1 完整 Perceus RC** | total return-mode drop pass（drop 所有 fresh-owned 临时，统一覆盖 arg/scrutinee/condition/receiver/subexpr/control-flow，地基 B-103）+ 静态 leak verifier（编译期证明 0 泄露/0 UAF）。**G-a 真解** | B-104 完整化（收编 W1/W2/W3a/W4）；B-080 标记指针降级为后续 peak/perf | **B-104**（前置 B-103）|
| **P2 三门终验** | G-a（verifier 全绿 + live plateau + peak << 25.9GB 本机可跑）/ G-b（double-bootstrap 字节一致，js 路径）/ G-c（native E2E + llvm_diff 全量 parity） | — | **B-089**（Level 1 终点，依赖 B-104，B-099 out-of-scope） |

**两条纪律（统一 ≠ 裸奔）**：
1. **碎波可绕，依赖序与验证关卡不可绕**：P1 是动 perceus RC 核心的大改，内部仍须每改一类位置 → llvm_diff + ASan + verifier，否则全崩无从二分（比碎波更慢）。这不是"埋中间验证阶段"，是大改的工程必需。
2. **W1/W2/W3a/W4 框架保留、收编不推倒**：已落地的 materialize + scope-drop（Call-arg/scrutinee/control-flow/scalar-reassign）是 total pass 的前身（手工按位置版），收编为统一 return-mode 驱动算法 + verifier 兜底，不废弃已验证的安全性。B-080 标记指针后续叠加（消标量装箱 churn），与完整 RC 正交。

---

## 类型系统

### B-001 Refinement Types [feature] [P2] [XL] [judgment] [queued]
design.md 1.2。类型附带谓词，编译期静态验证 + 运行时检查兜底。

```ring
type Positive = Int where it > 0
type Email = Str where it.matches(r"^[^@]+@[^@]+\.[^@]+$")
fn divide(a: Float, b: Float where b != 0.0) -> Float { a / b }
```

- **当前状态**：struct-field 位 `where` 可解析（tokens 消费后丢弃，W0002 warning）；**参数位 `where`（`fn f(x: Int where x > 0)`）连解析都未实现——硬 parse error E0103（2026-06-11 实测核定）。参数位 parser 支持归本项，不单独先行**（先做解析又只丢弃 = 再造一个「写了不生效」的静默面，正是公理 1 违例的制造机；2026-06-11 用户拍板）。checker 验证未实现
- **前置依赖**：Phase B 模块系统稳定后启动
- **复杂度**：极大（SSA 约束传播 + 可选 Z3 集成）
- **优先级**：Phase C 首要
- **交互规则（B-043 决策）**：refinement 是值级谓词，不允许引用可变绑定；跨 effect/await 边界恒成立；handler resume 值须满足 refinement 约束；`mut` 参数带 refinement 时每次赋值重新验证（SSA 流分析，复杂度归入本 item）。详见 design.md 1.5
- **可判定片段条款（2026-06-12 D-5 拍板，公理⑤做实）**：SMT 查询限于**具名可判定片段**（QF_LIA + enum/bool 等式类，Liquid-style；具体片段定义 = lang-design §10 TODO「Refinement types 的可判定片段定义」，实现前必须完成）；超出片段 = 编译错误，要求显式 runtime check 兜底。**禁止 timeout 语义**——SMT timeout 即「耗时不可预期」，违反公理⑤
- **含 const generic 参数谓词**（2026-05-25，原 B-003 吸收）：refinement predicates 作用于 const generic 参数（如 `where N > 0`）归入本 item 的 SSA 约束传播。详见 design.md 1.3

### B-002 Ownership + Drop（Rust 风格 RAII，无 borrow checker）[feature] [P2] [XL] [judgment] [queued]
Rust 的所有权模型减去 borrow checker。编译器做数据流分析追踪值的所有权，确保 Drop 恰好执行一次。

> **Perceus 分层角色 = L2**（见 §7.10 / B-012）：在 L0 RC 核心（B-012）之上实现用户 `impl Drop` + 正常/abort/cancel 全路径 RAII。**两个并入项**：(1) fail/catch 从 setjmp/longjmp 切换到 **drop-aware unwind**（longjmp 会跳过 drop → 改成栈展开时逐帧 drop）；(2) `Weak<T>` 库类型实现（`Rc.downgrade()` + `.upgrade() -> T?`，循环引用解法，设计见 §7.9）。
>
> **#2 TryCatch / handler abort 的 abort-unwind drop 泄漏并入本项（2026-06-03 决策）**：try body 中途 `fail.raise`（经 `ring_try` longjmp）绕过正常 drop 序列，已分配局部值 + 未调用的 resume 闭包 + handler param 捕获全泄漏（方向安全）。perceus 静态 pass 插不进 longjmp 边——必须靠上面的 drop-aware unwind 在栈展开时逐帧 drop。涉及 `perceus.ring`（TryCatch/HandleExpr 分支）+ `ring_runtime.cpp`（ring_try/raise unwind）+ codegen_llvm。影响 G-a 内存 + G-c 正确性。原 B-083 #2 退回后归此。

**模型**：
- 所有值 scope 结束自动 drop（RAII，正常路径 + abort 路径均自动）——**scope-end 即语义**（2026-06-12 D-1 拍板，公理⑥/design.md §7.11 as-if 条款）：带 Drop impl 或被 `Weak<T>` 指向的类型禁止引擎提前 drop，纯数据类型引擎可在不可观测前提下提前
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



### B-110 Move 语义补完：use-after-move checker + 可变别名收口 [feature] [P2] [L] [judgment] [queued]

> 2026-06-11 立项（Discussion，Fable 全面审视）。**Mutable aliasing 语义拍板 = move 补完**，详见 design.md §7.5「强制状态」+ 决策表。背景：三真值源分裂——实现 = 引用语义（两后端，`let ys = xs; xs.push(3)` 后 ys 可见 3 元素，已核实 checker 无任何 use-after-move 检查、runtime 无 COW）、设计文档 = move（§7.5）、Koka 血统 = 值语义+COW——且无任何测试锁定任一。已否决引用语义追认（`mut<T>` 系统性失真、aliasing bug 类对无人回路永久开放）与值语义+COW（编译器自迁移是静默行为变化、JS oracle 无 RC 表达不了 COW）。

**涉及修改**：
1. checker：新增 use-after-move pass——复合类型绑定在「赋值给新绑定 / 存入 struct 字段 / 容器 insert / return 局部 / 跨 spawn 闭包捕获」后标记 moved，后续使用报编译错误（E07xx，`--error-format=llm` 含 `let ys = xs.clone()` 修复建议）。值类型（标量）auto copy 不受影响；Str 是否豁免（不可变值语义）实现时核定。
2. checker：句法禁止同一调用中同 lvalue 同时作 borrow 与 `mut` 实参（`f(xs, mut xs)`）——无 borrow checker 下唯一的别名洞。
3. 测试：aliasing 语义 E2E——判定程序 + 字段存储 + 容器 insert + spawn 捕获各一例断言编译错误；`.clone()` 后独立性正常路径（趁 JS oracle 在世双后端跑）。
4. 编译器自身迁移：use-after-move 错误即迁移清单——不可变共享改 `.clone()`（运行时=免费 dup），共享可变站点改 mut 参数线程化。**首步先跑 checker 统计错误数再定波次**，量大则回报拆分。
5. **投影绑定堵缝（2026-06-11 增补，COW 不可观测原则，见 design.md 决策表）**：`let item = xs[i]`（IndexExpr/FieldAccess 源的绑定）后对 item 写入，在 dup+COW 下会静默 detach（写副本不写原件）——use-after-move checker 不触发、行为静默变化，**原则已拍：不得静默分叉，必须响**。堵法 = (a) 写从投影绑定出的复合值 = 编译错误（与 use-after-move 同级）+ (b) 嵌套 lvalue path 官方化承接 + 测试锁定。**实测（2026-06-11 Discussion，两后端核实完毕）**：
   - **FieldAccess 为根的嵌套左值已全链工作且两后端一致**：`pts[0].x = v`、`w.p.x = v` 原地改——(b) 的主体已存在，缺测试锁定（补 E2E + llvm_diff）。
   - **IndexExpr 为根、receiver 非 Ident 的赋值两后端双崩**：`grid[0][1] = v`、`bag.items[1] = v`——JS codegen 产**非法 JS**（运行时 ReferenceError，产物级 bug），LLVM codegen 编译期 panic `unsupported assignment target`。修复归本条：按堵缝方案要么 emit set 路径递归化支持、要么 checker 显式报错，**不允许维持产非法 JS 现状**。
   - **投影绑定写穿透实锤**：`let mut item = pts2[0]; item.x = 99` → 原件同变（IndexExpr/FieldAccess 源、两后端一致）——B-110 落地时该模式必须按 (a) 报错，否则 COW 下语义静默反转。

**范围边界**：参数 move 推断（§7.3，callee 消耗实参 → caller use-after-move 传播）**不在本项**——参数维持 borrow-default，调用永不消耗实参（spawn 闭包捕获除外）；归 B-068/后续。本项纯 checker 层，不改 RC 行为——Perceus escape-clone 在 move 强制后成为可优化冗余（last-use move），留 L3。

**与现有项关系**：B-068（move 标注/lv2/fmt 文档化）的语义前置；B-002（Drop/RAII）依赖本项 move 基础设施。

**验收标准**：
- 判定程序与四类逃逸位置 use-after-move 全报编译错误，含 clone 修复建议；`f(xs, mut xs)` 编译错误
- 编译器自身（31 文件）在新 checker 下编译通过（迁移完成）+ double bootstrap 一致
- JS 全量 + llvm_diff 全绿

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

### B-007 `async` Effect + 结构化并发（设计已确定 2026-05-23）[feature] [P2] [XL] [judgment] [queued] [deferred: B-116]
async 作为 effect，handler 决定执行策略。Generator-based 实现（**JS 后端**），支持 sync handler（测试场景）。**native 实现模型未定——挂起超出 tail-resumptive 表达力 → 前置 B-116 design-probe（2026-06-11），probe 出方案后本 spec 补「native 实现策略」节再动工。**

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

### B-107 泛型 Map key（Hash trait + derive）[feature] [P2] [L] [judgment] [queued]

> 2026-06-07 立项（Discussion）。**类型系统说谎的缺口**：`std/map.ring` 的 `Map<K,V>` 类型层全泛型（`get(key:K)`/`insert(key:K,..)` 用类型变量 K），类型检查器放行 `Map<Int,T>`/`Map<MyEnum,T>`，但 runtime（LLVM `unordered_map<std::string,void*>`、JS 同样 Str-key）只兑现 Str key。非 Str key 静默错误，**两后端皆有，LLVM 上具体化**。bootstrap 阶段编译器自身的 Map 几乎全是 `Map<Str,...>` 故未暴露（migration diary 记录的简化）。

**设计方向**：加 `Hash` trait + derive，镜像现有 Eq/Ord/Clone/Debug 的 derive 机制；runtime Map 改为 key 为 void*，经 Eq/Hash dict 派发——**复用 `List.contains` 已走的 `ring_get_builtin_dict` 泛型 Eq 派发路径**。与 B-080（标量 unboxing）协同：Int unbox 后 hash Int key trivial。

**涉及修改**：
1. `compiler/builtins.ring` / `std/`：定义 `Hash` trait（`fn hash(self) -> Int` 或等价）；内置类型 + 用户 struct/enum derive。
2. `compiler/derive.ring`：Hash derive（同 Eq/Ord 模式）。
3. `ring_runtime.cpp`：Map key 从 `std::string` 泛化为 void* + 自定义 hash/eq（经 dict），或等价方案。
4. `compiler/codegen_llvm_*.ring`：Map 操作传 Eq/Hash dict（同泛型 Eq 派发）。
5. `compiler/codegen.ring`：JS 后端对应（非 Str key 正确处理）。
6. checker：`Map<K,V>` 的 K 要求 `K: Hash + Eq` bound（内置类型自动 derive）。

**验收标准**：
- `Map<Int,T>` / `Map<MyEnum,T>` / `Map<用户struct,T>` get/insert/contains_key 两后端行为一致且正确
- `K: Hash + Eq` bound 缺失时报错
- 现有 `Map<Str,...>` 全部不回归
- 全部 E2E + llvm_diff 通过；自举一致

## 性能优化（愿景：语义驱动的编译优化）

> **核心论点**：Ring 的类型系统（effect + refinement + linear）不仅用于安全性，还为编译器提供其他语言没有的优化信息。性能是 Ring 的核心卖点之一——目标不是"接近 C++/Rust"而是在特定场景**超越**。
>
> 优化分两层：AOT（LLVM 编译期）和 JIT（运行时 PGO），很多优化两层都可以做。
> 前置依赖链：LLVM backend → Perceus RC → 各项优化 pass → JIT（远期）。

> **B-011 LLVM Native Backend 已完成（2026-06-01）** — 前端自举打通：ring.exe 单文件产出与参考编译器字节级一致，多模块端到端跑通，所有 codegen bug + fail/catch 已修（见 `tests/cases/llvm/` 回归套件）。**完整 native 自举的剩余两条验收（二次自举一致性 + native E2E 全过）受内存墙（25.9GB，no-GC）阻塞，已并入 B-012——Perceus RC 是解锁它们的唯一路径。**

### B-079 Perceus Reuse Analysis / FBIP (L3) [feature] [P3] [XL] [judgment] [queued]
就地复用分析（functional but in-place）：`rc == 1` 时 match 解构 + 同尺寸重构 → 就地改写，drop-reuse 配对消除分配。Perceus 的性能核爆点（函数式写法零拷贝：list map、tree rebalance/insert）。含 reuse specialization（为有/无 reuse token 特化函数）+ COW（`rc > 1` 时 clone-on-write，内部优化非用户可见语义）。
- **前置依赖**：B-012（L0 RC 核心）
- **参考**：Koka Perceus reuse pass
- **合法性边界（2026-06-12 D-1 拍板）**：last-use drop / 重用仅限「无用户 Drop impl 且非 `Weak<T>` 目标」的类型（as-if 条款，公理⑥ / design.md §7.11）；Weak 目标与带 Drop 类型钉死 scope-end，不得重用
- **验收**：典型 FBIP 模式（list map/filter、tree insert）生成就地改写而非新分配；基准显示分配数下降；全 E2E + `llvm_diff` 不回归；自举一致；Weak/Drop 用例在 reuse 启用前后输出一致（D-1 锚点）

### B-109 非标量精确-RC（STR/OPTION/CLOSURE/TUPLE）→ 折入 B-104 完整 Perceus RC [folded]

> 2026-06-09 立项（B-080 P0 重测 redirect）→ **同日折入 B-104**（用户拍板完整 total pass + leak verifier，取代 wave 式「按归因修主导漏」打地鼠）。非标量临时（STR 24.3% / OPTION 22.1% / CLOSURE 16.7% / TUPLE 8.4%，G-a 墙 74.5% 主体）是 total pass 要 drop 的 fresh-owned 临时之一 → 由 B-104 统一覆盖，不单列 wave。

**保留并入 B-104 的资产**：
- **诊断工具 DONE**（git `799c600`，保留）：RING_BOX_PROFILE 扩到 STR + OPTION call-site 归因（`ring_enum_some` / `ring_alloc` STR typeid 接 `_ReturnAddress`→IR 站点）——total pass 落地后定位/验证残留漏点的眼睛。
- **两个已知根因 → B-104 回归实例**（total pass + verifier 必须覆盖且 verifier 静态抓到）：① **struct-field 重赋值漏**（`self.pos = self.pos + 1` 存新 box 进 struct 字段、旧 box 不 drop——W4 标量 mut-var reassignment 的 struct-field 兄弟，Lexer/Parser 热路径）② **call-result Option/STR temp 不 drop**（`str_char_code_at` 返 `Some(box_int)`，调用方在 scrutinee/comparison 位不 drop）。**非标量 RC 有别名 soundness 风险（B-101 教训）→ verifier 兜底 + ASan 验，不靠人肉归因猜测。**

### B-080 标量标记指针表示（tagged pointer）— 消残余标量(BOOL+INT churn)+perf [feature] [P2] [XL] [judgment] [queued] [deferred: B-104 完整 Perceus RC 先行]

> **⚠️ 降级（2026-06-09，重测数据推翻原定位）**：原立为「G-a 内存墙真解/唯一结构性解」，前提=「墙=标量装箱」。**两个 range-loop RC 修复 + 3 次重测证伪**：INT 47.8%→1.6% plateau（精确-RC 解决），墙现在 74.5% 是非标量。**B-080 标记指针只消 ~21%（BOOL 19.3%+INT 1.6%）、非墙驱动**。降级为后续优化（消残余标量 BOOL + INT/BOOL alloc churn + 干净标量 repr/perf），**G-a 终解改由 B-104 完整 Perceus RC（total drop pass + leak verifier）承担**。技术内容（标记指针实现配方）仍有效，见下文 P1 实现序 + memory `llvm-debug-state`。

> **进度（2026-06-09）**：
> **P0 决定性诊断 DONE（反预期结果）**——监督式 self-compile（`RING_BOX_PROFILE` 采样侧表）测出：残留存活 INT **97% 集中在 `exhaustive.ring` 一个模块**（`check_matrix` 66.8% + `specialize_row` 26.7% + `finite_type_ctors` 3.8%，全站点 `born==live` 纯泄漏），**不是 spec 假设的多态边界装箱分散**。机制 = `for i in a..b` range 计数器每轮 `box_int` 新装箱、perceus 把 for-binding 统一当借用从不 drop → 每轮漏一个 Int box，exhaustive 递归 checker 迭代量最大故集中爆。标量可兑现幅度 INT 47.8%+BOOL 10.4%=**58.1%**（标记指针上限），非标量 42%（STR/OPTION/CLOSURE/TUPLE）**同样线性泄漏**→ 标记指针单独破不了 G-a，需配精确 RC。轨迹线性无界无 plateau，15GB 时 allocs 1.31B/live 400M。
> **用户拍板（避免第四次误判）：先修 loop-var RC gap 再重测**，不直接上 XL 标记指针。
> **loop-var counter 修复 DONE**（git `15b5318`，`codegen_llvm_stmt.ring` `emit_range_counter_drop`）：range for-loop 在 `incr_bb` 开头 drop 上轮 boxed 计数器（normal fall-through + continue 都经此；perceus borrow→escape dup 平衡 box_int，无双重释放）。残留 break/return 中途退出漏 1 box/loop-run（O(loop)非 O(迭代)，热点不 early-exit 故≈0）。
> **re-measure 确认（scale）**：INT @可比 alloc 减半（~191M→~96M），live 400M→305M（−24%），leak 30%→23.3%，到 15GB 用时 98s→125s（+27%）。但暴露 range preamble **bound box** 新漏：`for i in 1..xs.len()` 把 start 字面量 + `.len()` 结果各 box_int→unbox→不 drop，O(loop 入口) 但 check_matrix 深递归 → 数千万 INT box（修复后 top INT 站点）。
> **bound-box 修复 DONE**（`emit_for_in_range_direct` unbox 后 `emit_drop_value(start_val/end_val)`）：perceus rc_expr(RangeExpr) 一律 rc_escape 边界 → start/end 值总是 owned（字面量/call fresh box，Ident→Clone dup +1）→ unbox 消费后无条件 drop sound（Ident dup rc 2→1 留源变量）。**JS 733 + llvm_diff 53×3 全绿**。
> **combined re-measure（决定性，2026-06-09）→ 里程碑 redirect**：counter+bound 合并后 INT **47.8%→1.6% 且 plateau**（~4.99M 恒定，box-profile check_matrix/specialize_row 站点全消，bound 修复证实有效）。**墙现在 74.5% 是非标量**（STR 24.3/OPTION 22.1/BOOL 19.3[标量,非range驱动]/CLOSURE 16.7/TUPLE 8.4/INT 1.6），墙外推 P0 98s/1.31B→146s/2.147B。**B-080 标记指针只消 ~21%（BOOL+INT）、非墙驱动 → 降级**（见上）。disasm 挖出 2 个非标量根因：①struct-field 重赋值漏（旧 box 不 drop）②call-result Option/STR temp 不 drop。**用户拍板：里程碑转 B-104 完整 Perceus RC（total drop pass + leak verifier，B-109 非标量精确-RC 已折入）**（P0 的 P1 标记指针实现序保留于下，B-080 deferred）。

Int/Bool（及可选 Float）从 uniform-boxed 堆 ptr 改为 **低位 tag 编码进指针大小的字**——标量在**任何位置都不进堆**（局部/临时/结构体字段/容器元素/Option 载荷/泛型槽/dict 槽）。OCaml/V8/LuaJIT 标准做法。uniform 表示完全保留（一切仍是一个字），只是这个字可能是标记标量或真指针。当前 uniform boxing 一切皆 `void*`（含标量：Int=boxed i64、Bool=boxed i1，各带 typeid header）。

> **2026-06-08 拍板标记指针（用户拍板，native on-par 统一规划 P1，见上「native on-par 统一规划」块）。取代原 box-at-boundary 方案**——后者已在工作树实测证伪：
> - **box-at-boundary（inline 标量字段 + 边界 box/unbox）实测不破墙**：未提交的 A1（标量结构体字段 inline i64）跑 native 自编译，`a1d @ 402M` 的 INT = 63.3M ≈ W4 基线 63M——**字段 box 拆了，INT 一点没降** → 残留 INT 根本不在字段里，而在**多态边界**（List<Int>/Option<Int>/泛型/dict/tuple/variant 槽），uniform void* 在那里**必须 box**，inline 字段/加 RC 波都消不掉。a1d 大规模仍 ~30% leak、INT 线性爬（63M→175M@1.2B）、peak OOM。
> - **精确-RC 四波（B-104 W1/W2/W3a/W4）已尽**：四波回收了 Option/Str/容器/BOOL 临时，INT 纹丝不动（W4 隔离测试证明标量重赋值 drop 真工作，但全自编译 INT ~flat → mut-var 重赋值在编译器本就小，函数式 for-in 为主）。残留 INT 绝对主导 = 合法存活/边界装箱的标量。
> - **标记指针是唯一结构性解**：低位 tag 让标量哪都不进堆 → INT/BOOL 堆对象整类、在所有位置一次性消失 → 边界 box 不存在 → 无所谓泄漏还是膨胀。box-at-boundary 是天花板写死的半措施，继续追 = patch treadmill（用户明确拒绝）。

**P0 前置 — 决定性诊断（半天，避免第四次误判）**：给 INT box 的分配点加 **call-site 归因**（不只 typeid），一次性确认残留 INT 是边界 box 泄漏 / 边界 box 合法存活膨胀 / 某具体 RC gap，并扫一遍有无非标量大头被掩盖。无论哪种，标记指针都能解（没有 box 就无所谓泄漏还是膨胀）；诊断只为锁定兑现幅度 + 确认范围，不是另起炉灶。

**核心设计**：
- **tag 约定**：真指针 8 对齐（低 3 位 0），标记 Int = `(n<<1)|1`（低位 1），Bool 同类编码（如 true=`0x3`/false=`0x1` 或复用 int-tag）。`ring_dup`/`ring_drop`/通用 RC op 开头 `if (w & 1) return;`——标量跳过 RC、不查对象头。
- **Float**：暂留 box（编译器里 Float 极少，残留是 INT/BOOL，不挡 G-a）；后续可 NaN-box 或 float-array 特化，独立项。
- **撤未提交的 inline-A1**：标量哪都不 box，字段自然不 box，inline-字段方案被取代 → **B-080 第一步 = 撤掉工作树未提交的 codegen_llvm*/perceus 改动 + 清 a1*.txt/asan*.txt/bis*.txt 实验残留**（git 工作树当前带这批未提交实验）。

**P1 实现序（2026-06-09 推导，de-scope——主要是 RUNTIME 改动，非 150 站点 codegen 契约改）**：标记指针**保留 uniform `void*` 表示**（字 = tagged 标量 or 真指针），codegen 的 uniform ptr 流不变 → **codegen 几乎不动就达 G-a**。两子步：**(1) runtime tag/untag**（`ring_box_int`→`(void*)((val<<1)|1)` 无堆 / `ring_unbox_int`→`(intptr_t)p>>1` / bool 同 / dup/drop 加 `if((uintptr_t)ptr&1)return`）→ G-a（alloc-stats tid0/tid2 直接归零，因 box_int 不再 call ring_alloc）；codegen 仍 call 这些 fn 故不动。**(2) codegen inline tag/untag**（inttoptr/ptrtoint/shift 代 runtime call）= perf 验收项（热路径无 box/unbox），G-a 不需。**难点 = value-op deref 审计**：哪些 runtime op DEREF 可能-tagged 的值需加 tag 处理（dup/drop/unbox/print/eq/compare/hash/list_contains/map/sort）。**省力洞察：tagged-int 编码双射 → 两 tagged-int「字相等⟺值相等」，纯 word 比较的 eq 天然对，只有 DEREF（读 payload/header）才崩**。**审计法 = 改完核心 6 函数跑 llvm_diff 53 经验性暴露**，逐个修。**⚠️ 注：曾误判为 box-at-boundary 全 SSA unboxing（改 gen_llvm_expr 返回契约 150 站点）→ 错，已撤工作树地基（box_value/unbox_value/llvm_repr_type 未提交、已 checkout）。** Float 暂留 box（real ptr bit0=0 → dup/drop 不跳 → RC 正确）。

**涉及修改**：
1. `ring_runtime.cpp`：ring_dup/drop/eq/print 等 RC/通用 op 识别低位 tag，标量不进 RC/堆；与外部 C ABI 交界处（Map key、FFI）按需 box/unbox；alloc-stats 标量计数归零。
2. `compiler/codegen_llvm_expr.ring` / `_stmt.ring` / `_decl.ring`：Int/Bool 字面量、算术、比较、condition 产标记字；字段/容器/Option/泛型/dict 槽直接存标记字（无 box/unbox）；ptr 解引用前按需 mask；condition lowering 用 i1（comparison 产 i1，不经 box）→ **condition-Bool 泄漏随之消失**（折入本项，原 W4 [观察]）。
3. `compiler/perceus.ring`：scalar-typed 值全程不参与 RC（无 dup/drop/Clone）——`is_scalar_type`（W4 已有）扩到全 RC 决策；W4 的 scalar-reassign-drop + inline-A1 的 `is_inline_scalar_field` 在标记指针下变 no-op/删除（标量无 box 可 drop）。
4. `compiler/codegen.ring`（JS 后端）：JS 标量本是原生值，确保双后端 parity（LLVM 新 repr 行为须与 JS oracle 一致）。

**验收标准**：
- 标量（Int/Bool）在**所有位置**不再堆分配（alloc-stats：tid0 INT / tid2 BOOL 归零或趋零，不再线性爬）
- 算术/比较/condition 热路径无 box/unbox/对象头访问
- **condition-Bool 泄漏消失**（i1 比较，无 box 可漏；原隔离测试 `while i<N` 10M 循环 tid2 不再爬）
- 容器/Option/泛型/dict 存取标量行为不变，双后端 parity
- **native 自编译 peak RSS << 25.9GB 且本机可运行**（G-a 判据，counter live plateau）
- 全 E2E + `llvm_diff` 不回归（≥53 例）；double-bootstrap 字节一致；全程 ASan-clean
- **本机可做，native-worktree-unfriendly**（缺 gitignored addon）→ 主仓做，长任务尽早 commit 半成品
- **验证工具链 = B-104 配方**（alloc/free 计数器 `-DRING_ALLOC_STATS`、ASan 链、监督式 self-compile 15GB kill），见 B-104

### B-117 LLVM 函数/参数属性标注（nonnull/nounwind/memory 类）[feature] [P3] [S] [judgment] [queued]

> 2026-06-11 立项（Discussion）。§13.6 要求「LLVM 属性标注从第一天就做」——核实：`llvm_ffi.ring` 已声明 Attribute API，但 `codegen_llvm*.ring` **零调用**。支柱 3（语义驱动性能）当前落地为零，本项是第一块砖：信息 HIR 现成（每 HExpr 带 Type + EffectRow），每函数几行调用。

**涉及修改**（规则基于 §13.6，含一处订正）：
1. 参数级：非 Option 类型 → `nonnull`（uniform boxing 下所有 Ring 值均非空指针）。
2. 函数级：无 fail effect → `nounwind`；仅 fail → 不标（longjmp）。
3. ⚠️ **§13.6「纯函数 → readnone」不可直接照搬**：uniform boxing 下纯 Ring 函数仍调用 ring_alloc/dup/drop（内存效应），裸标 readnone 会被 LLVM 错误优化。需评估 LLVM 22 `memory(...)` 细粒度属性（如 inaccessiblememonly 类）按可证明粒度收紧；先落 nonnull/nounwind 两个无风险项。
4. 时序：B-104 完整 RC 落地后做（避免与 milestone 并发改 codegen_llvm）。

**验收标准**：
- 产出 IR 含属性（抽查 dump）；llvm_diff 全绿 ×3（错标会被 LLVM 优化出错，差分即安全网）；native 自编译产物正常

### B-118 LLVM codegen：Unit 类型值统一 emit null（消 receiver-return ABI 偶然）[refactor] [P3] [S] [judgment] [queued]

> 2026-06-11 立项（B-104 D1 Stage 1 feedback，用户拍板）。D1 规则② 把 Unit 定为类型级不 Clone/不 Drop/不计 owned，但 LLVM runtime mutator（List.push 等 `-> Unit` 函数）ABI 上仍 `return receiver;`——**残留理论洞**：Unit 值流入 RC sink（病态形态如 `[xs.push(v)]` 构造 `List<Unit>`）会把 receiver 裸指针 un-dup'd 存入容器，容器 drop 时 free 活容器。真实代码不出现（mutator 结果存容器无意义），但从根消除 ABI 偶然才闭环——Unit 值不再携带任何可被误当所有权的指针。

**涉及修改**：
1. `compiler/codegen_llvm_expr.ring`（含 stmt 层对应位置）：静态类型为 Unit 的表达式值统一 emit null 常量，不透传 callee 返回值。
2. 时序：**B-104 完整 RC 落地后执行**（避免与 milestone session 并发改 codegen_llvm；同 B-117 约定）。

**验收标准**：
- 病态形态（Unit 值进容器/绑定）双后端行为一致、ASan-clean
- llvm_diff 全绿 ×3（动 codegen 值路径，按 RC 改动纪律跑）
- dist-llvm 自编译正常；自举一致

### B-119 公理⑤做实：推断 fuel 上限 + trait instance 终止性审计 [design-align] [P3] [M] [judgment] [queued]

> 2026-06-12 立项（D-5 拍板，公理⑤「做实条款」①③）。公理⑤承诺「耗时可预期」与「当前系统全部可判定」，两处缺工程兜底/证据。

**涉及修改**：
1. **trait instance 终止性审计（probe 部分，先行）**：核查 checker 的 trait resolution（`trait_impls` 查找/递归 bound 解析）对 `impl Foo for T where Bar<T>: Foo` 类自引用 impl 是否会无界递归——有 Paterson 式结构递减条件或深度上限则记录证据入 lang-design；没有则构造最小复现（负面测试）。
2. **fuel/深度上限（实现部分，依审计结论定范围）**：推断与 trait resolution 加深度/迭代上限，超限 = 编译错误（E 码 + 提示加标注兜底），不允许卡死或不可预期耗时。上限值取「真实代码永不触发」量级（参考 Rust recursion_limit=128）。
3. 负面测试：爆炸/递归构造案例报错而非挂起（带 timeout 的测试 harness）。

**验收标准**：
- 审计结论成文（lang-design §6 或 §10）：终止性有证据，或修复后有上限
- 病态构造（自引用 impl / 深嵌套 let-多态）编译器在上限处报错退出，不挂起
- `npm test` 全绿，无现有代码触发上限

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

**不做的控制力**（2026-06-11 订正：unsafe 两行旧立场撤销，见 design.md §7.12 unsafe 区域图景）

| 机制 | 状态/原因 |
|------|-----------|
| 原始指针 / 手动 malloc | **安全区不做；unsafe 区提供**（§7.12 三栏总账，原语集归 B-106）|
| `unsafe` 块 | **改做**——`unsafe` effect + 两级 discharge（`mod requires {unsafe}` + `unsafe {}`，关键字与 Rust 一致），§7.12 |
| 手动 SIMD intrinsics | 不可移植，由编译器 + hint 处理 |
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

### B-108 native 回归网接入 + build 脚本化 [refactor] [P3] [S] [mechanical] [queued]

> 2026-06-08 立项（Discussion，处理 worker_feedback B-104 #3）。`tests/native_selfcompile.test.mjs` + `tests/native/real_program.ring` 是 native-frontend RC 的唯一回归网（依赖本地 `ring.exe`，fresh worktree 自动 skip），但 `npm test` 默认只跑 `test:e2e` 不含它（`package.json` 有 `test:native` 脚本但未聚合）。native build 链路（main.o → ring_runtime.o → ring.exe）也全手动无脚本。

**涉及修改**：
1. `compiler/package.json`：把 `test:native` 接入聚合 test 脚本（如新增 `test:all` 含 e2e + llvm + native），或文档化为独立验收步骤——native test 依赖本地 ring.exe，不能强制进默认 `npm test`（无 ring.exe 时会 skip 但不该误导为"已验"）。
2. native build 链路脚本化：写一个脚本（npm script 或 `.ps1`）封装 `node dist/main.js build compiler/main.ring --target=llvm --out-dir=compiler/dist-llvm` → `clang -c ring_runtime.cpp -o ring_runtime.o -O2` → `clang dist-llvm/main.o ring_runtime.o -o ring.exe -lmsvcrt`（计数器变体加 `-DRING_ALLOC_STATS`）。
3. 文档化：CLAUDE.md / docs/workflow.md 记录"native 验收需手动 build + `npm run test:native`"。

**验收标准**：
- native 回归网有明确运行入口（聚合脚本或文档化步骤），不再隐式 skip 而误判"已验"
- native build 链路有脚本，不再全手动
- 文档记录 native 验收流程

### B-018 Debugger [feature] [P3] [L] [judgment] [queued]
source-map 支持 + 断点调试。

- **前置依赖**：LSP
- **复杂度**：大
- **优先级**：Phase D/E

### B-111 LLM eval harness：核心赌注测量仪 [feature] [P1] [L] [judgment] [queued]

> 2026-06-12 D-7 拍板：P2→P1——层 0 判据（公理④）的测量仪，地位等价公理⑥的 B-089 锚点；只改优先级，不动排程（B-104 里程碑照旧先行）。
> 2026-06-11 立项（Discussion）。§10.3 五指标至今零测量——「LLM 写 Ring 优于 TS」是项目存在理由，须从信念变数据，且结果反向校准语言面特性优先级（哪类 papercut 真烧 token）。拍板：**对照组 TS only**；**题目从既有 benchmark（HumanEval/MBPP 风格）改编**（防自选偏差，题目分布不由我们控制）。

**形态（MVP）**：
1. **任务集**：15–25 题（字符串/数据变换/小算法/小 CLI），每题 = 自然语言 spec + 隐藏测试套件 ×（Ring + TS）。改编只替换语言表面（std API 名），不改任务实质。
2. **Ring primer**（关键产物，独立价值 = 未来所有 LLM 的标准 onboarding 文档）：~1–2K token 语法速查 + std 签名表。harness 喂 primer——「零训练数据 + 签名即够」是命题本身。
3. **驱动循环**：headless 驱动被测模型——生成 → 编译（Ring 用 `--error-format=llm`；TS 用 tsc）→ 错误喂回 → 重试（上限 N 轮）→ 跑隐藏测试。两语言协议完全相同；每题 ×3 取均值压噪音。
4. **指标**：首次编译通过率 / 到绿轮数 / 隐藏测试运行时错误率 / 总 token（§10.3 前四项）。
5. 被测模型 Sonnet 级（平均 agentic 代表 + 便宜可多跑；顶级模型硬实力会掩盖语言差异）。放 `eval/`，手动触发，不进 CI（烧 token）。

**验收标准**：
- ≥15 题 × 2 语言 × 3 重复跑通，产出指标对比报告
- Ring primer 成文且被 harness 实际使用
- 失败案例归类（语法迁移 / 类型 / effect / std API），形成修缮清单回流 backlog

## 设计验证（Stabilize 前置）

> 非实现任务，而是设计探针。在对应 XL 特性实现前完成，防止特性交互导致事后 breaking change。

### B-106 低层内存原语 + unsafe 区域图景（design-probe）[design-align] [P3] [M] [judgment] [queued]

> 2026-06-07 立项（Discussion）。**design-probe，非实现项**——产出设计决策文档，不写代码。RIIR（runtime C++ STL → 纯 Ring 重写，见「生态策略：RIIR」）的硬前置：用纯 Ring 重写 `std::vector`/`unordered_map`/`std::string` 需要 Ring 能表达裸内存操作（malloc / 指针算术），而设计哲学当前**明确排除裸指针**（「不做的控制力」表：raw pointer / manual malloc 不做）。此张力不解，RIIR 无从落地。

> **scope 扩展（2026-06-11 所有权讨论，用户指示）**：从「RIIR 前置」扩为**「没有一等引用/指针，语言怎么弥补」的系统性图景**。安全区答案已成形（Rc/Weak、arena+index、Span/(offset,len)、mut 参数线程化），残余无解场景 = 零拷贝视图（slice/serde-borrow）、深层可变访问的跨语句持有、自引用结构、RIIR 裸内存——这些是 unsafe 区域要兜的底。产出补充：**unsafe 区域图景**——unsafe 以 effect 形态出现（design.md 6.3 已锚定「unsafe effect = 用户责任」，签名可见 = LLM/审查可定位）、区内提供哪些原语（裸指针/指针算术/region/受控 transmute 候选集）、区边界如何审计、与 Perceus RC 的交互（unsafe 区内对象的 RC 责任归属）。**作为后续目标**，优先级维持 P3。

**要回答的设计问题**（2026-06-11 形态已拍——`unsafe` effect + 两级 discharge + 三栏总账，design.md §7.12 为真值；剩余）：
1. 区内原语集清单：`Ptr<T>`（名称待定）/ alloc/dealloc / read/write/offset / 受控 transmute——由 §7.12 栏 B 四场景（零拷贝视图/自引用/RIIR/FFI）倒推；value types / region effect 候选与之的关系（region 能否作为安全区替代收窄 unsafe 面）。
2. 跨界所有权移交 API（unsafe 指针 ↔ 安全值）+ RC 交互细则（extern type 类型级排除规则的推广）。
3. RIIR 边界划在哪：容器底层 RIIR 收益（自包含 + 对容器内部跑 Perceus reuse）vs 成本（libstdc++ 本就零依赖随 clang 自带、STL 久经考验）是否成立？
4. unsafe 封装库的验收工具：ASan 档位接入、miri 类解释器（远期）。

**产出**：design.md 章节——低层内存原语取舍决策 + RIIR 边界定义。决策后再评估是否立 RIIR 实现项。

**验收标准**：
- design.md 记录低层内存原语决策（提供/不提供 + 形式）
- RIIR 边界明确（哪层 RIIR、哪层永久 C FFI）
- 与 Perceus / linear / 哲学的一致性论证

### B-116 async native 实现模型（B-007 前置 design-probe）[design-align] [P3] [M] [judgment] [queued]

> 2026-06-11 立项（Discussion）。**design-probe，非实现项**。已锁「handler 仅 tail-resumptive + abort」，但 §8 async 需要**挂起**——tail-resumptive 表达不了。JS 后端靠 generator（V8 代做挂起）；native 无答案。B-007（XL）动工前必须先定实现模型。**用户拍板：不预置倾向，probe 中性评估三候选。**

**要回答的设计问题**（三候选，差异 = 挂起在哪层实现）：
1. **Stackless 状态机/CPS（Rust/C#/Koka 路线）**：codegen 把含 async effect row 的函数编译为状态机。核实：与 Perceus 的交互（跨 await 局部搬进状态 struct 如何改写 drop 位置）、effect-多态 HOF 是否需 sync/async 双版本编译、工程量级。
2. **Stackful fiber（Go 路线）**：每任务用户态栈，await = 栈切换。核实：Windows fiber/ucontext 可行性、固定栈预算（`mut` 参数传 caller alloca 指针 → 栈搬迁疑似被锁死，需证实）、FFI 重入、万级 vs 十万级任务上限。
3. **线程池 + 阻塞 await**：是否值得作 (1)/(2) 前的垫脚石交付（结构化 scope + cancellation token 可先行）。
4. 共同项：§8.2 取消语义（cancel-at-await、两 await 间同步代码完整执行）在各模型下的实现；结构化并发 scope 运行时形态；与 tail-resumptive evidence passing 的共存。

**产出**：design.md §8 增「native 实现模型」节（决策 + 否决理由）+ B-007 spec 更新 + 解除 deferred。

**验收标准**：
- 三候选关键风险点逐条**核实**（非纸面比较）：Windows API 可行性 / Perceus 交互 / FFI 边界
- design.md 记录决策；B-007 spec 含选定模型的实现策略

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


### B-113 `return` 在 match arm 表达式位置 [feature] [P2] [M] [judgment] [queued]

> 2026-06-11 立项（Discussion，公理 1 违例簇）。Rust 允许 match arm 内 return，LLM 高频本能写法；Ring 当前拒绝。语义无歧义：含 return 的 arm 类型为 `Never`，与其他 arm 自然 unify（`fail.raise` 已走此路，机制存在）。

**涉及修改**：
1. parser/checker：放行 match arm 内 `return`；arm 类型推为 Never 参与 unify。
2. codegen（JS）：B-022 临时变量方案（含 return 的 block/if 弃 IIFE）扩展到 match arm；与 B-055（labeled block 替代 IIFE）天然协同，可合并实现。
3. codegen（LLVM）：核对 match lowering 对 arm 内 early-return 的 basic block + Perceus return 路径 drop。
4. e2e：JS + llvm_diff（match arm return / 嵌套 match / loop 内 match return）。

**验收标准**：
- design.md/CLAUDE.md「已知限制」删除该条；双后端 e2e 通过；穷尽性检查与 Never arm 共存正确

## 已知 Bug / 技术债

### B-114 HOF 闭包捕 `let mut`：回归锁定 + 过期已知限制行清理 [design-align] [P2] [S] [mechanical] [queued]

> 2026-06-11 立项（Discussion，公理 1 违例簇）→ **同日 Discussion 探针实测证伪前提，缩水为回归锁定项**（B-115 同款过期备忘）。实测：inline lambda 捕 `let mut` 赋值传 `.map()`、named closure 传 `.map()`、`.filter()` 捕 mut——**JS 与 LLVM 双后端全部正确**（写穿语义对，输出 `6 3` / `24 2 2`）。原 spec 猜的两个根因（HOF inline codegen 不走 boxed-capture / effect row 拒绝 `mut<T>`）均不存在。现有 e2e（lambda_closure_effect 等）只覆盖只读捕获，**mut 写穿行为无任何测试锁定**——本项补锁。

**涉及修改**：
1. tests：e2e 一例（HOF 闭包捕 let mut 读写：inline lambda + named closure，map + filter）+ llvm_diff 一例（LLVM 后端 mut-cell 写穿，B-091 机制）。
2. CLAUDE.md「已知限制/语法」：删「`.map()` 闭包不能捕获 `let mut` 变量，改用 `for` 循环」行；同文件「类型系统」段「Refinement `where` 子句只解析不验证」行订正为「struct-field 位 `where` 只解析不验证（W0002）；参数位 `where` 未实现（硬 parse error E0103）；均归 B-001」。
3. design.md 对应描述已由 Discussion 同步（1.2 现状注记），无需动。

**验收标准**：
- 两个新用例双后端通过（不动 RC，llvm_diff 单跑即可）
- CLAUDE.md 两行修正落地
- 全部 E2E + llvm_diff 通过

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

### B-102 native Type-DAG 内存回收：pure Perceus RC（R-clean）[bugfix] [P1] [XL] [judgment] [doing]

> **终态（2026-06-07；正确性本质 done，[doing] 仅余终验）**：B-102 = native Type-DAG RC 正确性。over-free/UAF 链已终结——**Phase 1**（git `1a6b1d7`：perceus `rc_block_inner` owned 集增量可见 + runtime `ring_list_extend` 元素 escape-dup）+ **R-clean**（git `27fe62d`：撤 A1 never-drop + 撤 A2 intern，Type 回 clone-all-escape，dup-on-share 由 clone-all-escape 自动盖全）。native real_program ×3 ASan-clean、JS/llvm_diff ×3 / double-bootstrap 全绿。试错史（A1/A2 为何放弃、四条死路）见 design.md §7.11「Type-DAG RC 试错结论」+ 本条目末归档块。**G-a 内存归 B-104**（归因终订：墙 = incomplete RC 中间临时不 drop + 标量装箱，非 Type-DAG over-free；return-mode 知识缺口已由 B-103 ✅ 补上）。本项 G-a 实测终验在 B-104 后进行，验收参照 = 下方 Phase 2 (rev) 验收标准。

**Phase 2 (rev) — R-clean = Type 正确参与 Perceus RC（机制，2026-06-07 用户拍板，已落地）**：

> 深度设计调研结论（only-read，very thorough，2026-06-07）：Type-DAG 是真 DAG（递归 enum 按名引用、不嵌入 → 深 drop 无限递归风险无）；**纯 RC 靠 working-set 自然 bound 内存**（瞬态随用随放、HIR/env 持有类型按程序规模有界），**不需要 intern**。命门 = dup-on-share 完整性（正是当年 B-098 栽的地方）。可行性 = **YELLOW**（机制对、可 ASan 验，但 dup-on-share 完整性需收敛猎杀）。

- **撤 A1 never-drop 全部 hook**（Type 回到 clone-all-escape，codegen 生成完整递归 `drop_T`）：
  - `perceus.ring:244/432/435`：删 `is_type_dag_type` 判据（Type-typed 排除 Clone/Drop）
  - `codegen_llvm.ring:689/731`：删 `is_type_dag_type_name` skip（emit_drop_functions 改为给 Type-DAG 生成递归 drop_T）
  - `codegen_llvm.ring:815/837`：删 never-drop 注册（emit_drop_registrations 改走正常 drop 注册）
  - `ring_runtime.cpp:115/133`：`never_drop_table` check 保留机制但 Type-DAG 不再注册（或视情清理）
- **补全 dup-on-share（命门）**：每处把**已存在的** Type 子结构存进父 Type 都须 `HExpr::Clone`（ring_dup），与深 `drop_T` 对称。已知关键点 = `apply_subst` 的 `fields: fields` / `variants: variants` 透传（`env.ring`）+ intra-node 共享（如 `make_option_type` 的 `inner` 同进 type_params 与 variant fields，两处都需 clone）。clone-all-escape 对一般类型本就 escape→clone，撤 A1 后 Type 自动走；**但 B-098 当年正是这里没盖全 → over-free**，必须 **ASan 驱动逐点验证**（over-free 在 ASan 下立即现形，同 #134 收敛式猎杀 7 个）。
- **撤掉 A2 intern**（revert `574b92d` + `68a56e9` 的 `UnionFind.intern_table` / `type_intern_key` / apply_subst intern 包裹）——纯 RC 不需要它防内存，且免去 intern+RC 的所有权账风险（命中返别名指针、新 owner 须 dup，167 消费点皆然 = UAF 雷区）。**intern 留作后续纯性能优化另立项**：纯 RC 下 2.51 亿次 malloc/free 有 churn 开销，若致 native 自编译过慢再加回；那时 RC 已正确、intern 命中 dup 的账好补。
- **内存模型**：peak = 同时存活 Type 集（瞬态随 scope-end drop 回收 + HIR/env 持有按程序规模有界），**非累积**。25.9GB 是累积泄漏，纯 RC 下不累积 → 预期 << 25.9GB 达 G-a。
- **风险与退路**：dup-on-share 若撞结构性障碍（IR 承载层 `HStmt::Dup` 只能按名 dup、非-Ident 逃逸无名——§7.11 已用 `HExpr::Clone` 解，需确认覆盖 Type 全部逃逸形态）→ 上报重估；最坏退到 region/escape 分析（方案 E，L3 范畴、工作量更大）。

> **设计依据**：纯 RC 是 Perceus-native 答案（Type 当初被 A1 错误特例排除）；它回收**所有**类型（瞬态 + 非-interned），不像 intern 只去重可达子集。详见 design.md §7.11「Type-DAG 内存回收」。

**涉及修改（Phase 2 rev = R-clean）**：
1. `compiler/perceus.ring`：删 `is_type_dag_type` 判据（244/432/435）→ Type-typed 走通用 clone-all-escape（逃逸 Clone + scope-end drop）。
2. `compiler/codegen_llvm.ring`：删 `is_type_dag_type_name` skip——689/731（emit_drop_functions 改为给 Type-DAG 生成递归 `drop_T`）+ 815/837（emit_drop_registrations 改正常 drop 注册，不再 register_never_drop）。
3. `ring_runtime.cpp`：Type-DAG typeid 不再标 never-drop（`never_drop_table` 机制可保留他用或清理）。
4. `compiler/env.ring`：补全 dup-on-share——`apply_subst` 的 `fields:fields`/`variants:variants` 透传 + 任何共享既有 Type 子结构的点改走 `HExpr::Clone`（命门，ASan 逐点验）；**revert A2 intern**（移除 apply_subst 的 intern 包裹 / `intern_type`）。
5. `compiler/union_find.ring` + `compiler/types.ring`：revert A2 —— 移除 `UnionFind.intern_table` 字段 + `type_intern_key` 及 helpers。
6. native 构建：ASan 变体（`-fsanitize=address`）驱动逐点猎杀 over-free（同 #134 收敛式）。
7. `tests/`：复用 `native_selfcompile.test.mjs` + 新增 over-free 回归 + peak RSS 观测。

**验收标准**：
- native ring.exe 编 `real_program.ring`（print/list/map/str）EXIT 0 + 输出对 **3× 稳定**，**全程 ASan-clean（无 UAF/over-free/double-free）**
- native 自编译推进过 prelude + exhaustive；理想完整自编译
- **G-a：native 自编译 peak RSS << 25.9GB**（working-set 回收；本机监督实测，15GB kill 护机器）
- JS 731×3 + llvm_diff 51×3 零回归；double-bootstrap 字节一致
- Type 语义不变（`types_equal` / 推断 / unification 行为不变）

**注**：native 终验（G-a/b/c 全过）仍归 B-089，本项解锁之。下方为设计史归档。

---
**【设计史归档（缩编 2026-06-11，过程见 git）】** B-101 Wave A 证实白/黑名单是死路——`apply_subst` 族全有 alias-返回 arm（scalar 透传 / `fields:fields` 共享子结构），Type tree 是故意不可变共享的 DAG，函数级粒度判不了 fresh，泄漏侧关不掉；native 实证 UAF 锁定根因 = `ring_dup` 浅 +1 vs `drop_T` 深递归 + `apply_subst` 共享不 dup（同根另一面 = 保守不 drop 的无界泄漏）。方案 (A)（A1 never-drop + A2 intern，否决 B 全子结构 RC / C 逃逸深 clone / D 原则化 escape 分析）一度锁定并落地（A1 git `ade6266`/`bedf4a0`；A2 两版 `68a56e9`/`574b92d`），2026-06-07 因「never-drop 本身不回收内存」（两版 intern 自编译均线性爬 15GB）整体放弃，被 R-clean pure Perceus RC 取代（见上 Phase 2 rev + design.md §7.11「Type-DAG RC 试错结论」，含日后重启 intern 作纯性能优化的三条硬约束）。

### B-104 精确 Perceus RC：drop owned 临时值 → G-a 真解 [feature] [P1] [XL] [judgment] [milestone-dedicated-session] [doing]

> 2026-06-07 立项（orchestrator 监督诊断后定位，用户拍板方案 A）。**G-a 内存墙的真正根因 + 真解**——推翻此前归因。**2026-06-07 定为里程碑、开专门 session 攻坚**（scope 从"收尾"升为多波编译器核心工程，见下「里程碑化」节）。

> **⭐ 重定向（2026-06-09，用户拍板 = 完整 Perceus RC，先读本段，推翻 2026-06-08 收口）**：P0 决定性诊断 + 两个 range-loop RC 修复（counter `15b5318` + bound `40ebf23`）把 **INT leak 47.8%→1.6% plateau**——证伪「精确-RC 已尽 / INT 残留 = irreducible 存活装箱 / G-a 交棒标记指针」：INT 残留是 precise-RC 没盖到的 loop-var 临时（一修就掉），非 irreducible。重测后墙主体 **74.5% 是非标量临时**（STR 24% / OPTION 22% / CLOSURE 17% / TUPLE 8%）+ BOOL 19%；标记指针（B-080）只消 ~21%（BOOL+INT）、**非墙驱动 → 「标记指针 = G-a 真解」被数据推翻**。**真解 = 把 Perceus 做完整**（当前 clone-all-escape 只实现半套：drop named let-绑定 + 逃逸，不 drop 中间临时；wave 式按位置补 = 无完整性不变量的打地鼠）。本 item 转向 **完整 total drop pass + 静态 leak verifier**（设计真值见 design.md §7.11「完整 Perceus RC」节，方案下「完整方案」节）；**B-080 降级**为后续 peak/perf 优化。G-a 经本 item 完整 RC 达成，不依赖 B-080。

**诊断（决定性，orchestrator 监督 native 自编译 + alloc/free 计数器 + per-typeid 分桶）**：B-103 后 native 自编译仍线性爬 15GB。加 `live = allocs - frees` 计数器实测：**live ≈ allocs 几乎 1:1（256M allocs / 232M live = 88% 从不释放）**。per-typeid 分桶 leak 主体：
- **tid=0 INT live=86M + tid=2 BOOL live=43M = 129M（56%）** —— 装箱标量
- tid=8 OPTION 38M、tid=3 STR 30M、其余 LIST/CLOSURE/用户类型若干

**根因（两个系统性问题，非 Type-DAG over-free）**：
1. **RC drop 覆盖不全**：`perceus.ring:is_droppable_init` 只管 `let x=init` 绑定，且 BinOp/UnaryOp/控制流 = `_ => false`（B-103 明令保持不动）。**表达式中间临时值**（`a+b`、`i<len`、`f(g(x))` 的 `g(x)`、call args 的临时）**无绑定、无人 drop** → 全 leak。clone-all-escape 只 drop let-绑定 owned local + 逃逸，**不做 backward-liveness、不 drop 中间临时**——这是 Perceus 核心只实现了半套。
2. **标量统一装箱**（B-080 未做）：每个 Int/Bool 是堆对象 → 把上面的 leak 放大成 86M+43M。

**⚠️ 归因订正**：25.9GB 内存墙**一直是 incomplete RC（不 drop 临时）+ 装箱标量**，**不是** Type-DAG over-free。B-098/B-101/B-102/B-103 修的 over-free 都是真崩溃 bug（必须修）+ R-clean 让 Type 可 drop 是前提，但它们从不是 25.9GB 主因。never-drop（100% leak）→ R-clean+B-103（88% leak）只回收 12%。

**方案 A（用户拍板）= 完整精确 Perceus RC**：
- **drop 所有 owned 值在 last-use**（不止 let-绑定，含中间临时）—— 实现 Perceus backward-liveness drop 插入（Koka POPL'21 核心），当前 clone-all-escape 缺这块。
- **开放 `is_droppable_init` 的 BinOp/UnaryOp/控制流 arm**（其 let-绑定结果是 fresh owned，可安全 drop）。
- 临时值（arg/condition/subexpr 位置的 owned call/BinOp 结果）在 last-use 后 drop（borrow-返回的不 drop——复用 B-103 的 is_borrow_returning_call 分类）。
- **ASan 全程验证无 over-free**（drop 临时不能误 drop borrow——B-103 的分类是前提）；alloc/free 计数器验 live plateau（不再 1:1 爬）。

**（B）标量 unboxing（B-080）= 放大器**：Int/Bool 不装箱 → 直接消 56% leak + 标量分配。但 Option/Str/用户临时仍需 A。A 必须、B 可后续叠加。

**定案（2026-06-07，用户拍板）= A-via-ANF/materialize；否决 B-080-先（「unboxing 只掩盖 bug 不符原则」——真 bug 是 RC 不 drop 临时，unboxing 藏标量症状但 Option/Str/用户临时照漏、RC 残缺照旧）**：
- **α 已做（未提交）**：`is_droppable_init` 开 BinOp/UnaryOp=true。实测对纯 let-绑定零收益 → 证实 **leak 是中间临时（非 let-绑定）**，必须 ANF。
- **核心 = ANF/materialize**：每个 **fresh-owned 中间临时**（BinOp/UnaryOp、非-borrow Call、构造器、StringInterp 在 arg/condition/subexpr 位置）hoist 成最近 statement 的 `let __tmp=expr` → 复用现有 escape-clone + scope-end-drop 回收。**规则**：① 只 materialize fresh-owned（**不碰** Ident/FieldAccess/IndexExpr/borrow-call —— 它们是 borrow，drop 会 UAF）② **不跨短路/分支边界 hoist**（`a&&b` 的 b、if/match 分支值在分支内 materialize，保求值序 + 惰性）③ **loop 条件每轮 materialize + 每轮 drop**（`while c` 的 c 临时不能 scope-end 才 drop）④ escape 由现有 clone-all-escape 处理（materialized 绑定逃逸→Clone，原绑定 scope-drop）。**不重引入 backward-liveness（#134 风险）**——materialize 复用现有机制。
- **dup-on-share 完整性（随临时 drop 激活，已修）**：`ring_list_clone`（f07382d）+ `ring_map_clone`/`ring_map_int_clone`（#135）浅拷 → 深拷 dup 元素/value；`ring_set*_clone` 非 bug（值内联）。后续 ASan 揪出的同类漏 dup runtime 一并修。
- **验证**：native 自编译 **live plateau（alloc/free 计数器，不再 1:1）+ peak << 25.9GB**（监督）+ 全程 ASan-clean（materialize 不误 drop borrow）+ JS 731×3 + llvm_diff 51×3 + double-bootstrap。
- **基础设施注记（2026-06-11 Discussion；同日 milestone session 已判断）**：#20 hir-visitor **D1 阶段不先建**——D1 改造 perceus 现有 anf/rc 遍历，不新增第 6 个全量 HExpr match；通用 visitor 也表达不了 verifier 的位置敏感所有权记账。**D2 动工时重估**，与 Stage 1 提出的 RcCtx 捆绑一并考虑（externs 已以参数线程穿两个 pass ~30 签名，total pass 若继续膨胀则引入 RcCtx）。

## 里程碑化（2026-06-07，专门 session 攻坚 —— scope 从"收尾"升为多波核心工程）

> ANF 实测后发现：materialize **只能安全覆盖"容易类"**（消费位临时 + 字面量），G-a 剩余主体是**需 precise-Perceus 分析的"难类"**——这正是 B-098 为消 #134 简化掉的部分。开专门 session 攻坚，本 session 进展已 durable commit。

**✅ 已完成（durable）**：
- **ANF/materialize 易类**（git `6ec870c` + `f16ffe0`）：消费位临时（BinOp/UnaryOp 操作数、if/while condition、IndexExpr index、StringInterp pieces）+ 字面量（IntLit/StrLit/BoolLit/FloatLit）hoist 成 `let __anf_N` → scope-end-drop。`anf_normalize` pre-pass（perceus.ring）。**避 &&-RHS 别名坑**：字面量经 `anf_operand` 才 materialize，&&/||-RHS 走 `anf_cond_in_own_scope`/`anf_expr` 不 materialize（gen_and/gen_or phi 返 RHS box verbatim）；arg/scrutinee 位走 `anf_arg`（recurse-only 不 materialize，见难类①）。
- **一串 pre-existing 隐崩修复（随临时 drop 激活，必须）**：`ring_list_clone` 浅拷→深拷（`f07382d`）、`ring_map_clone`/`ring_map_int_clone` 同（#135）、`row_merge`/`merge_effects` EffectRow over-free（根因 list_clone 浅拷）、`list_fold` 空表返 init 的 arg-alias double-free（`f16ffe0` 改 `anf_arg`）。α（is_droppable_init 开 BinOp/UnaryOp，排除 And/Or）。
- **✅ W1 — Call 实参 materialize（本 session，git pending）**：`anf_expr` 的 Call arm 把每个实参从 `anf_arg`（recurse-only）改走 `anf_operand`（materialize fresh-owned → scope-end-drop），**仅 `is_arg_returning_call` 的 callee 例外**（保持 `anf_arg`）。**关键收窄**：`is_arg_returning_call = {fold}` 仅一项——一个 arg 不安全 materialize ⟺ callee verbatim 返回它**且结果未被 Clone-wrap**（callee ∉ `is_borrow_returning_call` → 结果 move）。`fold` 空表返 init 且结果 move（不能进 borrow-returning，非空表返 owned 闭包结果会泄漏）→ 必须分类；`unwrap_or` 返 default 但 ∈ borrow-returning → 结果被 Clone-wrap、那个 dup 平衡 materialize 的 arg → **安全无需分类**（real_program 的 `.unwrap_or("?")` native + ASan 实证）。scrutinee + EffectOp args 仍保守（`anf_arg`，见剩余①）。
- **实测（同 alloc/free 计数器、同输入、同里程碑严格对比，本 session）**：**订正此前乐观的「~50%」——ANF 易类基线（pre-W1 HEAD）实为 ~69% leak**（@268M allocs）。进程实为 **88%（R-clean+B-103）→ ~69%（ANF 易类）→ ~52%（W1）**（@268M）。W1 同 alloc 里程碑削 ~16pp（@268M）至 ~29pp（@33M，早期）。**逐 typeid**（@402M）：INT 106M→75M（−31M，Call-arg int 临时回收）、STR 略降；**OPTION 65M→66M 几乎未动 → 证实 OPTION 大块在 scrutinee 位（`match map.get(k){...}`），W1 未覆盖 → W2 目标**。验证：JS 733 / llvm_diff 52×3 / native harness 3/3 EXIT 0 / ASan real_program + self-compile(13GB) 全 clean（零 over-free/UAF）。
- **✅ W2 — MatchExpr scrutinee materialize（本 session，git pending）**：`anf_expr` 的 MatchExpr arm 把 scrutinee 从 `anf_arg` 改走 `anf_operand`（materialize fresh-owned Option scrutinee → scope-end-drop）。**关键发现：无需 match-arm return-value 分析**——backlog 原担心的 `_ => scrut` double-free 已被 clone-all-escape 中和：match 在 escape 位时每个 arm tail 单独 rc_escape，返回 scrutinee（`x=>x`）/ pattern 绑定（`some(v)=>v`，scrutinee 内部投影借用）/ 任何 owner-bearing 投影都被 Clone-wrap（ring_dup）→ 结果绑定持 fresh dup、scrutinee 的 scope-end Drop 释放原件，平衡（dup 在两次 drop 前 bump，drop 序无关）；非 escape 位则 arm tail 是借用、无人取所有权，单次 scope-drop 仍平衡。与 W1 unwrap_or 同源的 Clone-wrap 平衡。逐案验证 + ASan-clean（real_program matches + self-compile）。仅 fresh-owned scrutinee materialize（Ident/FieldAccess/IndexExpr scrutinee 是借用、保持 inline）。
- **W2 实测**：**leak ~52%→~39%（@268M），且轨迹由爬升转平稳下降（42%→38%@33M→402M，近 live plateau）**。**OPTION 65.8M→22.6M（−65%，scrutinee 回收兑现）**、INT 75M→64M。W1+W2 合计 ~69%→~39%@268M（近腰斩）。验证：JS 733 / llvm_diff 52×3 / native harness 3/3 / ASan real_program + self-compile(13GB) 全 clean。
- **✅ W3a — control-flow-init droppable（branch-value 分析，本 session，git pending）**：`is_droppable_init` 对 IfExpr/MatchExpr/Block 递归判 droppable（新 `is_droppable_branch_value`）——每个**非发散**分支 tail 自身 `is_droppable_init` 才算（分支 tail 在 escape 位经 rc_escape → owned，同 B-103 Call=true）。**关键：非 blanket-true**——分支 tail 若是 `&&`/`||`（gen_and/gen_or phi 返 RHS box verbatim，可能借用，rc_escape 对 And/Or 是 move 非 Clone）→ `is_droppable_init(And)=false` → 整 If 不可 drop（正确保守，否则 `if c{a && obj.field}else{d}` drop x 会 over-free obj.field）。发散分支（return/break）不产值、不约束。EffectOp/Handle/TryCatch 仍 false。这就是 backlog 担心的「branch-value 分析」，递归 bottom-out 在 per-expr 分类。
- **W3a 实测**：**leak ~39%→~33.5%（@268M）/ ~31.7%（@402M），轨迹更强平稳下降（42%→30%）**。BOOL 27→18M、OPTION 22.6→18.7M、STR 19→13.4M（control-flow 各类临时回收）。**但 INT 卡死 64M（W1:75→W2:64→W3a:64，三波纹丝不动）且随 allocs ~线性增长** → INT 不在 Call-arg/scrutinee/control-flow 位。验证：JS 733 / llvm_diff 52×3 / native harness 3/3 / ASan real_program + self-compile(13GB) 全 clean。
- **✅ W4 — scalar mut-var reassignment drop（2026-06-08，git `4fe2bef`）**：`rc_stmt` Assign arm 对持标量（Int/Bool/Float）的 plain（非 auto-boxed）mut 变量，重赋值时 materialize RHS（已 escape）→ Drop 旧值（按源 `name`，匹配 named_values keying + emit_assign `name` 回落）→ store。新增 `scalar_reassign_drop_name`/`is_scalar_type`。**安全性**：标量值语义无内部别名、重赋值点无跨语句借用、跨语句持有者皆 clone-all-escape dup → 旧 box rc=1 释放（回收泄漏）/ rc>1 递减（共享者有效）；ring_box_int 无 interning、INT/BOOL/FLOAT 非 never-drop。**顺序关键**：RHS 先 materialize（可能 self-read `x=x+1`），再 drop，再 store（drop-first=UAF）。排除：auto-boxed cell（B-091 共享指针）、非标量 lvalue（内部别名留后续波）。
- **W4 实测 + 决定性发现**：**隔离计数器测试（10M 循环 `i=i+1`）tid0(INT) 恒定 4 → W4 确实工作**；但**全自编译 INT @402M 64M→63.4M（~flat）、leak 31.7%→30.6%（@402M）/ 33.5%→32.6%（@268M）、peak 仍 OOM**。→ **编译器自身极少 `while; i=i+1`（函数式 for-in 为主）→ ① 本就小 → INT 主体确为 ② 合法存活装箱标量（Span/id 字段）→ 数据再次确证 B-080 unboxing 是 G-a 真杠杆**。验证：JS 733 / llvm_diff **53**×（新增 `scalar_reassign_drop.ring` 锁共享 rc>1 边界）/ ASan 探针（共享 rc>1/bool/float/self-read）exit 0 输出全对 / real_program ASan clean / native 自编译 ASan **0 error**（12GB OOM=已知 G-a 泄漏）。**另发现**：while/if condition-result Bool box 未 drop（隔离测试 tid2 爬 10M），独立于 W4 的 precise-RC gap，记入 [观察] 待定。

**剩余（⚠️ 下方 1-2 条的「INT 唯 B-080 解 / 精确-RC 已尽」结论已被 2026-06-09 redirect 推翻——range-loop 修复证明 INT 是 loop-var 临时非 irreducible；保留作 W4 时的演进记录，权威方案见顶部 redirect + 下「完整方案」+ design.md §7.11）**：W1+W2+W3a+**W4** 后 leak ~30%@大规模，轨迹强平稳，但 peak 仍 OOM（>15GB）。当时判断残留主导 = INT 63M（标量装箱）：
1. **INT 不可由临时-materialize 回收（已证）**：三波（Call-arg/scrutinee/control-flow）回收了 OPTION/BOOL/STR/容器临时，INT 不动。INT 来源 = ①**mut-var 重赋值泄漏**（`x = x+1` 按 L0/L1 约定泄漏旧 Int box，loop 计数器尤甚——可由「scalar 重赋值 drop 旧值」精确化，标量值语义不共享、安全）②**合法存活装箱标量**（HIR/AST 节点的 Span.start/end、def_id、type-var id 等 Int 字段，随程序结构存活）③ receiver/And-Or/EffectOp 残余（小）。①②**唯 B-080 标量 unboxing 根除**（Int/Bool 不装箱 = 无堆对象 = 无泄漏无装箱开销）；①另可由精确-RC 的 scalar-reassign-drop 子波部分回收。
2. **结论（数据支撑，W4 已收口 ①）**：精确-RC 四波（W1/W2/W3a/W4）已尽——W4 隔离测试证明标量重赋值 drop 真工作（INT 恒定），但全自编译 INT ~flat 证实 ① 在编译器本就小（函数式 for-in 为主），残留 INT 63M 绝对主导 = ② 合法存活装箱标量（HIR/AST 的 Span.start/end、def_id、type-var id 等 Int 字段，随程序结构存活）。②**唯 B-080 标量 unboxing 根除**（Int/Bool 不装箱 = 无堆对象）。**精确-RC 单独到不了 G-a 是四波数据结论 → 下一杠杆 = B-080，不是更多 materialize/scalar 波。**

**完整方案（2026-06-09 用户拍板，取代上「剩余/结论」的「交棒 B-080」——设计真值见 design.md §7.11「完整 Perceus RC」节）**：

W1/W2/W3a/W4（手工按位置版）收编为**一个完整 total drop pass + 静态 leak verifier**，做完 garbage-free by construction：

- **D1 — total return-mode drop pass**：每个 **fresh-owned 临时**（子表达式产 owned 且父节点借用/丢弃）在 last-use 后 drop，**统一覆盖所有子表达式位置**（arg / scrutinee / condition / receiver / subexpr / control-flow-init），不再一波一位置。地基 = **B-103 完整 return-mode 分类（✅ 2026-06-11 done，git `dba4054`/`261943e`/`ded9fd3`）**：ring_runtime.cpp ~170 个 extern fn 全量分类表（FRESH ~95 / BORROW = Option 投影 4 + 元素直读 3 + receiver-returning mutator 9 字段名 / SCALAR ~40 / NULL-NEVER ~15，含逐函数源码证据）落 `perceus.ring` `is_borrow_returning_call` 上方注释；`is_arg_returning_call` 审计 `fold` 仍唯一；runtime dup-on-share 补全 ×9（filter/concat/slice/reverse/sort/sort_default/map_from/map_int_from/flat_map，UAF 方向 + pre-fix 实证）。临时天然单次使用 → "何时 drop" 是 per-subexpr 局部判定（父消费→不 drop，父借用→用完 drop），**不需 owned-everywhere 的 per-path 平衡 → 不重蹈 #134**。
- **D1 内置规则（2026-06-11 用户拍板，B-103 Wave A feedback 折入）**：
  - ① **extern-handle 类型级 RC 排除（audit #139，D1 正确性硬前置）**：`llvm_ffi.ring` 59 个 extern fn 返回非 ring_alloc 的裸外来指针（无 RC header），HIR 类型 = extern type → **不 Clone / 不 Drop / 不入 owned / 不 materialise**（类型级排除，非 59 名字白名单——FFI 增长会漂移）。现 dormant（仅 B-099 native-编译器跑 `--target=llvm` 触发），但 D1 total drop 会系统性 drop arg/subexpr 位 call 结果 → 必然引爆，须先行。
  - ② **Unit 类型级规则**：UnitType 值不 Clone / 不 Drop / 不计 owned（checker 已证 Unit 无值语义，JS 后端返 undefined，LLVM receiver-return 是 ABI 偶然）——叠加于（并消除）B-103 的 9 个 mutator 字段名分类的 leak-side 误伤（用户同名方法返真值被多 Clone + fn-tail mutator 结果 Clone pin 容器）。
  - ③ **IndexExpr 按 receiver 类型精化**：`str[i]`（`ring_str_get`）实为 FRESH（新 alloc 单字符串）但现走 IndexExpr borrow arm 多 Clone（leak-side）→ Str→fresh、List/Map→borrow。
  - ④ **runtime overwrite/remove 泄漏类配套（✅ 2026-06-11 Stage 3，git `3830d59`/`366add9`/`26aadf1`）**：`list_set`/`map_set`/`map_int_set` 覆写旧值不 drop、`map_delete`/`map_int_delete`/`*_clear` 族不 drop 旧元素、`map_from` 重复 key 泄 dup——crash-free leak，D1 配套 runtime drop（verifier/计数器可见）。sink "add"（Set.add/SB.add 拷值）的多 dup 随 ② 一并消。**落地注**：store/erase-then-drop（rc>1 共享者只递减）；Map key 值内联核实（无 key 账）；`ring_set_clear`/`set_int_clear` 审计 RC no-op（值内联）；llvm_diff +3 例（overwrite_drop_rc / remove_clear_drop_rc / map_from_dup_key）；自编译 @2.382B 与 Stage 2 持平 14.1%（编译器自身无覆写/clear 热路径，收益在用户面 + D2 账目完备）；撞出 #138 实测命中（Set.clear 双形态 panic-stub，已追加精化）。
- **D2 — 静态 leak verifier**：post-RC HIR 线性检查——owned 恰好消费一次（逃逸/return/drop）+ drop 非 borrow。通过 = **编译期证明 0 泄露 + 0 UAF**，不通过 = 指出漏点。挂 `npm test`（`--verify-rc`）；兼作 total pass 重写的编译期 UAF 安全网。**这是「保证 0 泄露」的机制。**
- **D3 — 0 泄露范围** = 无环 by-construction + 环用 `Weak<T>`（§7.9，不引入 cycle collector）；自举（HIR 树/DAG 无环）= 字面 0。
- **B-080 降级 peak/perf**（只消 ~21% BOOL+INT 装箱 churn、非墙驱动）；condition-result Bool box 由 D1 drop，不再依赖 B-080。
- **B-109（非标量精确-RC）折入本项**：非标量临时（STR/OPTION/CLOSURE/TUPLE，墙主体 74.5%）是 D1 要 drop 的临时之一，不单列 wave。保留 B-109 的诊断工具（box-profile STR/OPTION，git `799c600`）+ 两个根因作 **回归实例**（① struct-field 重赋值 drop-old ② call-result Option/STR temp drop）——verifier 须静态抓到、ASan 须验无误 drop borrow。

**执行序（worker 接棒）**：~~B-103 完整 return-mode 分类~~（✅ 2026-06-11 done，条目已删，成果见上 D1 地基注）→ **D1 total drop pass（推进中：内置规则①② ✅ 2026-06-11 Stage 1，git `bfd4fe6`..`b62423b`，#139 → resolved + 9 mutator 名退役；规则③ + total pass 收编 ✅ 2026-06-11 Stage 2，见下；规则④ ✅ 2026-06-11 Stage 3（git `3830d59`..`26aadf1`，runtime-only，详见 worker_feedback「B-104 D1 Stage 3」组）；剩 Stage 3 清单 #150 修复 + bookkeeping，见下）**（收编 W1-W4，统一覆盖所有子表达式位置）→ D2 leak verifier（挂 `npm test`）→ native re-measure（verifier 全绿 + live plateau + peak << 25.9GB）。每改一类 → JS + llvm_diff ×3 全套 + ASan + verifier。**native-worktree-unfriendly（主仓做，长任务尽早 commit）**。

**✅ Stage 2 done（2026-06-11，git `81c43be`..`98eb25b`，8 轮各自全门验证 + 独立 commit，详见 worker_feedback「B-104 D1 Stage 2」组）**：规则③（Str-IndexExpr=FRESH，runtime 核实 ring_str_get 新 alloc）+ ANF 可达位置全收口——receiver（FieldAccess/IndexExpr，lexer char_at-Option 类）/ ForIn iterable（RangeExpr 特例保留 inline）/ IfLet scrutinee / LetDestructure init（RC 端 escape→borrow，消 Clone-pin）/ ExprStmt 丢弃值 / EffectOp args（handler-tail escape-Clone 平衡）+ 两个 codegen 级位置——while-cond/guard 结果 box（post-unbox drop + hir.ring 共享谓词 `is_fresh_owned_bool_value`；隔离 1M-while BOOL live 1,000,001→3）/ Set 迭代转换 list。**两个新不变量**：dropping-block tail-escape（修 W2-era ASan 实证 UAF：cond-block 内 match 投影悬垂）+ unknown-ownership 守卫（TypeVar/ErrorType 不材料化不 drop——#149 过度泛化洞的 RC 侧防线，ASan 双向实证）。llvm_diff 57→65 例。**自编译 @2.382B 里程碑：基线 15.3%（live 364.7M）→ 14.1%（336.3M，−28.4M）**；主收益 = OPTION −13M（receiver）+ BOOL −1.5M（cond）；**残余 = STR 86.5/BOOL 67.8/CLOSURE 63.8/OPTION 61.1/TUPLE 31.9M，其中 CLOSURE+TUPLE 疑似 #151（codegen 合成 Eq/Ord dict，HIR 不可见——D1 收编范围外，需独立收口或 dict 全局缓存），且 live 计数含合法存活（AST/HIR/env），纯泄漏量化要等 D2 verifier**。新开 audit：#148 join 堆溢出（oracle 盲区）/ #149 未标注 fn 返回过度泛化 [high]（checker 根修）/ #150 fold 空表 verbatim-init（已拍板，修复入 Stage 3 清单）/ #151 dict 合成泄漏。

**Stage 3 清单（2026-06-11 Discussion 拍板）**：
1. ~~**规则④** runtime overwrite/remove drop~~（✅ 2026-06-11 done，git `3830d59`/`366add9`/`26aadf1`，成果见上 D1 内置规则④落地注）。
2. **#150 修复（拍板 = runtime dup + fold 退役）**：`ring_list_fold` 空表路径 `ring_dup(init)`（B-103 dup-on-share ×9 同模式）+ `fold` 退役出 `is_arg_returning_call`（分类表清空 → `anf_arg` 保守机制整个删除，W1 实参材料化全覆盖）。修后同步 audit #150 状态；决策依据见 design.md 附录决策表「fold 空表 verbatim-init 修复方向」。
3. **bookkeeping**：CLAUDE.md「开发约定」补 **dist-llvm rebuild 纪律**行（与 dist/ 同级——merge 后重建一并 amend 进 merge commit；源自 Stage 2 [观察]：维护 wave `b19c85b` 改 lexer 未重建 dist-llvm，Round A 补上）。

**D1 保守保留清单（Stage 2 收口后的残余位置 = D2 verifier 对照表；归档自 worker_feedback 2026-06-11）**：
- StructLit/NVC spread 源（codegen 裸字段指针拷贝，材料化即 UAF）——保守正确，待 D2/后续核定承接方式
- fold 实参（`anf_arg` 唯一余户——#150 Stage 3 落地后退役，本行随之消）
- Call-callee 自身为 Call 的形态（罕见，残余泄漏方向）
- And/Or 结果与非 while/guard 位的控制流丢弃值（phi 可能 verbatim 借用，泄漏方向）
- TypeVar/ErrorType 类型值（unknown-ownership 守卫，#149 根修后守卫仍留作防御纵深；不变量见 design.md §7.11）

**工具（每波 ASan + alloc/free 计数器 + peak RSS 监督）**：alloc/free 计数器（`ring_runtime.cpp` 已带 `-DRING_ALLOC_STATS` 守卫的 `g_allocs`/`g_frees`/`g_live_tid[4096]` 在 ring_alloc/ring_drop，每 32M 打印 top-typeid + atexit）+ ASan 配方（B-102：`clang -fsanitize=address -D_DISABLE_STRING_ANNOTATION -D_DISABLE_VECTOR_ANNOTATION`，runtime DLL 在 `<llvm>/lib/clang/22/lib/windows` 入 PATH）+ native 重建链 `node compiler/dist/main.js build compiler/main.ring --target=llvm --out-dir=compiler/dist-llvm` → `clang -c ring_runtime.cpp -o ring_runtime.o -O2 [-DRING_ALLOC_STATS]` → `clang compiler/dist-llvm/main.o ring_runtime.o -o ring.exe -lmsvcrt` + 监督 self-compile 15GB kill 护机器。typeid 速查：0=INT 2=BOOL 3=STR 4=LIST 7=CLOSURE 8=OPTION 10=TUPLE 64+=user。

**W4 顺带发现（2026-06-09 改归 total pass）**：while/if condition-result 的 Bool box 未 drop（隔离测试 tid2 随循环次数线性爬）——这正是 total pass 要 drop 的 **condition-位 fresh-owned 临时**（D1 覆盖 condition 位）→ **由完整 RC drop**，不再依赖 B-080。BOOL 装箱本身的 churn（非泄漏）仍可由 B-080 unboxing 后续消（comparison 直接产 i1）。



**验收标准**：
- **leak verifier 对编译器自身静态全绿**（证明 0 泄露 + 0 UAF）——「保证 0 泄露」的判据；构造已知 leak/UAF 用例断言 verifier 报错
- native 自编译 **live plateau（不再 allocs:live 1:1）** + peak RSS **<< 25.9GB**（监督实测，15GB kill 护机器）
- 全程 ASan-clean（临时 drop 不误 drop borrow——B-103 分类是前提）
- JS 733×3 + llvm_diff 53×3 零回归；double-bootstrap 字节一致
- verifier 挂进 `npm test`，回归防 RC 退化
- native 自编译完整跑通

**依赖**：B-102 R-clean（✅ Type 可 drop）+ B-103 完整 return-mode 分类（✅ 2026-06-11，分类表落 perceus.ring，git `dba4054`）。解锁 B-102 G-a + B-089。这是 Perceus L0/L1 核心的**完整**实现（total drop pass + garbage-free verifier）。

### B-089 Native 自举终验 capstone [bugfix] [P1] [L] [judgment] [queued]

> **native on-par 统一规划 P2（2026-06-08）= Level 1 终点**：依赖 **B-104 完整 Perceus RC（G-a 真解，total drop pass + leak verifier）**落地后启动（2026-06-09：原写 B-080 标记指针，已降级；G-a 改由 B-104 完整 RC 达成）。三门走 **js 路径**（native 自编译产 JS dist 与 node 版一致）。**B-099 显式 out-of-scope**——Level 1 不要求 native 自产 .o（产 .o 仍可借 node），B-099 是 Level 1→Level 2 分界，deferred。验收门以下文「合 B-012 遗留」为准，唯依赖从 B-102 改为 B-104。

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

> **= Level 1→Level 2 分界（2026-06-08 native on-par 统一规划）**：**不在 on-par Level 1 范围**。Level 1（B-080+B-089）做到 native 前端+JS 后端与 node 版对等；本 item 是「native 自产 native 代码 / Node 彻底消除 / JS 后端归档」的 Level 2，用户本轮拍板暂不走。保持 deferred。

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
- **extern-handle RC 排除 runtime 级终验**（原 audit #139 修复的真实 runtime 验证，git `bfd4fe6`..`b62423b`：native 自跑 `--target=llvm` 全程无 handle dup/drop 损坏；audit #140/#146/#147 latent 路径届时一并复核）

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
- **oracle 盲区 native-only 语义测试（2026-06-11 增）**：归档前为已知差异角落补 native 侧手写期望值测试——I64 全宽度（±2^63 边界）/ 整数溢出（debug panic / release 回绕）/ 整数除零 panic / UTF-8 code point 索引 + `byte_len`。这些角落 JS oracle 本身失真（±2^53 / 静默 float / Infinity / UTF-16），差分测不了，归档后再无任何安全网

**已知取舍**：层 3 codegen 失去活差分 oracle，靠手写 E2E 期望值 + golden 回归验证（(Z) 策略的代价，已确认接受）。

### B-105 增量编译（per-module .o）[feature] [P3] [XL] [judgment] [queued] [deferred: native-primary]

> 2026-06-07 立项（Discussion，从 migration diary 未登记债转入）。**deferred**——gate 在「native 成为主工具链（B-099 之后）+ 编译时间成实测痛点」。不阻塞 B-089/B-099/B-100。

**现状**：`generate_llvm_project`（`codegen_llvm.ring`）把所有 .ring 编进单个 LLVM Module → 单 .o。当初为省跨模块符号解析（migration diary 记录的简化）。

**核心设计难点（非工程量，是设计未解）**：Ring 对泛型做单态化。模块 B 用模块 A 的泛型函数 → 该实例化版本 emit 在哪个 .o？（Rust/C++ 模板实例化经典问题）。外加跨模块 struct 布局 / trait dict / enum tag 一致性。真正难的是跨模块单态化，不是 link。具体方案（实例化放使用方 vs 独立 codegen unit）等真要做时单独 Discussion。

**涉及修改**（方向，待细化）：
1. `compiler/codegen_llvm.ring`：每 .ring → 独立 Module → 独立 .o；跨模块单态化策略。
2. 链接：多 .o 链接（符号 mangling 已有 `ring_` 前缀基础）。
3. 跨模块类型 / dict / enum tag 一致性保证。

**验收标准**：
- 改单文件只重编该文件 + 受影响的单态化实例
- 多 .o 链接产出与单 Module 行为一致
- 全部 E2E + llvm_diff 通过；自举一致

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
