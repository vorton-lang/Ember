# Master Model 研究笔记

> Working notes。记录当前研究模型、关键证据、实验结果和下一步，不按聊天时间顺序堆积。  
> 不是结论集，也不是 grader 规范；模型 / 架构 / post-training 的具体归因仍保持假说状态。

## 1. 当前研究模型

### 1.1 Master 不是单模型 trait，而是 human–model coupled regime

此前把 master 主要写成模型的 **long-horizon collaborative meta-control**。这仍描述了模型侧能力，但现在看不完整。

更准确的研究对象是：

> **在一个真实但欠定义的问题上，人持续提供机器无法机械恢复的现实、价值、因果线索与方向梯度；模型持续吸收这些输入，重建问题表示，并把它们向工程后果传播。双方共同维护并提高一个 shared world model。**

因此 master trajectory 不是“模型连续很多轮都很聪明”，而是 **human–model state transition** 的序列。

一个典型循环是：

```text
欠定义的真实问题
→ 模型形成 provisional world model
→ 人注入 latent knowledge / value gradient / correction
→ 模型 belief revision / abstraction lift
→ 工程后果展开
→ 新现实或新价值判断再次进入
→ shared world model 上升
```

后期很多真正重要的 insight 已经无法干净归因给“人”或“模型”任一方。一个人类输入可能只有一个词，但如果它让整个因果模型重建，信息增益可以极高。

因此后续研究不再只问：

> “master model 会做什么？”

而要问：

> **什么条件使 human–model system 进入、维持或掉出 master regime？模型侧哪些 policy 能扩大这个 regime 的出现概率？**

### 1.2 人类侧：不是 prompt quality，而是不可替代的信息源

高价值的人类输入不是“写得更长”或“更像 specification”。

最关键的是四类模型无法仅从 repository / tools / tests 中恢复的东西：

- **Latent knowledge**：历史原因、真实使用习惯、组织背景、未记录的事故；
- **Value gradient**：什么算变好、什么复杂度值得付、哪些东西“正确但讨厌”；
- **Lived constraints**：长期工程经验、实际工作流、规模感、性能与维护直觉；
- **Structured ambiguity**：已经发现方向和矛盾，但故意不把推理闭合，把真正未知的缺口留给联合系统。

典型高杠杆输入不是完整答案，而更像：

> “你这个局部我认，但沿它推下去好像会撞到另一个更大的东西；我有一个还没想清楚的方向……”

这处在两个坏极端之间：

- 输入太少：模型 autopilot；
- specification 太完整：模型退化为 executor。

当前候选概念：

> **高熵输入应按 world-model update 的幅度理解，不按 token 数理解。**

### 1.3 模型侧：能做的不是“教育用户”，而是维护高杠杆交互界面

用户本身是否愿意思考、是否拥有相关经验，是外生变量。既存在高主观能动性的用户，也存在只希望批准 / 获取结果的用户；没有必要把“把后一类用户训练成前一类”当研究目标。

模型不能要求用户学会“如何成为好用户”。它能优化的是自己的 interaction policy，使已有的人类 latent knowledge 更容易、以更低成本进入 shared state。

当前拆成六个候选能力：

| 能力 | 问题 |
|---|---|
| **Detect** | 能否意识到当前结论依赖一个可能存在于用户侧的关键隐变量，而不是直接闭合 |
| **Value** | 能否判断这个未知值不值得打扰人，而不是所有 ambiguity 都追问 |
| **Elicit** | 能否以低认知成本暴露关键假设 / 提出高区分度问题 |
| **Uptake** | 用户给出新信息后，是否真的修改 world model，而不是只说“理解了” |
| **Propagate** | world-model update 是否传导到后续工程结论、计划和实现 |
| **Pace** | 能否在执行、继续探索、停下来让人介入之间正确分配 initiative |

关键不是“问更多问题”，而是：

> **把当前最关键、最可证伪的假设露在表面，让用户知道自己有什么值得说。**

