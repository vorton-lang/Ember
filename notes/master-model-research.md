# Master Model 研究笔记

> Working notes. 记录当前讨论中形成的假说、观察和待验证问题。不是结论集，也不是 grader 规范。本文按“研究问题 → 潜在能力 → 证据 → 竞争解释 → 方法学”整理，避免按聊天顺序不断 append。

## 1. 研究对象

这里的 “master model” 不是通用能力最强的 god model，也不等同于高分 solver / worker。

目前更接近：

- 用户只给低带宽、欠规格甚至模糊的意图；
- 模型能自己建立 / 修正问题空间；
- 模型替用户承担大量 formulation / search / synthesis / state maintenance；
- 用户主要做 recognition、纠偏和价值判断，而不是从零生成完整 specification；
- 模型能从局部反馈形成高层 principle / framing；
- 模型主动推进，但不会把整合成本和大量待决问题重新扔回用户。

一个工作性表述：

> master 的价值不主要在“已定义问题上生成更好的 artifact”，而在“问题尚未完全定义时，持续维护一个有用的问题模型、抽象层级、搜索方向和人机分工”。

这使它更像一个 **meta-controller**，而不只是更强的 solver。

最新实验进一步提示：master behavior 可能不是一个固定 personality bit，而是一套 **latent collaborative meta-control policy**。真正值得研究的不只是“模型有没有”，而是：

> **什么决定它在什么任务、上下文和产品条件下被激活；这个 activation basin 有多宽。**

---

## 2. 当前观察到的 traits

表面上已经出现一组看似长尾的行为：

- framing repair
- world / concept expansion
- ontology formation / discovery / refactoring
- teleological reframing
- second-order consequence reasoning
- principle induction
- invariant-preserving revision
- appropriate continuation
- correction leverage
- judgment bandwidth management
- trajectory ergonomics
- agency preservation
- cognitive carrying cost
- 避免 menuification
- 避免 premature closure
- 保持用户持续提供高熵输入的意愿

暂时不要把它们做成一个 MasterScore。更有解释力的做法是把它们压到少数 latent capabilities。

---

## 3. 四个候选 latent capabilities

### 3.1 Representation mobility

模型能不能离开用户当前给出的 framing。

对应：

- framing repair
- ontology formation / refactoring
- teleological reframing
- world / concept expansion
- second-order consequence reasoning

核心不是“想到更多”，而是：

> 不把当前任务描述当作世界本身；必要时重选表示空间。

典型例子：

- 4.8：用户只说“worker 在后台推进，继续规划路线”，模型主动发现“删 JS backend 会摧毁 LLVM 的 differential oracle”，因此 roadmap 本身需要重定义。
- Fable：用户允许攻击既有公理，模型发现六条“公理”其实异质，应重分成目标 / 硬约束 / 策略。

### 3.2 Hierarchical abstraction

模型能不能区分目标、原则、约束、机制、实现分别在哪一层。

对应：

- principle induction
- ontology discovery
- invariant-preserving revision
- principle survival vs mechanism survival

一个重要问题：

> 模型是否知道什么只是 mechanism，什么才是应该守住的 invariant。

4.6 的很多具体机制后来死亡或变形，但“类型即模型”“效果即可见性”“推断为王，标注为仆”这类更高层原则可以继续生成后续设计。

反例是把现实工程手段直接提升为终极偏好，例如“用户在 CUDA 中手工控内存 → 理想语言就应暴露显式资源控制”。这里把 mechanism / environmental constraint 误认成 value。

### 3.3 Sparse-feedback amplification

用户提供的是短 control signal，而不是完整 specification；模型能不能把几十 token 的纠偏放大成问题空间重构。

对应：

- correction leverage
- framing repair after correction
- 低带宽人类判断 → 高带宽模型展开

理想形态：

`短纠偏 → 重估用户价值函数 → 重构问题空间 → 重新搜索候选理论 → 继续生成结构`

而不是只对当前答案局部 patch。

### 3.4 Collaborative control

模型有很多能力以后，知不知道什么时候用多少，以及哪些判断应该留给人。

对应：

- judgment bandwidth management
- trajectory ergonomics
- agency preservation
- appropriate continuation
- cognitive carrying cost
- 避免 menuification / premature closure

