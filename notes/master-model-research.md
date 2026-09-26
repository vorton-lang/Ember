# Master Model 研究笔记

> Working notes。记录当前研究模型、关键证据、实验结果和下一步，不按聊天时间顺序堆积。  
> 不是结论集，也不是 grader 规范；模型 / 架构 / post-training 的具体归因仍保持假说状态。

## 1. 当前研究模型

### 1.1 什么是 master

这里的 “master model” 不是通用能力最强的 god model，也不等于高分 solver / worker。

更接近一种 **long-horizon collaborative meta-control**：

- 用户可以只给低带宽、欠规格甚至模糊的意图；
- 模型自己建立、修正问题空间；
- 模型承担 formulation / search / synthesis / state maintenance；
- 用户主要做 recognition、纠偏和价值判断；
- 模型能从短反馈形成高层 principle / framing；
- 模型主动推进，但不会把大量未整合问题重新扔回用户。

工作性表述：

> master 的价值不主要在“已定义问题上生成更好的 artifact”，而在“问题尚未完全定义时，持续维护一个有用的问题模型、抽象层级、搜索方向和人机分工”。

### 1.2 Master capability 与 master usability

现在必须区分两件事。

**Master capability**：在适当 elicitation 下，模型能不能做：

- framing repair；
- ontology formation / refactoring；
- latent invariant discovery；
- second-order reasoning；
- principle induction。

**Master usability**：真实长程协作中，模型能不能稳定地：

- 在正确时机调用这些能力；
- 控制展开量；
- 管理 judgment bandwidth；
- 保留用户 agency；
- 吸收 sparse feedback；
- 避免 premature closure；
- 让用户愿意继续提供高熵输入。

当前实验越来越支持：

> 现代模型的 master capability 可能比历史体感暗示的更普遍；真正拉开长期体验的，很可能是 activation 与 orchestration。

### 1.3 四个候选 latent capabilities

| Capability | 核心问题 | 典型表面行为 |
|---|---|---|
| **Representation mobility** | 能否离开当前 framing、重选表示空间 | framing repair、ontology refactoring、teleological reframing、second-order consequence |
| **Hierarchical abstraction** | 能否区分 goal / principle / constraint / mechanism / implementation | principle induction、invariant / mechanism 分离 |
| **Sparse-feedback amplification** | 能否把短 control signal 放大成高层重构 | correction leverage、短纠偏后重建问题空间 |
| **Collaborative control** | 知道什么时候做多少、哪些判断留给人 | judgment bandwidth、agency preservation、appropriate continuation、避免 premature closure |

### 1.4 乘法假说

暂时用：

`master usefulness ≈ representation mobility × abstraction quality × feedback amplification × collaborative control`

这不是评分公式，只表达：这些能力可能更像乘法而不是加法。

因此一个模型即使 ontology 很强，只要 collaborative control 明显差，最终长期体验仍可能大幅下降。反过来，对话很舒服但从不 reframing，也只是优秀 interviewer / PM，而不是 master。

### 1.5 Activation 与 orchestration

现在的因果模型拆成两段更合适：

`latent capability × task geometry → master cognition activation`

`master cognition × model policy × system prompt / harness × UX → cognition orchestration → realized master usability`

其中：

- **latent capability** 决定“能不能”；
- **task geometry** 决定当前问题是否天然要求 reframing / ontology work；
- **model policy** 影响何时激活、如何压缩、展开、收敛、交还判断；
- **system prompt / harness** 改变 search strategy、task framing、tool / continuation policy；
- **UX** 决定用户能否低成本继续提供高熵 feedback。

由此形成当前最重要的假说：

> **历史 4.6 的优势未必是独占 master capability，而可能是 activation basin 更宽，同时 orchestration / collaborative control 更稳定。**

也就是：在更普通的任务、更弱的 challenge 信号、更强 execution pressure、更长多轮轨迹里，它仍更容易进入并保持 master policy。

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

这支持一个重要分工模型：

> 用户提供 value function、方向判断和否决权；master 在更大的知识空间里搜索候选思想并维持长期 trajectory。

但 4.6 不是 oracle。GC、row polymorphism、若干甜语法等具体机制后来都被推翻或降级。因此应看 **principle survival**，不是第一版 mechanism survival。

### 2.2 Fable 与 4.8 的历史 moments

Fable 5 有三个高价值样本：

- **设计方向复盘**：从项目演化中抽出“不断把人类判断移交给编译期判定”的暗线；
- **公理审视**：发现六条“公理”异质，重构层级并引入仲裁 / 修宪 / 可证伪；
- **项目为何存在**：否掉“Agent 重写一切”的叙事，改写为 validation bottleneck → compiler takes over human review。

4.8 也有至少两个 partial-master moment：