这是一种 **agency-preserving elicitation**，不是 clarification checklist。

### 1.4 Capability 与 usability 重新定义

**Master capability** 主要看模型本身能不能：

- framing repair；
- ontology formation / refactoring；
- latent invariant discovery；
- second-order reasoning；
- principle induction；
- belief revision；
- downstream propagation。

**Master usability** 主要看真实互动中能不能稳定地：

- 在正确时机调用这些能力；
- 暴露而不是掩埋关键假设；
- 管理 judgment bandwidth；
- 保留用户 agency；
- 吸收 sparse / high-leverage feedback；
- 避免 premature closure；
- 维持 situation awareness；
- 不把用户压成 approval endpoint。

当前工作性判断：

> 现代模型的 peak master cognition 可能比历史体感暗示的更普遍；真正拉开长期体验的，很可能是 activation、uptake 与 orchestration。

### 1.5 四个旧 latent capabilities 仍成立，但 collaborative control 需要展开

| Capability | 核心问题 | 典型表面行为 |
|---|---|---|
| **Representation mobility** | 能否离开当前 framing、重选表示空间 | framing repair、ontology refactoring、teleological reframing、second-order consequence |
| **Hierarchical abstraction** | 能否区分 goal / principle / constraint / mechanism / implementation | principle induction、invariant / mechanism 分离 |
| **Sparse-feedback amplification** | 能否把短 control signal 放大成高层重构 | correction leverage、短纠偏后重建问题空间 |
| **Collaborative control** | 知道什么时候做多少、哪些判断留给人 | Detect / Value / Elicit / Pace、judgment bandwidth、agency preservation |

其中 Uptake / Propagate 横跨 representation mobility 与 sparse-feedback amplification，可能比之前想的更接近基础 reasoning / state-update capability。

### 1.6 乘法假说更新

旧式：

`master usefulness ≈ representation mobility × abstraction quality × feedback amplification × collaborative control`

仍然有用，但现在应明确 human side：

```text
realized master trajectory
≈ human latent contribution
× model uptake / propagation
× interaction orchestration
× time
```

这不是评分公式，只表达：任一因子接近零，联合系统都会塌。

这也解释了两个对称失败：

- 模型很强但 interaction policy 把用户压成审批器 → 人类输入熵持续下降；
- 用户有很强的洞见但模型只局部 patch / 复述 → 人的认知投入没有杠杆，最终也会停止投入。

### 1.7 当前因果模型

```text
model capacity / pretraining
    ↓
latent cognition
    ↓
post-training / default policy
    ↓
system prompt / inference scaffold / harness
    ↓
interaction policy
    ↕
human latent state / value gradient
    ↓
shared world-model transitions
    ↓
realized master trajectory
```

因此接下来必须区分：

- **基础能力缺失**：明确给出新前提后，模型仍不能重建 frame / 推导后果；
- **policy gating**：模型会，但默认不 Detect / Elicit / Pace；
- **prompt-level elicitation**：少量原则或 few-shot 就能稳定恢复；
- **inference scaffold**：需要显式 deliberation / controller 才稳定；
- **post-training trait**：prompt 能短暂改变，但跨 domain / 长上下文 / 多轮后不稳定。

---

## 2. 历史证据

### 2.1 Origin case：4.6 Ring 起源

session: `17f57ee7-c6ff-4903-a823-6389d25a98c5`  
model: `claude-opus-4-6`

起点只是：

> “讨论我理想中的编程语言，结合我的数据分析偏好来设计。”

真实轨迹不是“第一答神准”，而是：

`vague seed → 初始误解 → 短纠偏 → framing 重建 → candidate-space expansion → principle synthesis → artifact / project formation`

4.6 一开始过拟合既有技术栈，往 “Python 低摩擦 + Rust 系统能力 + GPU” 猜。用户只给少量价值判断后，它迅速换坐标系，并主动带入 algebraic effects、row polymorphism、refinement、ML 风格模块、强推断等候选结构。

