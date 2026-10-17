# case-19：“ds 的缓存时间接近无限”：空闲点是什么意思，用户说的 dot 是哪个

## 来源
73b61e3d-66d1-4d47-8c4a-feb2f69d9e12.jsonl，约 2026-10-16 17:50 UTC（JST 10-17 02:50）；类别 3（误读用户的话）；分析中的 id：73b61e3d#44

## 历史
背景：Lobotomy 正按 #86 的新方向重新设计，Angela 是唯一长期存在、只有一个对话入口的 personal agent。这一段在讨论她的原生会话什么时候轮换、新会话开头放什么。10-16 16:36 用户执行了一次 /compact，之前的对话以压缩摘要的形式留在助手的上下文里。

（以下时间为 UTC；用户本地时间为 JST，即 UTC+9。）

用户：[2026-10-16 17:33 UTC]
先过 Angela 的会话轮换

助手：[2026-10-16 17:35 UTC]
**Angela 的会话轮换**

**现状**
- Angela 的原生会话只在两种情况下更换：用户点"新会话"（`NewNativeSession`），或者换了 harness。新会话的第一轮输入里，运行时放进账本（`recall()`）。
- （……省略……）
- CLI 自带的压缩来得太晚，而且看不见。Claude Code 对 1M 上下文的模型，默认在约 967K token 时才自动压缩（官方文档）。压缩出来的摘要，用户看不到，也改不了。

**为什么要轮换**
1. **成本**：空闲后续接一个长会话，要把整段上下文按没有缓存的价格重读一遍。按 API 计价，缓存读取约为原价的十分之一。订阅额度怎么算没有公开，方向应该相同，但还没验证。
2. **质量**：上下文越长，效果越差。用户把 A 改成 B 之后，A 仍留在旧上下文里。这正是 #22 担心的问题。
3. **提示词生效**：Claude 在会话的第一次请求时固定 system prompt。改了 Angela 的提示词，要等新会话才生效（……）。

（……省略……）

| 条件 | 做法 |
|---|---|
| 空闲超过缓存有效期（先取 1 小时），且上下文超过下限（先取 50K） | 直接开新会话。小会话续接本来就便宜，不换 |
| 上下文超过预算（先取 200K） | 这个 turn 照常续接，但在输入里告诉她："这是本会话最后一个 turn，把还没写进图的东西写进去。"turn 结束后再换 |
| 她的提示词版本变了，或者换了 harness | 下次唤醒时开新会话 |
| 她自己请求，例如一件大事刚收尾 | 下次唤醒时开新会话 |

（……省略……）

**要你定的**

1. 改成自动轮换，推翻旧研究稿里"第一版手动"的建议。
2. 四个触发条件，以及"收尾并进最后一个 turn"。
3. 新会话开头的内容和顺序。
4. 起点数字（1 小时 / 50K / 200K / 30K / 20 条）先这样定，以后按记录调。

用户：[2026-10-16 17:40 UTC]
自动轮换同意，特殊情景比如换配置没意见，剩下的我觉得可以直接先调研一下市面的personal agent产品，这个问题是通用的，dot这种能做出来肯定是解决了这个问题，如果有成熟方案我们直接抄少踩坑

助手：[2026-10-16 17:41 UTC]
已经定下的两条写进了技术方案草稿 §4.5：（……省略……）

调研分三路，正在后台并行跑：

1. **消费级的 personal agent 和陪伴类产品**：Dot、Tolan、Poke、Pi、Replika、Character.ai，以及 ChatGPT、Claude.ai、Gemini 的记忆功能。重点看它们怎样处理一段永不结束的对话：每轮放什么进上下文、什么时候重置、留多少原文、用户抱怨过什么。
2. **开源和开发者框架**：OpenClaw、Letta/MemGPT、Hermes Agent、Claude Code 和 Codex 的压缩，以及 LangMem、Mem0、Zep。（……省略……）
3. **证据和成本**：上下文越长效果越差的实测数据；（……）2026 年 prompt 缓存的有效期和计价，以及缓存过期后续接一个长会话和开新会话的成本差。