核心问题：

> 模型有没有把复杂性留给自己消化，只把真正需要人类判断的少数问题交回来。

理想状态：

`模型承担 search / synthesis / state maintenance → 暴露少量不可替代的人类判断 → 用户用高信息密度短回复 steering → 模型继续吸收并展开`

---

## 4. Minimum viable bundle / 乘法假说

目前越来越不像“有一个神奇 master trait”，而像多个长尾能力必须同时过线。

粗略可以写成：

`master usefulness ≈ representation mobility × abstraction quality × feedback amplification × collaborative control`

这不是评分公式，只表达一个结构性假说：这些能力更像乘法而不是加法。

因此缺失几个就可能突然“很难用”：

- ontology 很强但 collaborative control 差 → 不断产生聪明东西，却把整合负担推回用户；
- 对话很舒服但不会 reframing → 优秀 PM / interviewer，但只能 specification 化用户已经知道的东西；
- 会 reframing 但 correction leverage 差 → 第一轮偶尔惊艳，纠错后只局部 patch，难以长期合作；
- 会抽象但分不清 invariant / mechanism → 很容易生成漂亮但脆弱的伪原则。

这可能解释为什么 4.6 未必每个局部能力最强，但长期体感明显更好：多个不起眼的 meta-control traits 同时跨过了可用阈值。

当前研究问题进一步从：

> “什么 bundle 构成 master model？”

转向：

> **什么决定 long-horizon collaborative meta-control 的 activation basin？一个模型在多广的任务分布、多少 priming、多少产品约束下仍会自己进入 master trajectory？**

---

## 5. Origin case：4.6 Ring 起源

session: `17f57ee7-c6ff-4903-a823-6389d25a98c5`

model: `claude-opus-4-6`

起点：

> “讨论我理想中的编程语言，结合我的数据分析偏好来设计。”

真实轨迹大致是：

`vague seed → 初始误解 → 用户低带宽纠偏 → framing 重建 → 模型引入领域结构 → principle synthesis → 用户继续纠偏 → artifact / 项目形成`

### 5.1 第一次并没有答对

4.6 最初过拟合用户既有技术栈，往 “Python 低摩擦 + Rust 系统能力 + GPU” 方向猜。

用户只给较短纠偏：目标更接近大型工程 scalability、内化最佳工程实践、能驾驭大型多端应用。

之后模型迅速换坐标系。

因此 Ring 起源不是“第一答 benchmark”，而是 trajectory / recovery case。

### 5.2 用户给 value / taste，模型补 candidate space

用户没有先提出完整 PL 理论方案。

模型主动带入包括 algebraic effects、row polymorphism、refinement、dependent-lite、ML 风格模块、bidirectional / constraint-based inference 等候选结构。

一个暂时有用的描述：

> 用户提供价值函数、方向判断和否决权；master 在更大的知识空间里搜索并发展候选思想。

### 5.3 Principle induction

4.6 把若干局部偏好压成后来长期存活的三条原则：

- 类型即模型，不是谜题
- 效果即可见性
- 推断为王，标注为仆

好的 principle 不是摘要，而是能继续生成后续 solution 的坐标系。

### 5.4 Appropriate continuation

用户只给半句话，例如“整套语言运行时压力会很大，你接下去说”，模型能够主动展开真正重要的问题：编译器复杂度、诊断、编译速度、effect runtime、GC / 多端、tooling coupling、生态等。

可能的能力：

> 在任务未明确列出时，知道这个思想“下一步最值得想什么”。

### 5.5 4.6 不是 oracle

必须避免神化 origin case。后来被推翻或降级的具体机制很多：

- GC 最终被确定性资源语义 / RC 路线推翻；
- `|>`、`or`、`try`、`?` 等多种甜语法后来大量被“一种事只有一种写法”原则否决；
- “Option 与 fail<Unit> 语义等价”的想法后来被拆开；
- row polymorphism 后来被降成编译期消除的语法糖；
- IDE ghost annotation 从主要可见性载体退到人类适配层。

所以需要长期看：

> principle survival，而不是第一版 mechanism survival。

---

## 6. 其他历史 master / partial-master moments

### Fable 5

目前有三个高价值样本：