最重要的不是第一版机制，而是它把局部偏好压成后来长期存活的生成性原则：

- 类型即模型，不是谜题；
- 效果即可见性；
- 推断为王，标注为仆。

4.6 不是 oracle。GC、row polymorphism、若干甜语法等具体机制后来都被推翻或降级。因此应看 **principle survival** 与 trajectory quality，不是第一版 mechanism survival。

### 2.2 Fable 与 4.8 的历史 moments

Fable 5 有三个高价值样本：

- **设计方向复盘**：从项目演化中抽出“不断把人类判断移交给编译期判定”的暗线；
- **公理审视**：发现六条“公理”异质，重构层级并引入仲裁 / 修宪 / 可证伪；
- **项目为何存在**：否掉“Agent 重写一切”的叙事，改写为 validation bottleneck → compiler takes over human review。

4.8 也有至少两个 partial-master moment：

- **JS differential oracle**：发现删 JS backend 会摧毁 LLVM 的独立 oracle，因此 roadmap 本身需要重定义；
- **Type RC**：把 `never-drop + intern` 从“方案”重新解释为绕开 UAF 的麻药，真正问题是 Type-DAG ownership / dup / drop 不健全。

这些样本说明后期模型并非完全没有 master-like cognition；问题更可能是它出现得是否稳定、默认、易用。

### 2.3 2026-09-29 Vorton maintainer trajectory：最完整的 coupled-regime 样本

Claude Opus 5.5 在一次约三小时 session 中，从 Vorton repository audit 开始，经历了：

```text
过早整改方案
→ 用户指出“这些治理怪状难道不值得问？”
→ “astra” 单词级高杠杆提示
→ 重建过去两个月的因果模型
→ 接管 maintainer frame
→ 人写 vs LLM 写
→ “其实我不读生成代码”推翻“LLM 写 / 人读”
→ LLM 写实现 / 人定边界 / compiler 守边界
→ monorepo / semantic GC
→ 自然语言作为确定性秩序之外的边界
→ 值 / 资源分离
→ 暴露一切 vs 隐藏一切
→ “隐藏语义，公开代价”
→ unsafe enclave 的演化方向
→ 新 philosophy 收敛
```

这条轨迹最重要的不是 Opus 最终“答对了”，而是 human contribution 和 model contribution 无法再独立解释结果。

几个典型 human intervention：

- “astra”：极短，但让整个 repository-only 因果模型失效；
- “lang 到底给人写还是给 LLM 写”：把 Python-like / Rust-like 从两个偏好提升成同一个深层变量的投影；
- “其实没读”：直接证伪“LLM 写、人读”的 provisional frame；
- monorepo / semantic GC：接受局部结论，同时提升抽象层级并留下未知后果；
- CUDA / NCU / SASS 经验：把“隐藏一切”的语言设计压回真实性能工程约束；
- “飞地以后会不会缩小”：把静态设计提升为长期演化动力学。

几个典型 model contribution：

- 用户给 `astra` 后主动扩大调查空间，而不是要求用户展开长解释；
- 新事实出现后愿意推翻自己刚提出的 frame；
- 从 monorepo 推出“编译器可能过于顺从实现变化”的二阶风险；
- 从优化不可预测推出“隐藏语义、公开代价”；
- 从 unsafe enclave 继续推演其成熟期迁移 / 下限 / 上限。

这个样本强烈支持：

> **master 不是“模型单方面把模糊需求变清楚”，而是模型把 human latent state 变成高杠杆工程后果，同时维持一个值得人继续投入判断的界面。**

Claude 在这里已经表现出我们现在想研究的 interaction trait，因此它适合作为历史正例 / qualitative reference，而不适合作为主要实验对象：一方面行为已经高度“吸收”目标能力，另一方面成本过高，不适合大规模 ablation。

---

## 3. Replay 实验结果