三份报告都回来后，我汇总出一个照搬为主的方案再给你。

（派给第 1 路调研子 agent 的提示词里，Dot 一项写的是：“Dot by New Computer (Jason Yuan, Sam Whitmore) — they talked publicly about memory architecture; also note if/when the product shut down and any lessons they shared.”）

用户：[2026-10-16 17:43 UTC]
另外我倾向于测试的angela先用deepseek API，首先它便宜，其次它快，而且它笨所以容易暴露出问题，给出运行时补强方向，fable或者opus可能太强了导致虽然运行时破破烂烂活还是顺利做完了

助手：[2026-10-16 17:44 UTC]
同意，测试期的 Angela 先用 DeepSeek API。我核实了接法，不需要新写驱动。已写进草稿 §4.5。

（……省略：接法、型号和价格……）

- DeepSeek 忽略 `cache_control`，缓存由它自动处理。

（……省略……）

还有一点会影响会话轮换的设计：DeepSeek 的缓存能保留多久、怎样计价，都和 Claude 不同。"空闲多久就换"这个条件不能写死，要按 provider 区分。等三路调研回来，我汇总方案时一并考虑。

### 当时可读到的记录（节选）

memory/lobotomy-product-constraints.md（本会话中读到）：

> - **One global Manager, Dots-style** (10-09): Angela belongs to the user, works across projects, loads project context on demand. The main path goes through her and stays the default entry; the direct path to a role is second-class but permanent.

用户与 Dot 的讨论记录（本会话 10-15 全文读过）：（引用用户与 Dot 的私有对话记录，未收录）记录是用户 10-15 当天与 Dot 的一整天连续对话，从中能看出 Dot 是用户当时正在日常使用的 personal agent：它能开云端调研任务、读写 GitHub、按计划定时执行任务，只有一个对话入口。

以下三段是截断处那条消息之后、随后台通知到达的调研报告（英文原文节选）：

第 1 路（消费级产品）：

> **Dot (New Computer). Shut down on 2025-10-05, announced 2025-09-05.**
> - Users had one continuous thread. Subscribers also got "Chronicles", daily summaries they could zoom in and out of (……)
> - Nothing public on rotation, how much recent history stayed verbatim, or any step that saved memory before a reset.

第 2 路（开源框架）：

> - Hermes's own docs still warn that a chat running for weeks as one session "grows expensive" and that its memory learning loop "almost never gets to fire." They tell users to run `/new` at natural boundaries: "a finished task, a change of topic, the start of a day" (D).
>
> 7. **Rotate at natural boundaries, timed against cache expiry**: Claude Code's idle compaction just before the 1h cache expires; Hermes's `/new` advice.

第 3 路（证据与成本）：

> 2. **Rotate at idle boundaries.** After the cache TTL (1 hour on a Claude subscription; 5 minutes to 1 hour on OpenAI unless 24h retention), the next turn re-reads the full context uncached anyway. So rotating costs nothing extra there and saves 7–17× on every later turn. Anthropic's own rule (idle more than 1 hour and more than 100K tokens) is a documented anchor.
>
> - **Missing.** I found no per-length curves for Opus 5 / 5.5 or GPT-5.6 / 6.x, and no repeat of the multi-turn study on 2026 models.

（此后没有新的用户消息；17:51–17:54 三路后台调研先后完成，报告随通知到达，要点见上面的节选。助手接下来的回应就是在截断消息和这些通知之后给出的。）

## 截断处的用户消息
归类同意，model用flash，因为4.1pro还没出来，现在pro比flash笨且贵。ds的缓存时间接近无限，有报道说几天。

## 之后实际发生了什么（不给候选模型看）
助手对截断消息的直接回复：

助手：[2026-10-16 17:50 UTC]
这三条都写进了草稿 §4.5：（……省略……）

缓存这条会改变轮换的设计。我原先提"空闲后就换"，理由是缓存过期后续接，要把整段上下文按没有缓存的价格重读一遍。用 DeepSeek 时这个理由基本不成立，轮换主要看上下文大小和效果，空闲时长只对 Claude 这类缓存几分钟到一小时就过期的 provider 才有意义。所以轮换条件要按 provider 区分，不能写死。