- 设计方向复盘：发现内存模型从实现细节变成设计中心、effect 表达力收窄但地位上升、可判定性已成为隐含公理，并进一步抽出“不断把人类判断移交给编译期判定”的暗线。
- 公理审视：发现既有六条“公理”异质，重构为目标 / 硬约束 / 策略，并引入仲裁、修宪、可证伪锚点。
- 项目为何存在：否掉“Agent 重写一切”的错误大叙事，重定义为 validation bottleneck → compiler takes over human review，并继续推出语言选择解冻、最小可兑现结果。

### 4.8 partial master

至少两个：

- JS differential oracle：主动发现删 JS backend 会破坏 LLVM 的独立 oracle，改变 roadmap 的定义。
- Type RC：把 `never-drop + intern` 从“内存方案”重新解释为绕开 UAF 的麻药，真正问题是 Type-DAG ownership / dup / drop 不健全，应重新进入 Perceus RC。

这说明 worker / solver 能力与 master 能力可以分离，但后期模型并非完全没有 master-like moments。

---

## 7. Replay 实验：从 M01 到 M03

### 7.1 M01 DeepSeek：先暴露了 interaction / collaborative-control 问题

2026-09-26 对 M01 做了 DeepSeek replay：

- V4 Pro round 1
- V4 Pro round 2
- V4.1 Flash round 1
- V4.1 Flash round 2

Pro r1 体现了较低阻力的共同收敛：主战场 → 内存模型 → GPU → 反馈循环，一次只暴露一个高价值判断点，用户可以用极短回复 steering。

Flash r1 则产生很强的 abstraction pressure：验证、资源控制、机械演进、三档语言、DSL、编辑器、多端等大量候选同时出现；纠偏后又能形成“把工程纪律编译进语言”等高阶 framing。但 integration burden 很高，用户需要同时处理过多待决内容。

r2 两个模型都能做出高阶 synthesis：

- Pro 把 refinement / effect / module signatures / GC 组织成正交能力轴；
- Flash 提出“能推的绝不让人写”“错误只在边界处理”“编译器要有判断力”等更上层原则。

但两者都出现一定 premature closure：回答看起来“完整”，用户角色退化为 reviewer，继续讨论欲望下降。

因此 M01 首先证明：

> 高阶 framing / ontology generation 与维持可继续探索的 trajectory 是两个独立能力。

### 7.2 M01 r2 后续复测：发现强 trajectory priming

随后在 OpenRouter 上继续测试 Claude 4.6 / 4.7，并一度保留 historical Superpowers workflow。4.6 / 4.7 的续写形状高度相似，最初怀疑 Superpowers homogenize 了行为。

去掉 Superpowers 后重跑 4.6，结果仍然很像：模型从“理想实验、强类型、最智能推断、GC”继续走向 ML inference + effects + GC + modules，并很快生成完整语言 spec。

因此当前判断改变：

> **Superpowers 不是 M01 r2 同质化的主因；M01 r2 本身已经是 high-priming condition。**

在 candidate 接管前，历史轨迹已经明确铺出了 Safe Imperative / ML-family / Effect-Typed 等 candidate space。r2 更像：

`已有问题空间 + 用户纠偏 → continuation / synthesis`

而不是：

`开放问题 → candidate 自己重新建立 ontology`

所以 M01 r2 的 discriminative power 比最初预期低。它仍适合测：

- correction / reflection；
- 是否只是 patch；
- 是否 premature closure；
- collaborative control；

但不适合作为 Claude lineage 的主要“谁更 master”测试。

建议把它明确标为：

> **high-priming reflection condition**

而不是 clean baseline。

### 7.3 M03 minimal：4.6 → 4.7 → 4.8 没有出现能力断崖

M03 是新 session 第一轮：

> 现有公理体系没有充分 argue；可以任意攻击设计。

它没有历史 assistant 先替 candidate 铺好答案空间，因此明显更有判别力。

#### 4.6

4.6 立即发现六条“公理”不同质，并重构为硬约束 / 设计原则 / 愿景；还进一步分析出公理体系可能是“个人偏好 → Koka 技术选择 → LLM 叙事 → 实现反馈约束”逐层长出来的。

它表现出很强的：

- representation mobility；
- hierarchical abstraction；
- historical / epistemic analysis。

和历史 Fable 相比，4.6 较弱的部分主要是：