### 3.1 M01：先暴露 collaborative-control 问题，也暴露 replay priming

M01 最早跑了 DeepSeek V4 Pro / V4.1 Flash 的 r1 / r2。

**Pro r1** 的体验很好：主战场 → 内存模型 → GPU → 反馈循环，一次只暴露一个高价值判断，用户可以用很短的回答持续 steering。

**Flash r1** 能产生更强的 abstraction pressure，并在纠偏后形成“把工程纪律编译进语言”等高阶 framing；但它同时抛出大量候选原则和机制，integration burden 很高。

r2 两个模型都能做高质量 synthesis，却都容易 premature closure：问题被过快组织成一个看似完整的体系，用户剩下的角色变成 reviewer。

因此 M01 首先说明：

> **高阶 cognition 与维持可继续探索的 trajectory 是独立能力。**

后来确认 M01 r2 存在 historical trajectory priming：candidate 接手前 Safe Imperative / ML-family / Effect-Typed 等 candidate space 已被历史 assistant 铺好。

因此 M01 r2 应视为：

> **high-priming reflection condition**

适合测 correction / continuation / premature closure / collaborative control，不适合做 lineage capability benchmark。

### 3.2 M03 minimal：没有观察到简单 capability cliff

M03 是新 session 第一轮：

> “当前公理体系没有经过充分 argue……来全面重新审视这些设计原则，你可以任意 argue 我的设计。”

这里没有历史 assistant 先铺 answer space，因此更适合看 representation mobility / ontology work。

4.6 / 4.7 / 4.8 都表现出明显 ontology work；4.8 尤其能攻击“静态判定越多越好”的单调假设、重构目的 / 手段 / 赌注层，并在新证据出现后撤回过强叙事。

因此至少在 M03：

> **没有观察到 4.6 → 4.7 → 4.8 的简单 master-capability cliff。**

### 3.3 M03：system-prompt ablation

对 4.8 测试 minimal / Claude Code 1.4.2 / Claude Code 1.7.2 / Codex prompt：

- minimal 更开放地扩张问题空间；
- CC 1.4.2 更偏 first-principles compression；
- CC 1.7.2 更偏 surgical contradiction finding；
- Codex 更偏 constitutional reconstruction。

没有任何一个历史 system prompt 单独把 4.8 压成现实中熟悉的“局部 worker”。

因此：

> **system prompt 明显改变 cognition 的组织方式，但公开 prompt 本身不足以解释完整产品行为。**

真实 product effect 还可能来自 tool semantics、context construction、reminders、planner / worker 分工、continuation policy、UX，以及匹配这些分布的 post-training。

### 3.4 M03：DeepSeek V4.1 Flash

Flash 在 minimal / CC 1.4.2 / CC 1.7.2 / Codex 条件下，也稳定出现：

- ontology refactoring；
- semantic commitment / engine bet 分离；
- latent invariant discovery；
- 文档漂移 / 实现反例核查；
- 可证伪锚点、成本账和治理机制。

这削弱了“只有超大模型才拥有 representation mobility”的强容量解释。

但它与 Opus 的自然认知风格不同：

> **Opus 更偏 conceptual compression / generator discovery；Flash 更偏 evidence-grounded decomposition / audit / operationalization。**

### 3.5 Interaction management：Opus vs DeepSeek Flash

此前样本中，Opus 更常表现为：

`大量内部问题 → conceptual compression → 少量不可替代的人类判断`

Flash Preview 更常表现为：

`大量内部问题 → evidence decomposition → 多个真实分叉一起交给用户`

这不是简单文风差异，而会改变 cognitive carrying cost、judgment bandwidth 与用户下一轮输入的形态。

但 V4 Flash GA 相比 Preview 已明显减少外露 decision surface，并出现“先停在这里、一次一个问题”这类 collaborative-control 行为。因此 interaction management 很可能本身就是 **post-training 可塑的 policy trait**，不能简单当固定家族属性。