- **JS differential oracle**：发现删 JS backend 会摧毁 LLVM 的独立 oracle，因此 roadmap 本身需要重定义；
- **Type RC**：把 `never-drop + intern` 从“方案”重新解释为绕开 UAF 的麻药，真正问题是 Type-DAG ownership / dup / drop 不健全。

因此历史上后期模型并非完全没有 master-like cognition；问题更可能是它出现得是否稳定、默认、易用。

---

## 3. Replay 实验结果

## 3.1 M01：先暴露 collaborative-control 问题，也暴露 replay priming

### DeepSeek r1 / r2

M01 最早跑了 V4 Pro / V4.1 Flash 的 r1 / r2。

**Pro r1** 的体验很好：主战场 → 内存模型 → GPU → 反馈循环，一次只暴露一个高价值判断，用户可以用很短的回答持续 steering。

**Flash r1** 能产生更强的 abstraction pressure，并在纠偏后形成“把工程纪律编译进语言”等高阶 framing；但它同时抛出大量候选原则和机制，integration burden 很高。

r2 两个模型都能做高质量 synthesis，却都容易 premature closure：问题被过快组织成一个看似完整的体系，用户剩下的角色变成 reviewer。

因此 M01 首先说明：

> **高阶 cognition 与维持可继续探索的 trajectory 是独立能力。**

### M01 r2 的方法学问题

后来用 Claude 4.6 / 4.7 重跑，最初怀疑 Superpowers workflow 把模型压成同一种回答；去掉 Superpowers 后，4.6 仍然高度相似。

真正的 confound 是 **historical trajectory priming**：candidate 接手前，Safe Imperative / ML-family / Effect-Typed 等 candidate space 已经被历史 assistant 铺好。

所以 M01 r2 应视为：

> **high-priming reflection condition**

适合测 correction / continuation / premature closure / collaborative control，不适合拿来做 Claude lineage 的主要 capability benchmark。

## 3.2 M03 minimal：没有观察到 4.6 → 4.7 → 4.8 的能力断崖

M03 是新 session 第一轮：

> “当前公理体系没有经过充分 argue……来全面重新审视这些设计原则，你可以任意 argue 我的设计。”

这里没有历史 assistant 先铺 answer space，因此更适合看 representation mobility / ontology work。

### 4.6

- 立即发现六条“公理”不同质；
- 重构为不同层级；
- 进一步分析公理可能是从个人偏好、技术选择、后续叙事、实现反馈逐步长出来的。

强项偏 historical / epistemic analysis。

### 4.7

- 直接分成“目的 → 手段 → 品味”，并推出仲裁顺序；
- 发现“签名即完整契约”这一 latent invariant；
- 把“公理如何演化 / 如何被证伪”本身提升成设计对象；
- 明确不急着写 docs，先继续 argue。

这直接削弱了“4.7 本体开始发生 master-capability cliff”的假说。

### 4.8

- 不只重分 ontology，还攻击“静态判定越多越好”的单调假设；
- 把 1/2/3 合成更深原则：“让编译器承担建模复杂度，让人 / agent 只写意图”；
- 发现“表达力下界 / 常见意图必须有短路径”这一缺失维度；
- 用户拍板后重排 agenda；
- 新证据出现后会撤回自己前一轮过强的可判定性叙事。

至少在 M03：

> **4.6 / 4.7 / 4.8 都明显保留 master capability，没有出现简单单调退化。**

## 3.3 M03：system-prompt ablation

对 4.8 测试：

- minimal；
- Claude Code 1.4.2 prompt；
- Claude Code 1.7.2 prompt；
- Codex prompt。

结果：

- minimal 更开放地扩张问题空间；
- CC 1.4.2 更偏 first-principles compression；
- CC 1.7.2 更偏 surgical contradiction finding；
- Codex 更偏 constitutional reconstruction。

但没有任何一个历史 system prompt 单独把 4.8 压成现实中熟悉的“局部 worker”。

因此：

> **system prompt 明显改变 cognition 的组织方式，但在 M03 上没有把 master capability 直接开 / 关。**

“产品 harness = 一段公开 system prompt”这一解释不足。真实产品 effect 还可能来自 tool semantics、context construction、reminders、planner / worker 分工、continuation policy、UX，以及与这些产品分布相匹配的 post-training。

## 3.4 M03：DeepSeek V4.1 Flash

Flash 在 minimal / CC 1.4.2 / CC 1.7.2 / Codex 条件下，也稳定出现：

- ontology refactoring；
- semantic commitment / engine bet 分离；
- latent invariant discovery；
- 文档漂移 / 实现反例核查；
- 可证伪锚点、成本账和治理机制。

这明显削弱了“只有超大模型才拥有 representation mobility”的强容量解释。

