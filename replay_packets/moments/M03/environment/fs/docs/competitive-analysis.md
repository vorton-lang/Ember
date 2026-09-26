# Ring-lang 竞品与行业定位

> 最后更新：2026-06-11（增量节，深度研究三票对抗验证）；全景基线 2026-05-22。数据来源：官方 GitHub、官网、科技媒体报道。

## 2026-06-11 增量：窗口期评估（深度研究，21 源 / 25 主张三票验证 / 4 否决）

**窗口期分层判断**：
- **机制窗口（核心组合）≥ 2-3 个季度**：「全推断代数效果（io/fail/mut/async）+ HM 零标注 + Perceus RC native + 自举」截至 2026-06-11 无人在做或宣布。三个最近邻方向各异且均非此路：MoonBit 向**显式标注**移动（反向）、Zero 押**显式 capability + graph-native**（反面）、Mojo 只打类型安全牌（无 effect）。
- **叙事窗口以月计**：Mojo 26.2（2026-03-19）已官方采用「编译期报错 = 省 LLM token」话术；Zero 被二级报道贴「explicit effects」标签。「签名即 LLM 行为契约」的话语权正被相邻叙事侵占——先发证据（可运行 native + 量化 benchmark）比机制本身更紧迫。
- **native 已从差异化变入场券**：同一周（2026-06-08）Zero v0.3.0 加实验性 LLVM 后端、MoonBit v0.10.0 加 native 后端。

**逐对象事实更新（全部已验证，区分发货/宣称）**：

| 对象 | 增量事实 | 对 Ring 威胁 |
|------|----------|--------------|
| **MoonBit** | 1.0 **滑期 Q3 2026**（官方 v0.10.0 notes 改口，原 H1）；v0.8.0 **弃用局部 fn effect 推断、改显式标注**（与 Ring 全推断**反向**）；1.0 路线图选 Kotlin 式协程而非代数效果；fd-leak 检查是运行时开关非类型级；Pilot 仍是工具链牌（零类型系统牌） | 机制威胁**下调**（effect 维度反向移动）；工程成熟度威胁维持中 |
| **Zero** | 动量强劲：25 天 10 版本、4,972 stars、1,057 commits（GitHub API 实测非自报）；v0.3.0 起 **graph-native**（`zero.graph` 语义图是编译器输入，.0 文件仅人类投影，agent 经 `zero query/patch` 对图做 checked edits）+ **实验性 LLVM 后端**；World capability 维持显式传递，无任何 effect 推断演进迹象 | **高**（叙事+动量+Vercel 品牌）；机制是不同的 LLM-first 赌注：「agent 直接操作语义图」vs Ring「签名携带语义」 |
| **Mojo/Modular** | 26.2（03-19）官方 token-economy 叙事 + agent skills（可装 Claude/Cursor/Codex）+ 750K 行开源 kernel；26.3（05-07）Mojo 1.0 Beta 1；Phase 1 仍明确限 GPU/CPU kernel | 叙事最近邻 + 大厂资源（**中**）；定位不重叠（**低**） |
| **TypeScript 7** | Beta 2026-04-21（tsgo），官方计划「两个月内」stable（即 ~6 月，RC 先行数周）；截至 06-11 **RC 未发**，可能小幅滑出 6 月；VS 2026 18.6 Insiders 已默认启用 Beta | 「够用就行」主向量，**极高**（不变） |
| **OpenAI×Astral** | 2026-03-19 收购协议（并入 Codex 团队），**未交割**（待监管）；自述方向 = 开源工具与 Codex 深度整合 | Python「够用就行」最强确认，**高** |
| **学术** | arXiv 2507.22048：effect handler 用于 LLM 脚本**编排**（OCaml，LLM 调用/IO/并发作为效果）——方向是编排非语言设计；「effect 签名帮 LLM 写代码」**未被学术抢注** | 低；交叉研究已开始出现 |

**覆盖缺口（验证管线空集 ≠ 确认无动态）**：Koka/Effekt/Flix/Unison/Scala caprese/OCaml effects 的 Q2 动态、4-6 月其他大厂/初创新语言、LLM×强类型语言新 benchmark——下轮定向补查。**报告保鲜期 ~4-6 周，2026 年 7 月中复查**（TS7 stable 随时落地、MoonBit 1.0 定 Q3、Zero 周更 2-3 版）。