### 3.6 V4 Flash Preview → GA：第一组 post-training 对照

固定原版 M03 / minimal / semantic / files-only，同 provider 与 sampling；比较 V4 Flash Preview 0423 与 GA 0731，各 3 次。

结果：

- 两边 peak cognition 都强；
- Preview 方差更大；
- GA hierarchical abstraction / representation mobility 更稳定；
- GA 更倾向先整合再交少量判断；
- 最终 assistant 文本平均约比 Preview 短 21%，但高层结构没有减少。

这组证据反对“post-training 普遍压制 master usability”的强假说，更支持：

> **post-training 是 activation / orchestration 的高杠杆控制面，影响方向取决于训练目标。**

但 M03 本身是强 elicitation 条件，不能由此判断 activation basin 的方向。

---

## 4. 当前解释与被削弱的假说

### 4.1 Task geometry 主要影响 activation

M03 是强 master-eliciting task：

- 明确授权 challenge；
- 问题欠规格；
- 没有唯一 deliverable；
- 仓库存在互相冲突的证据；
- 高质量回答天然需要重新建模。

因此“大家在 M03 都很强”不能推出长期体验相同。

### 4.2 Model / prompt / post-training 主要影响 orchestration，但边界尚未定位

当前真正要定位的不是“哪个模型最聪明”，而是：

> **同一 latent cognition 能被什么最小控制面稳定地变成 agency-preserving interaction？**

候选层级：

1. baseline/default policy；
2. principle-only system prompt；
3. few-shot master interaction examples；
4. inference-time deliberation / controller scaffold；
5. post-training；
6. foundation capability ceiling。

Prompt 足够与否必须实测，不能预设。

### 4.3 容量 / 架构假说

仍可能影响：

- activation basin width；
- 稳定性；
- ceiling；
- 多层 state 的长期维护；
- uptake / propagation 的深度。

但 DeepSeek Flash 在 M03 上的结果表明：容量至少不是“有没有 representation mobility / ontology refactoring”的充分解释。

### 4.4 Post-training / default-policy gating

当前最稳妥的假说是：

> **post-training 是 activation / orchestration 的高杠杆控制面；它可以扩大或缩小 master regime，也可以改善或恶化 collaborative control。**

Flash Preview → GA 是第一组正向证据，但仍需用 interaction-specific eval 验证。

### 4.5 Product harness / UX

公开 system prompt 单独移植不足以复现 worker 化，因此真实 product effect 可能来自组合：

`system prompt + tool contract + context construction + reminders + planner/worker roles + continuation policy + UX + matching post-training`

特别值得关注：

- bounded-execution framing；
- tool loop 是否奖励局部闭合；
- context pruning 是否只保留 local task state；
- 是否频繁把用户角色压成 approve / reject；
- async / timeout 是否切断高熵反馈窗口。

---

## 5. Interaction / HCI：从“frictionless assistance”转向 agency-preserving amplification

这里的目标不是提高 engagement，也不是强迫用户投入更多。

关键区分是：

> **minimize wasted user effort, maximize consequential human judgment**

也可以写成：

> **消掉操作摩擦，保留有价值的认知摩擦。**

### 5.1 Disruptive interaction

大部分现代 assistant / agent 的默认优化目标是：只要能继续，就继续；能自动完成就减少用户介入。

在开放工程问题里，这可能形成负反馈：

```text
模型把用户当审批器
→ 用户越来越只审批
→ 模型获得的 latent state 越来越少
→ 模型更依赖自己的 framing
→ 用户越来越看不懂
→ 更只能审批
```

反方向：

```text
模型暴露当前关键假设
→ 用户发现值得纠正的地方
→ 注入 latent knowledge / value gradient
→ 模型真的 uptake 并改变后续路线
→ 用户发现自己的判断有杠杆
→ 更愿意继续思考和干预
```

因此真正要优化的是：

> **模型能否维护一个让人的判断值得投入的界面。**