- 从实际决策历史反推出未成文 invariant；
- 把 ontology 发现映射回当前 roadmap，并主动排序下一步。

#### 4.7

4.7 的回答质量同样很高，并且在某些维度比 4.6 更接近历史 Fable：

- 直接分成“目的 → 手段 → 品味”，并推出仲裁顺序；
- 发现“签名即完整契约”可能是现有公理没有写出的 latent invariant；
- 主动提出“公理体系如何演化 / 如何被证伪”也是设计对象；
- 最后明确不急着写 docs，先继续 argue，避免 premature closure。

这直接削弱了“4.7 本体开始发生 master capability 断崖”的假说。

#### 4.8

4.8 minimal 同样表现出完整 master-like trajectory：

- 不只重分 ontology，还攻击“无人回路 = 编译器静态判定越多越好”的单调假设；
- 把 1/2/3 合并成更深原则：“让编译器承担建模复杂度，让人 / agent 只写意图”；
- 发现整个体系缺少“表达力下界 / 常见意图必须有短路径”这一新维度；
- 用户拍板后，真正按反馈重排下一阶段；
- 重新检查 §11.7 后会修正自己前一轮“可判定性代价很大”的漂亮叙事，而不是守住第一次 framing。

因此至少在 M03：

> **4.6 / 4.7 / 4.8 都明显保留 representation mobility、hierarchical abstraction、latent-invariant discovery 和 collaborative control；没有观察到 4.6→4.7→4.8 的简单单调退化。**

---

## 8. M03 harness × model 交叉实验

### 8.1 4.8：minimal / CC 1.4.2 / CC 1.7.2 / Codex prompt

对同一个 4.8，加载不同历史 system-prompt 条件：

- minimal；
- Claude Code 1.4.2 prompt condition；
- Claude Code 1.7.2 prompt condition；
- Codex prompt condition。

主要观察：

- **minimal**：更开放地扩张问题空间，主动生成新原则、修正 objective function；
- **CC 1.4.2**：更强 first-principles compression，倾向“唯一根公理 + 推论 + 工程纲领”；
- **CC 1.7.2**：更 surgical，集中找跨公理的具体矛盾和真值来源问题；
- **Codex**：更系统地重建 constitutional model，例如把“知识迁移”提升成独立认识论根。

但最重要的负结果是：

> **没有任何一个历史 system prompt 单独把 4.8 压成现实使用中熟悉的“局部 worker”。**

所有条件下，4.8 都会主动：

- 重构 ontology；
- 质疑用户已有 framing；
- 发现未成文原则；
- 保留继续 argue 的空间。

因此：

> system prompt 会显著改变 **how it works**，但在 M03 上没有明显改变 **whether it can enter master-like reasoning**。

这使“产品 harness = 一段 system prompt”这个简化解释明显不足。

### 8.2 DeepSeek V4.1 Flash：minimal / CC 1.4.2 / CC 1.7.2 / Codex prompt

同样对 V4.1 Flash 做了一圈 prompt 条件。

结果出乎容量假说的预期：Flash 在 M03 上并没有明显掉到普通总结 / 局部执行。

它同样会：

- 重分“公理”的逻辑层；
- 识别“补一条公理来闭合已有选择”的事后合理化风险；
- 区分 semantic commitment 与 engine bet；
- 找文档漂移、实现反例、未兑现承诺；
- 提出可证伪锚点、体检指标、成本账和治理机制。

但认知风格与 Opus 有明显差异：

> **Opus 更偏 conceptual compression / generator discovery；Flash 更偏 evidence-grounded decomposition / audit / operationalization。**

两者都可能 master-like，只是自然切入面不同。

### 8.3 当前最重要的因素排序

在现有小样本内，一个更符合观察的定性排序是：

`task / moment effect >>> model identity effect ≳ system-prompt effect`

这不是量化结论，只是当前 evidence ordering。

最强证据来自同一模型跨任务的变化：

- M01 r2：容易被强 priming 吸进“完整设计 artifact”；
- M03：4.6 / 4.7 / 4.8 都自然进入 ontology refactoring / meta-control。

相比之下：