**行动衔接（2026-06-11 Discussion 已立项）**：B-111 eval harness = 叙事武器（Mojo 的 token 话术只有定性说法，Ring 实测「effect 签名省 X% token/轮数」可越级）；B-104/B-089 native 收口 = 入场券；公开发布时机 = native + benchmark 两证据齐后（Zero 案例证明窗口内发布有 25 天 5k stars 级红利）。

## 竞品全景（2026-05-22）

| 项目 | 启动 | 当前版本 | 团队 | Stars | 编译器语言 | 自举 | Effect 系统 | AI 集成 |
|------|------|---------|------|-------|-----------|------|-------------|---------|
| **Ring-lang** | 5/16（7天） | 自举完成 | 1人+AI | — | Ring（自举） | ✓ | 完整（io/fail/async/mut） | 编译器反馈+签名信息密度 |
| **MoonBit** | 2023（3年+） | v0.9.2 | 数十人 | ~4k | OCaml | ✗ | ✗（checked raise） | MoonBit Pilot agent |
| **Zero** | 5/15（8天） | v0.1.3 | Vercel小组 | ~1.5k | C（1.7MB） | N/A | ✗（World capability） | JSON诊断+修复计划 |
| **Rue** | 12/2025 | 早期 | 1人+AI | 1.1k | Rust | ✗ | ✗ | ✗ |
| **Mog** | 3/2026 | 发布后停滞 | Voltropy | — | Rust | ✗ | ✗ | 3200-token规范 |

### Ring-lang 开发速度

- 7 天、1 人 + AI、242 commit、15.5k 行 Ring 代码、348 E2E 测试
- 自举（31 个 .ring 文件翻译 + 验证）在 **~9 小时**内完成
- Phase 3 整合（语法修订 + 新特性 + 重构 + 多错误恢复）在 **1 天内**完成
- 新功能开发周期：agent 约 2 小时交付一个完整特性（含测试），基本零返工
- 预计 Phase B（mut\<S\> + 模块系统完善）在 **2 天内**完成

对比参考：Rue 用 ~2 周写了 100k 行 Rust，但无类型推断、无 effect 系统、无自举。Zero 用 ~1 周写了 1.7MB C，但功能仅覆盖基础编译 + 工具链 shell。

---

## MoonBit——最直接的竞品

MoonBit（ICSE 2024 论文，2023 启动）由张宏波创建（OCaml 核心贡献者、BuckleScript/ReScript 作者），深圳 IDEA 研究院。v0.9.2（2026-05-12），1.0 计划 H1 2026。编译器为 OCaml 实现（未自举）。

**重叠度高：**

| 特性 | MoonBit | Ring-lang |
|------|---------|-----------|
| 类型系统 | ML 系：ADT + 泛型 + trait + 推断 | ML 系：ADT + 泛型 + trait + 推断 |
| 不可变优先 | 是 | 是 |
| 编译目标 | WASM + JS + Native（Perceus RC） | JS 原型，计划 WASM + Native |
| AI 友好 | MoonBit Pilot + constrained decoding | 语言设计 + 编译器反馈 + 签名信息密度 |
| 编译速度 | 极快（号称 9x Rust） | 亚秒级（JS） |

**核心差异——Ring-lang 追踪的范围更广：**

| | MoonBit | Ring-lang |
|---|---------|-----------|
| 错误追踪 | `raise`/`suberror`，编译时追踪 | `fail<E>` effect，编译时追踪 |
| IO 追踪 | 不追踪——签名看不出是否有 IO | `io` effect 签名可见 |
| 可变性追踪 | 不在类型中追踪 | `mut` effect 签名可见 |
| 异步追踪 | 不追踪 | `async` effect 签名可见 |
| Effect handler | 无 | 完整：声明、推断、handler、重解释、测试 mock |
| Refinement types | 无（用 `proof_ensure` 走形式化验证路线） | 核心特性（类型层表达） |
| Row polymorphism | 无 | 核心特性 |

