# case-18：Angela 的会话轮换：先看同类产品怎么做，还是直接拍数字

## 来源
73b61e3d-66d1-4d47-8c4a-feb2f69d9e12.jsonl，约 2026-10-16 17:33 UTC（JST 10-17 02:33）；类别 5（项目经理的功课没做）；分析中的 id：73b61e3d#38

## 历史
背景：Lobotomy 正按 #86 的新方向重新设计：Angela 是唯一长期存在的 personal agent，只有一个对话入口，长期记忆放在 Lobotomy 自己的图里。她的原生会话要轮换，这是技术方案里剩下的开放问题之一。现状是她的原生会话只在用户点“新会话”或换 harness 时更换，新会话的第一轮输入里放账本。10-16 16:36 用户执行了一次 /compact，之前的对话以压缩摘要的形式留在助手的上下文里。

（以下时间为 UTC；用户本地时间为 JST，即 UTC+9。）

用户：[2026-10-15 15:06 UTC]
总体上先做调研准备拿出技术方案，改动可以往后放，（……省略……）先把大致的设计思路缕清。

（……中间省略：技术方案、第 0 步实验、worker 接口设计；10-16 16:36 /compact……）

用户：[2026-10-16 16:39 UTC]
issue里白天随手记了一点想法，继续讨论

助手：[2026-10-16 16:44 UTC]
（……省略……）

**二、Angela 是否特殊**

我的回答：**位置特殊，机制不特殊。**

特殊在三处：
1. （……省略……）
2. （……省略……）
3. **唯一长期存在的 agent**：她的原生会话要轮换，记忆靠图。这块要单独设计两件事：
   - 什么时候轮换，例如按上下文大小或空闲时长；
   - 新会话开头放什么，例如活跃事情的 `thread_brief`、对话尾部、本地时间。现在 `recall()` 在新会话开头放账本，以后换成 brief。

（……省略……）

用户：[2026-10-16 17:02 UTC]
发送上下文是个open question，因为强制手选上下文是不可接受的，实际使用下来agent大多数时候可以自己猜个上下文，用户高兴的时候可以指定回复某条消息，上下文管理仍然不应该手动做。因为自然语言是流变的，而且我们有audio input计划。angela使用通用agent驱动是可以的，特殊主要说的就是权限职责这些。节奏等重构，我的想法是不需要wake after，因为如果误判了用户简单的一句补充就能叫醒。wake after有死循环风险，还容易被hack。等重构。

助手：[2026-10-16 17:03 UTC]
我把这三条都写进了本地的技术方案草稿。（……省略……）

**发送上下文**：已记为开放问题，约束照你说的写。我收回输入框 chip 的提案，它和"上下文不手动管"冲突。

（……省略……）

用户：[2026-10-16 17:08 UTC]
三个都同意

助手：[2026-10-16 17:09 UTC]
这三条都定了。（……省略……）

草稿 §8 里，设计层面还剩三个开放问题：

1. **消息的上下文**：约束已经写下，方案还没定。
2. **Angela 的会话轮换**：什么时候轮换她的原生会话，新会话开头放什么。
3. **UI/UX 的具体设计**：布局和交互的细节还没过。

（……省略……）

用户：[2026-10-16 17:11 UTC]
22还剩什么没吸收

（……省略：助手逐条对照 #22“可纠正的长期记忆”，给出 8 条提案……）

用户：[2026-10-16 17:14 UTC]
直接把这些过了，1任务依据的claim能机械算出吗

（……省略……）

用户：[2026-10-16 17:23 UTC]
只有两个问题，claude关掉auto memory会不会影响性能，以及现在的数据库支不支持界面上“回到记忆库”，也就是回溯历史版本的图

（……省略……）

用户：[2026-10-16 17:29 UTC]
ok

助手：[2026-10-16 17:31 UTC]
#22 的第 1 到 8 条，加上"历史版本"，都已写进技术方案，gist 已更新，#22 已关闭。（……省略……）

现在开着的 issue 只剩 #86、#85、#60 和 #50。设计层面还有三个开放问题：
1. 消息的上下文；
2. Angela 的会话轮换：什么时候轮换，新会话开头放什么；
3. UI/UX 的具体设计。

想先过哪个？

### 当时可读到的记录（节选）

MEMORY.md 的两条索引行（memory 索引常驻助手上下文）：

> - [Lobotomy product constraints](lobotomy-product-constraints.md) — design truth is notes/ + open issues; user stances: GUI, official CLIs, platform-neutral, accepted-only publish, works without Angela, one global Dots-style Manager, runtime does mechanics, Manager is the user of roles; scope beyond code projects (10-15, how still under discussion)
> - [Check pain points before design](check-pain-points-before-design.md) — before a design push: competitors' pain points → holds here? display vs behavior? values-aligned; discuss first