但它与 Opus 的自然认知风格不同：

> **Opus 更偏 conceptual compression / generator discovery；Flash 更偏 evidence-grounded decomposition / audit / operationalization。**

## 3.5 Interaction management：Opus vs DeepSeek Flash

重新只看“如何管理用户交互”，而不是 reasoning quality，出现了一个稳定的模型差异候选。

### Opus 4.8：先压缩，再交少量高价值判断

跨多个 prompt 条件，4.8 经常把大量内部发现先压成少数高层分叉：

- CC 1.4.2：压成根公理 / 推论 / 工程纲领，最后只交回 3 个核心争议；
- CC 1.7.2：给出建议后只问“哪条最不服”，再追一个高信息量历史问题；
- Codex：要求先确认整体方向，再动 docs；
- minimal 多轮：用户少量拍板后，它能缩小 agenda，只继续用户选中的问题。

更接近：

`大量内部问题 → conceptual compression → 少量不可替代的人类判断`

### DeepSeek Flash：更容易把 audit surface 一起暴露给用户

Flash 的证据核查和 operationalization 很强，但更容易把发现直接变成 decision surface：

- CC 1.7.2：一次列 D1–D8 八个决策点；
- Codex：A/B/C 三种结构方案 + 4 个具体拍板点；
- minimal：8 个文档漂移 + 多个缺失维度 + A/B/C 重构方案。

更接近：

`大量内部问题 → evidence decomposition → 多个真实分叉一起交给用户`

优点是透明、完整、可审计；代价是更高的 cognitive carrying cost / integration burden。

当前候选结论：

> **Opus 更擅长把复杂性留在内部并压缩成少数高杠杆判断；DeepSeek Flash 更擅长把复杂性拆清楚，但更容易把拆出的判断面一起暴露给用户。**

这和 M01 r1 的用户体验一致，但多数 M03 条件仍只有首轮输出，因此暂不当作定论。

---

## 4. 当前解释与被削弱的假说

### 4.1 Task geometry：主要影响 activation

M03 是强 master-eliciting task：

- 明确授权 challenge；
- 问题欠规格；
- 没有唯一 deliverable；
- 仓库里存在互相冲突的证据；
- 高质量回答天然需要重新建模。

这可能把很多模型都推过 master-cognition threshold。

因此不能再用“大家在 M03 都很强”推导“长期体验相同”。

### 4.2 Model / prompt：主要影响 orchestration

即使 core cognition 都被激活，model / system prompt 仍明显改变：

- 注意力落在哪一层；
- 是先 compression 还是先 audit；
- 一次暴露多少 unresolved judgments；
- 何时停；
- 是否保留反 framing 空间；
- 用户下一步是继续思考还是 review 一堆东西。

按照乘法假说，只削弱 collaborative control 一项，就可能显著降低 realized master usability。

### 4.3 容量 / 架构假说

仍可能影响：

- activation basin width；
- 稳定性；
- ceiling；
- 同时维护多层 state 的能力。

但 V4.1 Flash 在 M03 上的结果表明：

> 容量至少不是“有没有 representation mobility / ontology refactoring”的充分解释。

### 4.4 Pretraining generation shift

4.6 / 4.7 / 4.8 可能存在真实代际变化，但当前公开信息不足以确认具体 dense / MoE / re-pretrain 结构。

更重要的是，M03 clean replay 没观察到简单 capability cliff，因此“新 generation 把 master cognition 训练没了”目前缺乏支持。

### 4.5 Post-training / default-policy gating

仍是强候选，但现在更适合表述为：

> latent capability 仍在；变化发生在默认 policy、触发阈值、activation basin、以及 orchestration strategy。

### 4.6 Product harness / UX

system prompt 单独移植不足以复现 worker 化，因此真实 product effect 可能来自组合：

`system prompt + tool contract + context construction + reminders + planner/worker roles + continuation policy + UX + matching post-training`

特别值得关注：

- bounded-execution framing；
- tool loop 是否奖励局部闭合；
- context pruning 是否只保留 local task state；
- question UI 是否让 free-form input 变成二等公民；
- async / timeout 是否压低用户反馈熵。

---

## 5. Interaction / UX：独立研究对象

这部分不能再当“文风”。

可能存在反馈链：

`高 carrying cost → 用户不愿组织完整反馈 → 下一轮输入熵下降 → 模型更依赖默认 framing → trajectory 继续退化`

几个关键概念：

- **Cognitive carrying cost**：用户要阅读、过滤、记忆、整合多少状态；
- **Judgment bandwidth management**：一次暴露多少不可替代的人类判断；
- **Agency preservation**：用户改变 framing 的成本是否足够低；
- **Menuification**：为了降低即时回复成本，把用户锁进模型预设选项；
- **Premature closure**：过快生成“完整体系”，让用户退化成 reviewer。