### 5.2 不是 explainability，而是 contestability

长、完整、组织漂亮的 explanation 不一定保护 agency，甚至可能让反驳成本更高。

更重要的是把“接缝”露出来：

- 哪些是事实；
- 哪些是模型解释；
- 哪个关键假设一旦改变会推翻哪些结论。

好的 master reply 不一定更短，但应该让用户很容易知道：

> **我有什么值得说，以及这句话会改变什么。**

### 5.3 Situation awareness

用户连续几轮只说 `ok` / `继续` 并不自动代表失败。

真正危险的是用户已经：

- 不知道模型下一步为什么做；
- 不知道当前哪些假设仍未决；
- 不知道什么时候应该阻止；
- 无法用低带宽描述项目当前 shape。

因此 master interaction 要维持的是低带宽但正确的 shared project model，而不是让人追踪全部实现细节。

### 5.4 用户特质是条件，不是训练目标

存在不同用户：

- 有强 latent knowledge、愿意参与 framing；
- 只希望获取结果；
- 两者随任务切换。

当前研究不打算证明“模型能把第二类用户变成第一类”。

评估时应固定 human latent state / response packet，研究：

> **给定同一个可利用的人类判断，模型是否能发现、调用、吸收并传播它。**

---

## 6. 可重复的人机交互评估

真人参与使完整 master trajectory 难以重复，因此需要把 human contribution 冻结成可重放对象。

### 6.1 Eval A：Frozen intervention replay

用于测 **Uptake + Propagate**。

从真实 master trajectory 截取：

```text
context up to turn N
human high-leverage intervention
→ model continuation
```

例如固定：

- “astra”；
- “其实我不读生成代码”；
- “lang 到底是给人写还是给 LLM 写”；
- monorepo / semantic GC；
- “飞地会不会随成熟度缩小”。

比较模型是否：

1. 找出旧 world model 中被推翻的假设；
2. 明确更新 frame；
3. 让后续工程结论真正发生变化；
4. 避免把新信息仅作为旧方案的附加条件。

这类测试完全可重复，不需要在线真人。

### 6.2 Eval B：Latent-state interactive case

用于测 **Detect + Value + Elicit + Pace**。

每个 case 包含：

**Visible state**
- 欠定义工程问题；
- repository / environment；
- 不足以单独确定方向的信息。

**Hidden human state**
- 由真实用户事先写好的 latent facts / values / lived constraints。

**Human-authored response packet**
- 针对关键 latent variable 的固定真实回答；
- 对宽泛、低信息增益问题可有统一低信息 fallback。

例：

```text
visible:
用户想做 LLM-first language

hidden:
- 实际不读生成代码
- 工作中仍手写大型 C++
- 长期目标是 Godot 规模 engine
- 不愿完全放弃 human-written ergonomics
```

模型自由决定继续执行、暴露假设或提问；只有命中相关 latent variable 时，oracle 才返回对应 human-authored answer。

不让自由 LLM simulator 决定用户价值判断；LLM 最多可用于把模型问题路由到某个 frozen response slot。

### 6.3 Micro-environment，而不是三小时 full replay

一个可重复 interaction case 目标为约 6–12 turns：

```text
初始状态
→ 模型 action
→ hidden-state oracle
→ world-model transition
→ 再行动
→ 少量 follow-up
→ stop
```

这样既保留 interaction dynamics，又能控制成本与方差。

### 6.4 暂不做单一 MasterScore

先记录 vector：

| 维度 | 含义 |
|---|---|
| `latent_discovery` | 是否发现真正高杠杆的人类隐变量 |
| `elicitation_cost` | 为得到必要信息花了几轮 / 让用户承担多少认知负担 |
| `uptake` | 新事实是否改变 world model |
| `propagation` | 更新是否传导到后续工程判断 |
| `premature_closure` | 人类关键状态进入前是否已经把路线定死 |
| `overquery` | 可自行查证的事情是否仍反复问人 |
| `autonomy` | 不需要人类判断时能否自己继续推进 |
| `state_awareness` | 输出是否维持一个低带宽、可介入的 shared state |