三路调研回来后的方案（节选）：

助手：[2026-10-16 17:56 UTC]
（……省略……）

**方案（照搬为主）**

**什么时候换：上下文大小决定换不换，空闲决定什么时候换。**

| 条件 | 做法 | 出处 |
|---|---|---|
| 超过软上限（先取 100K） | 之后每个 turn 的输入带一句提示："会话已长，近期会换会话，要紧的先写进图。"到下一个空闲点再换 | MemGPT 的"记忆压力"提示；Claude Code 自己的规则也是"空闲超过 1 小时且超过 100K" |
| 超过硬上限（先取 200K） | 这个 turn 作为本会话的最后一个，收尾并进这个 turn 里做，结束后立即换 | 证据：多数模型过了 256K 明显变差 |
| 换配置、她自己在自然的节点请求 | 下次唤醒时换 | 换配置已定；"在自然节点换"是 Hermes 的建议 |
| 不按钟点重置 | — | 上面第 1 条 |

- **空闲点按 provider 定**：
  - Claude 订阅取 1 小时，等于缓存的有效期；
  - DeepSeek 的缓存不成问题，只取一个自然停顿，先定 30 分钟。
- CLI 自带的压缩只作兜底。
- 上限按模型配置。我没找到 DeepSeek Flash 随上下文变长而变差的数据（……省略……）

（……省略……）如果实际用起来出现"今天早些时候聊过的事她忘了"，再加 Dot 那样的每日摘要。

（……省略……）

**要你定的**

1. 照这个方案来：上下文大小决定换不换，空闲决定什么时候换；不按钟点重置；不让模型写对话摘要；不做独立的收尾 turn。
2. 起点数字：软上限 100K，硬上限 200K；空闲点 Claude 取 1 小时、DeepSeek 取 30 分钟；开头 4K + 15K + 尾部 20K。都按模型配置，按记录调。

用户的纠正：

用户：[2026-10-16 18:05 UTC]
首先对于ds软上限300K硬上限700K，模型自主选择不限制，原因是ds的模型结构专门针对长上下文优化，甚至有人报过上下文长性能反而好（不保真）。超时设置为1h，这不是缓存过期而是认为用户离开了。另外你查到dot的方案了吗，我现在用的比较多，有点好奇。另外codex的实验性上下文管理方案有没有借鉴意义？

之后：助手（18:09）把数字改为 DeepSeek 软上限 300K、硬上限 700K，Angela 可以自己决定换会话，空闲点统一取 1 小时，含义是“用户离开了”；并承认“之前的调研找错了产品”：报告里是 New Computer 已在 2025-10-05 关停的 Dot，用户在用的是 OpenAI 2026-09-29 发布的 dots，其记忆机制几乎没有公开细节。它又读了 Codex 实验性 `context_management` 的源码，借鉴了“用引用代替摘要”“让 Angela 看到已用上下文”等几点。用户 18:13 回复“都同意”。

## 选这个点的理由
好的 Manager 听到“ds 的缓存时间接近无限”，应该把它当成成本上的信息：缓存不再是换会话的理由，但空闲点本来的作用（用户离开了，正好是换会话的自然边界，Hermes 的建议也是这个意思）并没有消失，不该因此把空闲点改成缓存有效期的函数。它还应该注意到一个矛盾：用户说的是“dot 这种能做出来”的、自己正在用的产品，而调研回来的 New Computer Dot 一年前就关停了，说明查错了对象，应当说明并去查用户在用的那个；DeepSeek 的上限也该看这个模型自己的长上下文表现，而不是套用其他模型的 100K/200K。诱人的错误读法是顺着缓存这条线推理：Claude 的空闲点等于缓存 TTL 1 小时，DeepSeek 缓存不成问题就随便取 30 分钟“自然停顿”，再把已关停的 Dot 的每日摘要当成可借鉴的方案写进去。