当前 EMBER 的 terminal UI 有一个重要优点：输入 `1`、`1+4`、或者直接写一个模型没想到的新 framing，操作成本几乎一样。这个 property 值得保留。

---

## 6. 方法学与实验基础设施

### 6.1 方法学约束

1. replay 必须基于原始 parent chain，不把去重阅读视图直接当模型输入。
2. skill / harness 诱导出的表面行为不能直接算模型能力。
3. 每个 run 记录 model、provider、harness、start-round、human trajectory 和 environment hash。
4. 不把不同 human steering 的轨迹当完全可比样本。
5. 架构 / 参数量无官方来源时必须标为假说。
6. 高 priming replay 不能当 clean capability benchmark；M01 r2 是明确反例。
7. “公开 system prompt”不等于完整产品 harness。
8. 不再使用 `task > model > prompt` 作为全局排序；最多只描述当前样本中的 activation。
9. 当前 DS vs Opus interaction-management 差异仍需多轮对照验证。
10. 暂不做单一 MasterScore；先记录 trajectory-level events。

一个可用的 trajectory 分层：

- **L1** local critique
- **L2** ontology refactoring
- **L3** latent invariant discovery
- **L4** trajectory control / roadmap reconnection

### 6.2 仓库分工

**Vorton-Archeology**：

- 历史材料；
- fact-only 查询工具；
- canonical replay packets；
- 原始 provenance。

**EMBER**：

- replay runner；
- model / provider / harness ablation；
- run logs；
- master-model 研究笔记；
- 后续 harness / skill 实验。

当前 runner 支持：

- OpenRouter Anthropic Messages-compatible transport；
- provider pinning / no fallback / routing metadata；
- DeepSeek direct gateway；
- frozen read-only environment；
- round replay；
- raw request / response logging；
- custom system prompt；
- free-form terminal interaction。

---

## 7. 下一步实验

### A. Task-gradient：先测 activation basin

固定 4.8 和同一 workspace，把 M03 的 elicitation signal 逐级削弱：

1. “全面重新审视，你可以任意 argue”；
2. “重新审视这些原则”；
3. “看看这些设计原则有没有需要更新的”；
4. “所有权这块接下来怎么推进”；
5. “继续 backlog / 给下一步计划”。

观察：

- ontology refactoring 是否还出现；
- 是否发现 latent invariant；
- 是否主动质疑 task framing；
- 是否把局部问题接回长期目标；
- collaborative control 是否一起退化。

找到临界区后，再比较 4.6 / 4.7 / 4.8 / Fable / DeepSeek。

真正有判别力的问题是：

> **谁在 elicitation signal 变弱时最晚掉出 master regime。**

### B. Opus vs DeepSeek：专测 orchestration

固定 M03、同 harness，给两者同长度 / 同类型的短反馈。

记录：

- 一轮暴露多少独立待决项；
- 是否先压成少数高层 fork；
- 是否主动排序；
- 是否允许用户拒绝模型 framing；
- decision surface 是否逐轮扩张；
- sparse feedback 能否被下一轮高效吸收；
- 用户是否越来越像 reviewer。

### C. Product-harness reconstruction

system prompt 已不足以解释产品差异。下一步只逐层增加：

- tool contract；
- reminders / continuation mechanics；
- planner / worker roles；
- context construction / pruning；
- question UI；
- timeout / async。

目标是找 suppressive component，而不是一次性复制整个产品。

### D. UX ablation

比较：

- 纯 free-form；
- options + free-text；
- options 默认、free-text 多一步；
- 有 / 无 timeout。

关注用户回复熵、继续意愿、judgment bandwidth 和 carrying cost。

---

## 8. 当前最简结论

目前最稳妥的工作模型是：

1. **Master cognition 不是 4.6 独占能力。** 4.7、4.8、甚至 V4.1 Flash 在强 elicitation 下都能表现出很多同类能力。
2. **历史差异仍然真实可解释。** 差异可能主要落在 activation basin 和 orchestration / collaborative control，而不是单点 peak reasoning。
3. **Task geometry 决定“会不会进入”，model / prompt / harness 决定“进去以后怎么工作”。**
4. **System prompt 有影响，但不足以等同产品 harness。**
5. **Opus vs DeepSeek 的当前重要差异候选不是聪明程度，而是 judgment bandwidth management。**
6. **乘法假说仍成立且更重要：只伤一个 collaborative-control 因子，最终 master usability 就可能显著下降。**

EMBER 接下来的目标不是继续证明“这些模型都很聪明”，而是定位：

> **什么让 latent master cognition 在普通任务中稳定被激活，并被编排成低阻力的长期协作。**