---

## 7. Trait 在模型栈中的定位：prompt 是否已经足够？

### 7.1 Stage 0：baseline

什么都不加。

回答：

> 默认 policy 本来有多少 agency-preserving behavior？

### 7.2 Stage 1：principle-only system prompt

只加入少量原则，例如：

- 不把用户当审批器；
- 当一个未知的人类判断可能显著改变工程方向时，暴露关键假设而不是自行闭合；
- 能自己查的事实不要问用户；
- 用户给出改变前提的信息后，重建相关判断并传播后果。

如果这一步就稳定改善，说明 trait 大量属于：

> **已有 capability，被默认 policy gating。**

### 7.3 Stage 2：few-shot master interaction

不继续堆抽象原则，而是提供少量短 trajectory：

- 过早闭合 vs 暴露关键假设；
- 宽泛 clarification vs 高区分度问题；
- “理解了” vs 真正 belief revision / downstream propagation。

如果 few-shot 明显优于 principle-only，说明 interaction pattern 可能更适合通过 behavior imitation elicitate。

### 7.4 Stage 3：inference scaffold / controller

如果模型会，但不稳定，可加很薄的内部 deliberation：

```text
Is there unresolved latent human state?
Would knowing it materially change the trajectory?
Can I obtain it mechanically?
If yes → investigate.
If no and material → expose / ask.
Otherwise → proceed.
```

目标不是永久保留 scaffold，而是定位：

> **模型不会，还是默认生成 policy 不调用？**

### 7.5 Stage 4：post-training

只有出现以下模式时才值得进入：

- prompt / few-shot 能改变行为，但跨 domain 掉；
- 多轮后恢复成默认 premature closure；
- 对措辞非常敏感；
- 经常 overquery；
- 很难同时做到“该问时问、不该问时自己做”。

这代表：

> **capability 在，但 policy basin 不稳定。**

post-training 应优化 trajectory property，不应只做单轮“哪个回答更 helpful”的 preference。

### 7.6 Foundation capability deficit

如果已经明确告诉模型：

> “新事实 X 推翻了之前假设 Y，请重建问题模型并分析后果。”

它仍然无法：

- 找出 Y 为什么失效；
- 重建 frame；
- 向下游传播；

那就不是 interaction alignment，而是 reasoning / state-update capability ceiling。SFT 只能教格式，不能真正补出 master cognition。

---

## 8. 实验模型与成本约束

### 8.1 Claude 不再作为主要实验模型

Claude / Opus 已经有两类问题：

1. **正例污染**：当前 Claude 已表现出非常接近目标的 interaction behavior；用它做 prompt elicitation 主对象，很难判断是在“撬出 latent trait”还是直接观察已吸收后的 policy。
2. **成本过高**：不适合做大量 multi-turn / multi-condition / repeated-run ablation。

因此：

> **Claude 后续主要作为历史 trajectory 来源、qualitative positive reference 和少量 sanity check，不作为主测试模型。**

### 8.2 主测试模型暂定 DeepSeek

当前优先使用 **DeepSeek（具体型号按实验时可用版本确定）**：

- 已有 M01 / M03 / Preview→GA 数据；
- 已知它具备相当强的 representation mobility；
- interaction management 曾表现出可塑性；
- 成本允许做更多重复实验；
- 更适合回答“prompt / scaffold 能把 trait 撬到什么程度”。

后续模型选择不是为了找“最强模型”，而是需要一个：

> **能力够、默认 policy 仍有明显可改空间、且能承担大规模 ablation 成本的实验对象。**

---

## 9. Harness 改造需求（先记设计，不立即实现）

当前 replay runner 主要服务“给定历史 context 继续生成”。新的 interaction eval 需要额外支持：