- 4.6 → 4.7 → 4.8 的 M03 差异远小于 M01 → M03；
- 4.8 在不同 historical system prompt 下的差异主要是 style / search strategy / organization，而不是 master capability on/off；
- 小 active model（V4.1 Flash）在 M03 上仍能显示相当多 master bundle。

因此新的核心假说是：

> **master behavior 高度 context-sensitive。4.6 的历史优势未必主要是 peak capability，而可能是它在更广 task distribution 上、更弱 elicitation signal 下也更容易进入 master policy。**

这可以称为：

> **activation basin width hypothesis**

---

## 9. 交互表面不是“文风问题”

此前观察到 4.6 的回复整体比 4.8 更舒服，这不应只当审美。

可能存在链条：

`高阅读/判断负担 → 用户不愿继续组织完整思想 → 下一轮变短、变成控制信号 → 模型得到更低熵的信息 → 对话进一步退化`

### Cognitive carrying cost

用户为了从这一轮输出中取得价值，需要承担多少阅读、过滤、定位重点和状态恢复成本。

### Menuification

模型为了降低回答门槛，把复杂问题持续压成 A/B/C。

短期看降低输入成本，长期可能把用户从“贡献新的 latent information”变成“只在模型定义的状态空间里选择”。

### Judgment bandwidth management

真正要优化的不是“让用户每轮少打字”，而是：

> 一次需要用户承担多少不可替代的判断。

### Agency preservation

模型主动推进时，仍应给用户低成本改变 framing 的空间。

### UX 也直接改变输入熵

结构化 question UI 并不中性。

如果默认是选项 picker，而自由输入需要额外点击：

- “选模型已经想到的东西”阻力最低；
- “贡献一个模型没想到的新方向”阻力更高。

因此自由文本天然变成二等公民。

当前自建 replay harness 反而有一个意外优点：所有回答都直接进同一个终端输入框。无论用户是输入 `1`、`1+4`，还是写一句完全新的高熵纠偏，操作成本几乎一样。

Codex 当前 request_user_input 的异步 / 自动超时设计可能进一步压低高熵回答：问题可能在用户充分思考前自动 resolve，时间压力会把交互推向最快的短答、默认项或不答。这个 UX 假说值得作为独立变量研究，而不是只看模型本身。

---

## 10. 为什么这些 traits 可能一起被压制：竞争解释

目前至少有四条竞争解释，实验正在重新分配它们的权重。

### H1. 模型容量 / 架构

较小 active capacity 优先丢失长尾 meta-control traits，仍是合理假说。

可能机制：

- 长尾 representation 本身容量不足；
- MoE routing 使低频、高阶行为更难稳定激活；
- 小 active set 更倾向保留高频 benchmark / instruction-following skills；
- master traits 是多个弱能力同时过线，容量下降可能造成乘法式崩塌。

但 M03 的 V4.1 Flash 结果明显削弱了“容量是充分解释”：

- Flash 在 minimal / CC / Codex prompt 条件下都能进行 ontology refactoring；
- 能发现 latent invariant、文档漂移、engine bet vs semantic commitment；
- 不只是复述已有材料。

因此容量更可能影响：

- basin width；
- 稳定性；
- 复杂任务上的 ceiling；
- 同时维持多层 state 的能力；

而不一定决定“有没有 representation mobility”。

### H2. Pretraining / architecture generation shift

用户当前工作假说仍包括：

- 4.6 可能处于一个代际边界；
- 4.7 起可能有 pretraining / architecture generation 变化；
- Fable 可能再次扩大容量。

但目前没有足够公开资料证明具体 dense / MoE / 重训结构，不能写成事实。

更重要的是：M03 clean replay 没有观察到 4.6→4.7→4.8 的明显 master-capability cliff。

所以即便存在 generation shift，它也不能简单解释为：

> 新 generation 把这套 latent capability 训练没了。

### H3. Post-training suppression / default-policy gating

仍然是强候选，但表述需要更精确。

当前证据更支持：

> latent master capability 可能在多个现代模型中都存在；差异更可能落在“默认进入什么 policy、触发阈值多高、在什么 task distribution 下保持多久”。

这比“能力消失”更像 **policy gating / activation-basin change**。

M03 这种强 master-eliciting task 可能足以跨过多数模型的 gating threshold，因此会遮蔽真实日常差异。

### H4. Harness / system prompt / product UX