一句话：**MoonBit 追踪错误，Ring-lang 追踪一切副作用。** 对 LLM 而言，Ring-lang 的模块签名携带更多信息，LLM 需要更少上下文即可正确使用 API。

**MoonBit 2026 新动向（需关注）：**

1. **形式化验证**（v0.9+）：`proof_ensure` 语法 + `moon prove` 命令。走的是"外部验证工具"路线而非"类型层约束"路线。与 Ring-lang 的 refinement types 形成正面叙事竞争——MoonBit 已发货，Ring-lang 尚在规划。
2. **MoonBit Pilot**：AI code agent，号称 6 分钟生成完整 TOML parser（vs Cursor 16min / Codex CLI 35min）。自定义 Agent Server Protocol（ASP），支持 Sub-Agent 并发修改。
3. **Python 互操作**：`moon-agent` 框架批量生成 Python 库绑定。
4. **其他**：reverse pipeline `<|`、workspace 支持、async v0.17.0、`Debug` trait 替代 `Show`。

**诚实评估**：MoonBit 在工程成熟度上全面领先（3 年 + 数十人 + 完整工具链）。但：
- GitHub compiler 仅 689 stars，社区渗透率有限
- OCaml 实现未自举，Ring-lang 在"吃自己狗粮"上领先
- `proof_ensure` 是外挂工具，非类型系统内生——Ring-lang 的 refinement types 在理论整合度上更优
- MoonBit Pilot 的"更快"叙事基于自报数据，无独立基准验证

注：MoonBit Public License（魔改 SSPL）禁止商业 fork。

---

## Zero（Vercel Labs, 2026-05-15）——agent-first 系统语言

Zero（zerolang.ai）由 Vercel 工程师 Chris Tate 创建，**2026-05-15 发布**（与 Ring-lang 同周启动）。v0.1.3，Apache-2.0，~1,500 stars（首日 ~900）。

**编译器架构**：100% C 实现（12 个源文件，~1.7MB），直接手写 x86-64/ARM64 机器码 + ELF/Mach-O/COFF 构造。无 LLVM、无 QBE。Runtime 以 C 字符串数组嵌入二进制。

**Zero vs Ring-lang 对比：**

| 维度 | Zero | Ring-lang |
|------|------|-----------|
| 切入点 | **工具链** — JSON 诊断、修复计划、machine-readable 一切 | **语言** — effect 系统、严格编译器、最小语法面 |
| 类型系统 | 中等：泛型 + interface + choice | 激进：HM 推断 + effect + row poly |
| 副作用追踪 | `World` capability，仅区分有IO/无IO | 完整代数效果系统（4种 effect 独立追踪） |
| 所有权 | `owned<T>`/`ref<T>`/`mutref<T>` + borrow check | GC，零心智负担 |
| 编译目标 | 原生二进制（手写 emitter） | JS → WasmGC → LLVM |
| 错误处理 | `raises { ErrorName }` + `check`/`rescue` | `fail<E>` effect + catch + handler |

**Zero 的工具链亮点（Ring-lang 应借鉴）：**
- `zero check --json`：stable error code + typed repair object
- `zero fix --plan --json`：machine-readable 修复步骤
- `zero explain <code>`：版本匹配的错误解释
- `zero graph --json`：依赖拓扑
- `zero skills get zero --full`：agent 引导指南

**评估**：
- Zero 和 Ring-lang 同龄同阶段，但 Vercel 品牌带来 1,500 stars + 大量媒体曝光（TechTimes/HackerNoon/The Stack/MarkTechPost）
- Ring-lang 类型系统维度远超 Zero——Zero 无 HM 推断、无 effect 系统、无 row poly
- Borrow checker 不成熟，社区评价褒贬不一（"LLM 已经能处理 Rust/Go 的错误了"）
- 两者定位不直接冲突：Zero 是系统语言，Ring-lang 是应用语言
- **真正的竞争在叙事层面**：Zero 有 Vercel 品牌，Ring-lang 有技术深度

---

## Mog（Voltropy, 2026-03）——嵌入式 agent 语言