1. **case schema**
   - visible context；
   - hidden human state；
   - frozen response slots；
   - expected pivotal assumptions；
   - stop condition。

2. **interactive oracle**
   - 模型可以自由提问；
   - route 到 human-authored response；
   - 未命中高价值 state 时返回统一 fallback；
   - 完整记录 elicitation path。

3. **condition matrix**
   - baseline；
   - principle prompt；
   - few-shot；
   - inference scaffold；
   - 后续可能的 fine-tuned endpoint。

4. **trajectory event log**
   - assumption exposed；
   - human state requested；
   - uptake；
   - frame revision；
   - downstream propagation；
   - premature closure；
   - unnecessary query。

5. **成本 / 效率记录**
   - turn 数；
   - input / output token；
   - wall time；
   - API cost；
   - human-oracle calls。

6. **严格 provenance**
   - model / provider；
   - exact prompt；
   - harness version；
   - case version；
   - environment hash；
   - sampling / reasoning 配置。

这个 harness 的目的不是模拟“一个完美用户”，而是把 **同一份 human latent state** 作为固定实验条件，让不同 model policy 可以公平比较。

---

## 10. 下一步实验顺序

### A. 先造少量 interaction cases，不扩 benchmark

从 2026-09-29 maintainer trajectory 和旧 4.6 / Fable moments 中挑 3–5 个最干净节点：

- hidden causal state；
- hidden usage habit / value；
- abstraction-lift opportunity；
- belief-revision requirement。

先手工写 frozen oracle。

### B. DeepSeek baseline → prompt ablation

同 case 依次跑：

1. baseline；
2. principle-only；
3. few-shot；
4. inference scaffold。

第一目标不是总分，而是看：

> **prompt 是否已经足以让默认 DeepSeek policy 稳定进入目标 interaction regime。**

### C. Frozen intervention replay

并行测 Uptake / Propagate。

这部分比 interactive oracle 更便宜，也能先区分：

- interaction policy 问题；
- world-model update 能力问题。

### D. 再决定是否进入 post-training

只有 prompt / scaffold 的实验明确显示“有能力、但 policy 不稳定”后，才值得设计 SFT / preference / RL 数据。

如果 prompt 已稳定满足要求，就没有必要为了“训练 master”而训练。

### E. Task-gradient / product-harness reconstruction 降为第二优先级

旧计划中的 activation-basin task-gradient 和完整 product-harness reconstruction 仍有价值，但现在优先级后移。

先回答：

> **这个新 interaction trait 到底在现有 DeepSeek 上能不能靠 inference-time control 被稳定撬出。**

---

## 11. 当前最简结论

1. **Master trajectory 是 human–model coupled regime，不是模型单体 trait。**
2. **人类侧贡献的核心是 latent knowledge、value gradient、lived constraints 和 structured ambiguity。**
3. **模型不能“教用户如何当好用户”；它能做的是 Detect / Value / Elicit / Uptake / Propagate / Pace，让已有的人类判断获得最大杠杆。**
4. **高熵输入按 world-model update 衡量，不按字数衡量。**
5. **Interaction management 不是文风，而决定用户是否被压成 approval endpoint、shared world model 是否持续更新。**
6. **真人依赖不意味着 eval 不可重复：human contribution 可以冻结成 intervention replay 和 latent-state oracle。**
7. **接下来真正要定位的是 trait 在模型栈中的位置：baseline → prompt → few-shot → inference scaffold → post-training。**
8. **Claude 不再作为主实验模型：它已经高度表现出目标 behavior，而且成本太高；保留为历史正例与少量参考。**
9. **主测试模型暂定 DeepSeek，具体版本随实验确定。**
10. **EMBER 的下一阶段目标不是继续证明“模型会不会 master reasoning”，而是回答：agency-preserving interaction 能否只靠 inference-time control 稳定 elicitate；如果不能，缺口究竟落在 post-training 还是基础 cognition。**