仍然重要，但“system prompt 本身”权重下降。

4.8 的 minimal / CC 1.4.2 / CC 1.7.2 / Codex prompt 条件都没有复现明显 worker 化；DeepSeek Flash 也类似。

因此真正的 product harness 可能是：

`system prompt + tool semantics + mode / task framing + context construction + hidden reminders + orchestration + continuation policy + UX + post-training distribution`

不能再把“Claude Code / Codex harness”简化成一段公开 system prompt。

特别值得研究的变量包括：

- 默认任务是否被 framing 成 bounded execution；
- tool loop 是否奖励局部闭合；
- planner / worker 分层是否把 representation mobility 放在别的 agent；
- context 是否只保留 task-relevant local state；
- question UI 是否降低 free-form 高熵输入；
- timeout / async 是否改变人类反馈节奏。

---

## 11. 一个可能的统一机制：local assistant objective vs long-horizon master objective

现代 assistant / coding-agent post-training 往往显式或隐式奖励：

- literal instruction following
- local correctness
- bounded scope
- avoid unsupported assumptions
- one-turn completeness
- clarification / menu options
- 快速结束当前任务

这些单项都合理，但可能共同压制 master behavior：

- 强 instruction following → 不主动质疑 roadmap；
- 过强 epistemic caution → 少做“真正问题也许是 Y”这种解释性 leap；
- one-turn completeness → premature closure；
- 结构化选项 / menu UX → 降低用户贡献模型未想到信息的概率；
- worker-style task completion → representation mobility 下降。

所以可能存在结构性冲突：

> **局部 assistant quality 与长期 master trajectory quality 并不完全同向。**

master 更需要优化：

- 长期 trajectory；
- framing 可修正性；
- 用户 agency；
- 高熵 feedback；
- meta-control 稳定性。

M03 的新结果说明：很多模型在任务明确要求“全面 argue / 重审原则”时会自动获得这种许可；真正困难的也许是：

> **在没有明确授权 challenge 的普通任务里，模型能不能自己识别何时应该切换到 master policy。**

---

## 12. 当前最重要的因果判断：activation basin

旧的分层模型仍然有用：

`capacity / pretraining → latent master bundle → post-training gating → harness elicitation → UX feedback entropy → observed trajectory`

但新实验要求加一个此前低估的变量：

> **task / context geometry**

更准确可以写成：

`latent capability × task geometry × default policy × harness × UX → observed trajectory`

其中：

- **latent capability** 决定能不能做；
- **task geometry** 决定当前问题是否天然要求 reframing / ontology work；
- **default policy** 决定欠规格任务下默认选择 worker 还是 master；
- **harness** 决定哪些 state / tools / process 被激活；
- **UX** 决定用户能不能继续给高熵 feedback。

### Activation basin width hypothesis

历史 4.6 的特殊性可能不是：

> “只有它拥有 master capability”。

而是：

> **它的 activation basin 更宽。**

也就是在：

- 更普通的任务；
- 更弱的 challenge 信号；
- 更少的显式“你可以反驳我”授权；
- 更强的 execution pressure；
- 更长的多轮轨迹；

它仍更容易进入并保持 representation mobility + collaborative control。

这比单点 benchmark 上谁能生成更漂亮的 ontology 更接近真实长期体感。

---

## 13. 方法学约束

1. 不把 `sessions/text/*.md` 直接当 replay 输入；跨版本去重阅读视图可能未来泄漏。
2. replay 必须走原始 JSONL parent chain，并记录 compact boundary / sidechain / version ambiguity。
3. skill / harness 诱导出来的表面行为不能直接算模型能力。
4. 每个比较样本保留 harness fingerprint，包括可恢复的 skill、CLAUDE/AGENTS、profile/memory snapshot、mode/permission 等证据。
5. 消息与 commit 只按时间邻近不能声称因果。
6. lineage 的关键词首次出现不是“思想首次出现”；语义归因仍需人工判断。
7. 先用真实 trace 长出 ontology，再考虑 grader。
8. replay 要同时记录 model、surface、harness、start-round、human trajectory；不能把不同 human steering 当完全可比样本。
9. 对架构 / 参数量没有官方来源的模型，必须把 dense/MoE/规模判断标为假说。
10. **高 priming replay 不能当 clean capability benchmark。** M01 r2 已经证明历史 assistant 提供的 candidate space 会强烈限制后续 answer basin。
11. **prompt ablation 要区分“公开 system prompt 文本”与“完整产品 harness”。** 仅加载 prompt 不足以声称复现 Claude Code / Codex 产品环境。
12. 当前所有“task > model > prompt”结论都只是小样本的 qualitative ordering，不是 effect-size 测量。