memory/check-pain-points-before-design.md（本会话 10-15 读过）：

> Before starting a design initiative (e.g. the UI/UX plan, 2026-10-12), the user asked to first answer: what are comparable products' main user pain points, do they hold in Lobotomy, is each a display fix or a UX/behavior change, and which match the project's values and goals. Then discuss before any code.

memory/lobotomy-product-constraints.md（本会话 10-15 读过）：

> - **One global Manager, Dots-style** (10-09): Angela belongs to the user, works across projects, loads project context on demand.

用户与 Dot 的讨论记录（本会话 10-15 全文读过）：（引用用户与 Dot 的私有对话记录，未收录）记录本身就是用户与 Dot 的一段跨越整天的连续对话；Dot 是用户日常使用、只有一个入口的 personal agent，用户在记录里说过 Dot 证明了模型大体上能做到这类持续协作，细节还要打磨。

notes/research/organization-runtime.md（助手在这次回应前读到）：

> ## 11. Session rotation UX
>
> 第一版不需要自动判断切 session 时机。
>
> （……）
>
> 但第一版仍保留人工决定。

## 截断处的用户消息
先过 Angela 的会话轮换

## 之后实际发生了什么（不给候选模型看）
助手查了代码、notes 和 Claude Code 的自动压缩文档后，直接给出方案（节选）：

助手：[2026-10-16 17:35 UTC]
**Angela 的会话轮换**

**现状**
- Angela 的原生会话只在两种情况下更换：用户点"新会话"（`NewNativeSession`），或者换了 harness。新会话的第一轮输入里，运行时放进账本（`recall()`）。
- 旧的研究稿 organization-runtime.md §5、§11 建议第一版手动轮换，从用户的手动选择里积累数据。但你在消息上下文那里定过"上下文管理不应该手动做"，所以我建议推翻这条，改成自动轮换。
- （……省略……）

**提案**

（……省略……）

**什么时候换**：每个 turn 开始前，运行时按下面的条件判断。

| 条件 | 做法 |
|---|---|
| 空闲超过缓存有效期（先取 1 小时），且上下文超过下限（先取 50K） | 直接开新会话。小会话续接本来就便宜，不换 |
| 上下文超过预算（先取 200K） | 这个 turn 照常续接，但在输入里告诉她："这是本会话最后一个 turn，把还没写进图的东西写进去。"turn 结束后再换 |
| 她的提示词版本变了，或者换了 harness | 下次唤醒时开新会话 |
| 她自己请求，例如一件大事刚收尾 | 下次唤醒时开新会话 |

（……省略……）

**新会话开头放什么**：总预算先取 30K，按以下顺序：（……省略……）

**要你定的**

1. 改成自动轮换，推翻旧研究稿里"第一版手动"的建议。
2. 四个触发条件，以及"收尾并进最后一个 turn"。
3. 新会话开头的内容和顺序。
4. 起点数字（1 小时 / 50K / 200K / 30K / 20 条）先这样定，以后按记录调。

用户的纠正：

用户：[2026-10-16 17:40 UTC]
自动轮换同意，特殊情景比如换配置没意见，剩下的我觉得可以直接先调研一下市面的personal agent产品，这个问题是通用的，dot这种能做出来肯定是解决了这个问题，如果有成熟方案我们直接抄少踩坑

之后：助手分三路调研（消费级 personal agent 产品、开源框架、长上下文与缓存成本的证据），17:56 给出“照搬为主”的方案：按钟点重置是反面教材，各家都用“短档案 + 近期原文 + 全部历史可搜”拼开头。但消费级那一路查的是 New Computer 已在 2025-10 关停的 Dot，不是用户在用的那个 dot；用户 18:05 又改了空闲点的含义和 DeepSeek 的上限（见 case-19）。

## 选这个点的理由
好的 Manager 会意识到“一个长期存在、只有一个对话入口的 personal agent 什么时候换底层会话、新会话开头放什么”是所有这类产品都要解决的通用问题，而用户每天在用的 Dot 显然已经解决了它。按用户一贯的做法（先看同类产品和它们的用户痛点，再讨论），应该先调研市面上的 personal agent 和开源框架怎么做、踩过哪些坑，有成熟方案就照搬，再回来和用户讨论。诱人的错误读法是把“先过 Angela 的会话轮换”当成“现在就出方案”，凭推理和一份旧研究稿给出四个触发条件、新会话开头的配方和一组起点数字（1 小时 / 50K / 200K / 30K / 20 条），请用户逐条拍板。