定位"静态类型的 Lua"。MIT 许可。2026-03-09 Show HN 发布后无更新。

**核心卖点：完整语言规范仅 3,200 tokens。** 用 Voltropy 自研"Volt" coding agent 构建。无泛型、无宏、无线程。编译到 native（via Rust）。Capability 沙箱安全模型。

| 维度 | Mog | Ring-lang |
|------|-----|-----------|
| 定位 | 嵌入式脚本 | 通用应用语言 |
| 规范大小 | ~3,200 tokens | 远大于此 |
| 安全模型 | Capability 沙箱 | Effect 系统编译时追踪 |
| 类型系统 | 基础静态类型 | HM + effect + row poly |

**启发**："规范塞进上下文窗口"是强力叙事角度。

---

## Rue（Steve Klabnik, 2025-12）——简化版 Rust

Steve Klabnik（Rust 核心团队）用 Claude 在 ~2 周内完成。~100k 行 Rust，700+ commit，1,100 stars，4 contributors。

编译到 native（自定义 backend，非 LLVM）。基础控制流、enum、pattern matching、borrow/inout 已工作。无 LSP、无包管理、无并发。Klabnik 明确表示是个人探索，不追求采用。

2026-03 后无显著更新。

---

## 其他 agent-first 项目

- **Pel**（2025, arXiv 2505.13453）：Lisp 风格 agent 编排语言，内置 NL 条件由 LLM 评估，Common Lisp 风格 restarts
- **Quasar**（2026, arXiv 2506.12202）：LLM 代码动作语言，自动并行化 + 不确定性量化
- **Dana**（Aitomatic / AI Alliance, 2025）：agent 编排语言，企业定位
- **Darklang-GPT**（Paul Biggar）：转向"AI 是唯一的代码编写者"
- **PACT**：概念级 LLM 友好语言，编译到 Rust

**Ring-lang 的独特组合（完整代数效果 + HM 推断 + 自举 + LLM 友好性）仍无直接竞品。**

---

## "够用就行"威胁——现有语言的 AI 适配

| 力量 | 做什么 | 威胁等级 | 最新状态 |
|------|--------|---------|---------|
| **TypeScript 7 / Project Corsa** | Go 重写 TS 编译器，10x 加速 | **极高** | Beta 2026-04-21，stable 预计 6-7月 |
| **Constrained decoding** | 限制 LLM token 采样，保证输出符合语法 | 高 | 持续进展 |
| **OpenAI 收购 Astral** | Ruff + uv + ty 集成 Codex，Python "够用"上限拉高 | 高 | 持续推进 |
| **LSP 桥接** | 任意语言的 LSP 包装为 MCP/agent 接口 | 中 | 生态成熟中 |
| **Spec-driven 开发** | 结构化意图层补偿语言弱点 | 中 | 行业趋势 |

**TypeScript 7 是最大的"够用就行"威胁**：10x 编译加速 + 更好的 AI 工具集成会大幅提升"为什么不用 TS"的论点。

**Ring-lang 的反论**：工具层补丁无法改变签名信息密度、副作用 bug 捕获、业务规则编码深度。TS 7 快 10x 仍然是"快速检查不完整的类型"。

---

## 学术验证

- **LMPL 2025**：代数效果分离 LLM 工作流副作用，验证 effect 系统赌注
- **TypePilot**（EPFL）：高级类型系统是 AI 代码正确性的乘数
- **SimPy**（ISSTA 2024）：为 AI 优化语法有实际收益
- **AlphaVerus**：LLM 生成形式化验证代码
- **Kleppmann "Vericoding"**：AI 将使形式化验证主流化

---

## Koka——最近的学术对标（2026-05-23 新增）

Koka（Daan Leijen，Microsoft Research）是 Ring effect system 的直接理论来源。编译器代码参考 Koka 的 Haskell 实现翻译。

**核心重叠**：代数 effect system、evidence passing、effect 推断、Perceus RC（Ring 计划中）、ML 风类型系统。

**Ring vs Koka 差异化**：