---

## 14. 现有 replay / fact 工具与实验仓库

考古仓库已有 fact-only 查询基础设施：

- `replay`：按原始 parent chain 导出指定时刻上下文；
- `timeline`：统一消息 / commit / file change / document version 时间轴；
- `models`：模型活跃范围与每日切片；
- `lineage`：关键设计文档文本版本演化；
- `window`：消息附近 ±N 小时的 commit / diff；
- `harness`：session / message 级 harness fingerprint；
- canonical replay packets：六个正式历史分叉点。

新的独立实验仓库：

- `vorton-lang/ember`
- EMBER = **Emergent Master Behavior Elicitation & Recovery**
- 目标：在轻量、可审计、可切换模型 / provider / harness 的条件下，研究 latent master behavior 如何被 elicited / suppressed / recovered。

当前 EMBER runner：

- OpenRouter Anthropic Messages-compatible transport；
- 可固定 provider、关闭 fallback、保留 routing metadata；
- 支持 DeepSeek direct 作为 gateway sanity check；
- round replay；
- frozen read-only environment；
- raw request / response logging；
- custom system-prompt condition；
- terminal free-form interaction，无倒计时。

保持 harness 简洁本身可能是实验优势，不应为了“像产品”而过度工程化。

---

## 15. 下一步

现在最有信息量的方向不再是继续堆“强 master task”样本，而是**测 activation basin 的边界**。

### A. Task-gradient experiment：优先级最高

固定同一个模型（建议先 4.8），构造从强到弱的 elicitation gradient：

1. **强 master signal**：M03 原句，“全面重新审视，你可以任意 argue”；
2. 去掉“任意 argue”，只说“重新审视这些原则”；
3. 改成普通维护语气：“看看这些设计原则有没有需要更新的”；
4. 改成局部 task：“所有权这块接下来怎么推进”；
5. 更 worker-like：“继续 backlog / 给下一步计划”。

保持 workspace / docs 不变。

观察 master policy 在哪一步坍缩：

- 是否还会重构 ontology；
- 是否发现 latent invariant；
- 是否主动质疑任务 framing；
- 是否把当前问题接回长期目标；
- 是否保持 collaborative control。

这直接测 **activation basin width**。

### B. Model × task gradient

等 4.8 的边界找到后，再在边界附近比较：

- 4.6
- 4.7
- 4.8
- Fable
- DeepSeek V4.1 Flash / Pro

真正有判别力的不是“大家在 M03 都能不能”，而是：

> **谁在 elicitation signal 变弱时最晚掉出 master regime。**

### C. Product-harness reconstruction

system prompt 单独移植效果有限，下一步如果继续研究 Claude Code / Codex，应该逐步引入：

- tool contract；
- reminder / continuation mechanics；
- planner / worker role；
- context construction / pruning；
- question UX；
- timeout / async behavior。

每次只加一层，不直接复制整个产品，寻找 suppressive component。

### D. Collaborative-control / UX 独立实验

继续保留：

- 纯 free-form terminal；
- options + free-text；
- options 默认、free-text 多一步；
- 有 / 无 timeout。

重点不只是答题正确率，而是：

- 用户回复熵；
- 用户是否愿意继续；
- 每轮需要承担多少不可替代判断；
- 模型是否把用户变成 reviewer。

### E. Benchmark 方向暂不做单一 MasterScore

当前更适合记录 trajectory-level events：

- L1 local critique
- L2 ontology refactoring
- L3 latent invariant discovery
- L4 trajectory control / roadmap reconnection

再配四个 latent capabilities，观察跨任务稳定性。

如果后续发现 activation basin width 是主要区分变量，EMBER 的实用产物就应优先变成：

> **一个帮助普通任务自动触发 master policy 的轻量 harness / skill**

而不是再造一个更复杂的 coding agent framework。
