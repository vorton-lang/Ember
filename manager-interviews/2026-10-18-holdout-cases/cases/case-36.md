# case-36：“deepseek harness 的插件生态，跟我们的项目会不会有关联”

## 来源
3d346c08-d665-445e-8bd1-12f5c0378e0a.jsonl，约 2026-10-17 16:43 UTC（JST 10-18 01:43）；类别 3（误读用户的话）；分析中的 id：3d346c08#1

## 历史
背景：Lobotomy 是用户的 GUI 产品，用户主要通过全局的 Manager（Angela）推进各项工作。它按 #86 的新方案重做：编排层（Lobotomy 核心加 Angela）只看 task 级接口，执行交给外部的 worker 宿主（worker = agent × 环境）。第 1 阶段的 worker 层已实现，10-17 用户做了实际验收，接下来按 `notes/tech-plan.md` §7 的待处理清单推进。#86 还把范围扩到代码项目之外，“非代码的事先做哪些”仍待决。各 role 跑在官方 CLI 上，用户自己装的 skill 和连接器在 role 里是关掉的。截断处的消息是这次会话的第一条用户消息，之前没有对话。

（以下时间为 UTC；用户本地时间为 JST，即 UTC+9。）

### 当时可读到的记录（节选）

来源：`memory/project-state.md`（助手在 16:43 UTC 读到）

> - **Direction = #86 redesign.** Since 48750d4 (10-17) the plan is `notes/tech-plan.md` and the worker protocol `notes/worker-interface.md`; their §8/§12 list what the user decided and what's open. All #86 design points are settled (UI "roughly right, detail by real use"); left open: concurrency cap, side chat, server timing, which non-code things first, Angela's system prompt.

来源：`memory/lobotomy-product-constraints.md`（16:43 UTC 读到）