| 维度 | Koka | Ring | 差异强度 |
|------|------|------|---------|
| Effect 完整度 | Full AE（multi-shot continuation） | Tail-resumptive + abort | Ring 是子集 |
| Mutation 追踪 | state effect（有 handler，有运行时成本） | mut\<T\> marker effect（零成本编译期追踪） | **设计创新** |
| OOP 手感 | 纯函数式 | struct + impl + trait | 中 |
| Refinement types | 无 | 核心特性（计划） | **品类差异** |
| 编译优化 | C backend，无 JIT | LLVM AOT + JIT 愿景，语义驱动优化 | **架构差异** |
| LLM 友好 | 无此设计目标 | 核心设计目标 | 中 |
| 自举 | Haskell 实现 | Ring 自举 | 中 |

**诚实评估**：Ring 的 effect system 源于 Koka，但定位完全不同。Koka 是学术研究语言（纯函数式，无 OOP 手感），Ring 是面向工程的应用语言（Rust 语法 + ML 推断 + Koka effects）。核心差异化不在 effect 系统本身，而在三支柱的组合——推断一切（零标注）+ 追踪一切（签名即契约）+ 语义驱动性能（LLVM + 类型信息驱动优化）。Refinement types 是实验赌注（Z3 集成编译器路径未经充分验证），成了是品类创新，不成前三支柱自洽。

---

## 战略判断（2026-05-23 更新）

### Ring-lang 的核心定位（2026-05-24 更新）

**Rust 的安全性 + Python 的书写体验 + 效果系统让编译器知道一切，然后用这些信息优化性能。**

**三支柱**：

1. **推断一切**：类型 + effect + 可变性 + 所有权，全推断。写起来像 Python，安全性像 Rust。Rust 的标注负担（lifetime、turbofish、trait bound）由编译器承担，不由人承担
2. **追踪一切**：签名即完整行为契约（io/fail/mut/async）。LLM 和人都能从签名读出全部副作用。模块签名信息密度最大化，LLM 只需签名即可正确使用 API
3. **语义驱动性能**：LLVM 后端 + effect purity / linearity 信息直接转化为编译优化——bounds check 消除、RC 省略、纯函数重排/并行化。前两个支柱产生的类型信息是优化燃料

**实验赌注**：Refinement types（Z3 集成编译器，类型层值级谓词）。成了在第三支柱上再加一层（refinement proof → 消除运行时检查，消灭 `unsafe`），不成前三支柱自洽

**已领先的维度**：
- 类型系统理论深度（完整 effect + row poly，所有竞品都没有）
- 自举（MoonBit 用 OCaml，Zero 用 C，Rue 用 Rust——只有 Ring-lang 吃自己狗粮）
- 人效比（7 天 1 人 vs MoonBit 3 年数十人）

**落后但可追的维度**：
- LSP（等 Phase C 层 1+2 稳定后启动）
- 包管理（可延后）
- 公众可见度（Zero 同龄但 1.5k stars，需要公开发布）

**不应追的维度**：
- 包生态——需要用户基数
- MoonBit 的 3 年工程打磨——时间不可压缩

### 里程碑（2026-05-24 更新）

| 里程碑 | 状态 | 备注 |
|--------|------|------|
| Phase 3（语法修订 + 多错误恢复） | ✅ 完成 | 1 天 |
| 自举（TS → Ring） | ✅ 完成 | ~9 小时 |
| Phase B（mut\<S\> + 模块完善） | ✅ 完成 | 2 天 |
| Phase C 层 1（effect alias / supertrait / mut\<T\> / default handler / delegate） | ✅ 完成 | 1 天 |
| Phase C 层 2（关联类型 + Iterator） | 进行中 | — |
| B-044 语义规范 | 排队 | 阻塞 LLVM |
| LLVM 基础后端 | 确定交付 | 语义规范完成后启动 |
| Ownership + Perceus RC | 确定交付 | LLVM 后启动 |
| Refinement types | 实验赌注 | Z3 集成路径未验证 |

### "死亡螺旋"风险

新语言训练数据少 → LLM 写得差 → 没人用 → 训练数据更少。

Ring-lang 的独特缓解：**模块签名自描述**。Effect 系统让模块的完整行为契约压缩在签名中，LLM 只需签名即可正确使用 API——不依赖训练数据。