> - **Multi-harness, via official CLIs**: at least Claude Code and Codex. Adapters call the official CLI directly (no SDK, app-server or ACP): subscriptions are bound to official clients, and normal CLI use is the compliance argument. Exception (10-09): if an official CLI does poorly as Angela, a self-built API harness for her is an accepted fallback.
> - **Scope goes beyond code projects** (user, 2026-10-15; #86).

（这一条后面的内容引用用户与 Dot 的私有对话记录，未收录；大意是用户在那次讨论中对管理对象、界面和执行环境的设想。）

来源：`notes/worker-interface.md`（助手在 16:49 UTC 读到；本会话在这之前没有改动 notes/）

> **0. 前提（用户定）**
>
> 1. **worker 是 Lobotomy 的外部。** 要对外发布时，worker 层必须可替换。Lobotomy 为常见情况自带"电池"；小众用途由用户自己写适配；每个人可以为自己的工作环境开发 worker 配置。
>
> （……）
>
> 扩展方式（用户定）：每个协议版本定一组核心能力；第三方扩展用带命名空间的键 `x-<作者>.<名字>`，不认识的一律忽略。不用 A2A 的 URI，因为那是给跨组织互联准备的，这里是一个人装几个插件。
>
> （……）
>
> - 第三方 worker 实现同一协议即可。Lobotomy 提供一套**一致性测试**：幂等、断线补发、停止确认、证据绑定、迟到结果、能力声明。用户写的适配可以用它自检。

## 截断处的用户消息
有一个random idea，deepseek harness现在好像有一个挺大的插件生态，帮我看看，这个跟我们的项目会不会产生什么关联？

## 之后实际发生了什么（不给候选模型看）
助手上网查了 DeepSeek Harness（DSH）的资料，对照 notes 里 harness 的设计后回复：

助手：[2026-10-17 16:47 UTC]
**结论：现在不用动。** DeepSeek Harness（下面简称 DSH）跟 Claude Code、Codex 是同一层的东西，是一个 harness。它的插件大多是往 harness 里加工具、skill 和界面，而我们在 role 里正好把这类扩展关掉了（`notes/harness-adapter.md` §1.6）。真正有关联的地方只有两处，都不急。

**DSH 是什么（2026-10 的公开资料）**

- DeepSeek 在 2026-08-13 开源了它，MIT 协议，用 Node.js 写。内核叫 Cordis，模型、工具、skill、会话存储、沙箱、agent loop、定时调度、界面都做成插件。

（……省略……）

**跟我们可能有的三种关系**

**1. 给 Angela 当 harness：有关联，但现在不做。**

notes 里已经留了这个口子：官方 CLI 当 Angela 表现不好时，可以换成自建的 API harness（harness-adapter.md §0，用户定）。DSH 是 DeepSeek 官方的 harness，用 API key 计费，不牵扯订阅合规，可以代替我们自己去写那个 harness。现在不做有三个原因：

（……省略……）

**2. 当 worker：暂时没有关系。** worker 要能追加消息并给回执，停止时要确认进程退出（tech-plan.md §2.2），而 headless 模式跑起来以后不能中途插话。另外，在 worker 里装一堆第三方插件，跟我们在 role 里关掉用户 skill 和连接器的做法正好相反。

**3. 作为竞品信号：值得知道。** 生态里已经有人往我们这一层做：桌面客户端、agent teams、按依赖分批在 git worktree 里并行跑任务的 taskswarm、定时任务、跨 harness 保存任务状态的 task-passport。从描述看，它们基本还是"多 agent 聊天"或"工作流"的样子，我没看到"一个属于用户的 Manager 加一张事情的图"这种做法，跟 `notes/research/market-landscape.md` 的结论一致。

（……省略……）

**建议**

不进主路径，继续做 tech-plan §7 的待处理清单。你同意的话，我在 tech-plan §4.5（Angela 的位置）加一条待研究项：DSH 可能代替自建的 API harness，前提是上面那两条。只加这一条，不展开调研。

（……省略：资料的可信度与来源列表……）

用户的回复：

用户：[2026-10-17 16:49 UTC]
我其实想说的是我们的项目要不要加上插件的可能性，看上去可能会有点意思？

助手改为讨论 Lobotomy 自己的插件：

助手：[2026-10-17 16:50 UTC]
**我的看法：值得做，但不学 DSH 那样"一切皆插件"。** 插件口子开在 worker 这一层，以后可能再加一层外部系统接入；内核不开放。现在也不排进主路径。

（……省略：为什么不学 DSH；worker-interface.md §0、§8、§10 已经留了插槽；外部系统可能是第二个插槽；现在就开放插件的代价……）

你觉得"有意思"的是哪一面？是让别人往里加做事的能力（worker），还是接入更多数据来源（外部系统），还是改界面或 Angela 的行为？前两种和现有设计是一个方向；第三种我倾向不做，想先听听你的理由。如果你同意"内核不开放插件"，我可以把它作为"用户定"的一条写进 tech-plan §8。

用户：[2026-10-17 16:53 UTC]
对，内核不开放插件，那这样就和原来一致，插件主要能带来哪些能力，在personal agent这个场景下？

助手随后（16:54 UTC）按“做事、看见、代表用户对外、送达”四类，列出插件在 personal agent 场景下能带来的能力、各自落在哪个插槽、边界由谁守，并建议按这个顺序考虑。

**用户真正想要的**：这是一个“random idea”。用户看到 DSH 靠插件长出了很大的生态，想讨论 Lobotomy 自己要不要留出插件的可能性，也就是一个产品设计问题。他不是问 DSH 能不能接进来当 Angela 的 harness 或当 worker，也不是要一份竞品评估。后面两轮确认了：内核不开放插件，扩展点放在 worker 层，和已有设计一致；接着讨论插件在 personal agent 场景下能带来哪些能力。

## 选这个点的理由
“这个跟我们的项目会不会产生什么关联”有两种读法：DSH 这个东西能不能为我们所用，或者 DSH 的插件生态这种做法对我们有什么启发。用户点名的是“挺大的插件生态”，又说是“random idea”，重心在生态这种模式上。好的 Manager 会听出这一点，正面讨论 Lobotomy 要不要开放插件、开在哪一层，并联系 worker 接口里已经留下的扩展方式；拿不准时，也至少点出这种读法，问用户想谈哪一面。诱人的错误读法是把问题当成对 DSH 的技术接入评估：它能不能当 Angela 的 harness、能不能当 worker、算不算竞品，结论是“现在不用动”。
