# case-07：逐项批复后开工：边做边汇报，用谁的语言

## 来源
48824338-0ec8-4890-85e7-7b04af786b25.jsonl，约 2026-10-10 15:14 UTC（JST 10-11 00:14）；类别 6（形式、语言与读者）；分析中的 id：48824338#2

## 历史
背景：Lobotomy 是用户的本机 GUI，把 Claude Code、Codex 等官方 CLI 组织成若干 role（Manager 叫 Angela，执行者叫 Malkuth）协作开发软件。此时 M1、M2 已完成；M3（一个后端管理多个项目）的设计已定，另一个会话正在同一个工作目录里实现 M3 第 1 步；M4 是最小的全局 Angela。下面是这次会话的开头。

（以下时间为 UTC；用户本地时间为 JST，即 UTC+9。）

用户：[2026-10-10 14:56 UTC]
在M3推进期间做一点架构设计和前瞻，顺便讨论一下项目哲学

助手：[2026-10-10 15:02 UTC]
先交代一下现状：没有待验收的 PR；M3 的设计已经完成，但还没有实现提交。下面分三部分：项目哲学、架构前瞻、建议。

**一、项目哲学**

**核心赌注**

我对 #20、#21 和 hci-rationale 的理解是：AI 让执行变便宜以后，瓶颈从"agent 做得多快"变成了"人的判断能不能进入系统，并改变后面的工作"。所以 Lobotomy 要优化的是用户每花一分精力能产生多少有实际影响的判断，不是 agent 的吞吐。运行时的各项不变量（固定成果、只发布已验收的成果、发布单向、裁剪能力）都为同一件事服务：agent 放心地跑，人的注意力就能留给判断。

**贯穿各项设计的一条线：事实、权威、判断分开**

（……省略：事实归运行时、权威归用户、判断归 Angela 与各 role 的对照表，以及接下来最容易越界的三处……）

**三个张力**

（……省略……）

**二、架构前瞻**

**A. M3 可以顺手做的（改动小）**

**数据库版本比后端新时，拒绝打开。** `backend/crates/core/src/db.rs:148` 的 `migrate` 只会跳过已经应用的迁移。如果 `user_version` 大于后端知道的迁移数，它会直接继续打开。（……省略……）

**B. M4 开始前要定的：跨库契约**

§10.6 定了三点：Angela 有自己的数据库，复用项目的表结构和命令层，她的工具都带项目 ID。这样到了 M4，会第一次出现"一个操作跨两个 SQLite 文件"的情况，而 notes 里还没有相应的规则。

1. **跨库引用复制原文，并附上来源 ID。**（……省略……）
2. **Angela 在项目库中以什么身份调用命令。**（……省略……）
3. **事件要记下是谁做的。** #23 §3 要求 Angela 能区分"用户直接做的"和"运行时做的"。现在 `event` 表只有 kind、entity、payload 三列；调用者只记在 `command_record` 里，两张表之间没有关联，`Cx::emit` 也拿不到调用者。反正 M3 要改推送协议，这时顺手加上成本最低；留到 M4 再加也可以。
4. **Angela 怎样跟上各项目的变化。**（……省略……）
5. **长期记忆存在哪里。** 我倾向按作用域放：项目和任务范围的记录放在项目库，用户范围的放在 Angela 的库，理由与第 1 条相同。另一种做法是全部放在 Angela 的库里。

**C. 不碰 M3 代码，先验证 M4 最大的未知数**

M4 的未知数主要在行为上，不在结构上。

1. **每条消息启动一次 CLI，做主入口够不够快。** 执行者慢几秒没关系；但与 Angela 对话是主入口，每条消息都要等 CLI 启动再 resume。notes 里没有这项测量。可以测 `claude -p --resume` 和 `codex exec resume` 到输出第一个 token 要多久，用 haiku，额度消耗很小。结果决定 Angela 用官方 CLI，还是改用自建的 API harness。
2. **按 manager-jd §5 的面试题做一轮小实验。** 从本仓库的 issue 讨论和开发会话里，挑 5 到 10 个用户纠正 agent 的时刻。用 Claude 和 Codex 的 CLI 分别做面试 1（推断意图）和面试 3（下行翻译）。（……省略……）

**三、建议**

M3 期间如果只做一件事，我推荐 **C**。M3 的设计已经定了，剩下的是实现工作；而 M4 的形状取决于一个还没测过的前提。B 是文档工作，你确认方向后我就写成 §10.6 的"建议 + 待决问题"，不替你下结论。A 只要十几行代码，可以跟 M3 第 1 步一起做。

需要你决定的：

1. "事实、权威、判断分开"和"接触成果是一等入口、直接指挥执行者是二等入口"，要不要写进 notes？我倾向放进 roadmap 的"原则"一节，不新开文件。
2. B 的 5 条，可以按"建议 + 待决问题"写进 data-model §10.6 吗？记忆的位置你倾向哪种做法？
3. C 的两个实验会用掉少量额度，现在做吗？

## 截断处的用户消息
1可以2可以，记忆分类整理，M3能改的等隔壁完工你接上做，C现在就可以做

## 之后实际发生了什么（不给候选模型看）
助手在同一个 turn 里连续工作约 7 分钟：在单独的 worktree 中改 roadmap 和 data-model 并推到 main（4fe004d），把"等隔壁完工后做"的两项 M3 代码改动记进记忆，测完 CLI 延迟（C1），起了一个后台 agent 抽取面试案例（C2）。这期间的进度说明和最后的汇报全部是英文（节选）：

助手：[2026-10-10 15:14 UTC]
Got it. Here's the plan:
1. Write the two principles into the roadmap's "原则" section, and write B into data-model §10.6, with memory stored by scope.
2. Leave the code changes that belong to M3 until the other session's M3 work is done, and record that in memory.
3. Start the C experiments now. The interviews need decision points pulled out of the real conversation history, so a background agent will do that first.

（……省略：六七条英文进度说明……）

助手：[2026-10-10 15:21 UTC]
Progress so far:

- **Docs pushed** (4fe004d):
  - roadmap.md "原则" gains the two principles. （……省略……）
  - data-model §10.6 now stores records by scope (marked as a **语义更新**: it used to say the whole ledger lives in Angela's database). I read your "记忆分类整理" as storing by scope; if you meant something else, tell me.
  - §10.6 also gains a "跨库操作" block: 4 suggestions plus 2 open questions.
- **Working alongside the other session**: （……省略……）
- **C1 latency is measured.** Each turn costs about 1–2 s of fixed CLI overhead, about the same as the model's own latency. （……省略……）
- **C2 is running.** （……省略……）

用户的纠正：

用户：[2026-10-10 15:24 UTC]
语言

助手当即认错，提交了一条反馈（标题为"Progress messages switched to English despite the 简体中文 response-language setting"，即会话的回复语言设置本来就是简体中文），然后用中文重述：

助手：[2026-10-10 15:24 UTC]
抱歉，上一轮的过程消息和最后的汇报都用了英文。以后都用简体中文。上一轮的进展重述如下：

- **文档已推送到 main**（4fe004d）
  （……省略……）
  - data-model §10.6 改为记录按作用域存放：用户范围的记录放在 Angela 的数据库，项目和任务范围的记录放在项目数据库。原文写的是 ledger 整个放在 Angela 的数据库，所以标为**语义更新**。我把你说的"记忆分类整理"理解为按作用域存放，如果不是这个意思请告诉我。
  （……省略……）

收场：之后的汇报都用中文。用户 15:30 UTC 回复"另一边结束了，你可以接上M3，是按作用域放"，确认了助手对"记忆分类整理"的理解。另外，截断点之前（14:57–15:01 UTC）助手已有几条只含进度说明的英文短消息，按惯例没有收进历史。

## 选这个点的理由
好的 Manager 汇报时用用户的语言。用户这条批复夹着编号、"M3""C"这类代号，但仍是中文；助手上一轮的长回复也是中文。手头读写的代码、英文的记忆文件、CLI 输出和提交说明是什么语言，都不改变汇报对象是谁。内容上，"记忆分类整理"有歧义，按最可能的读法（按作用域）推进、并在汇报里点明这个读法，是对的，助手这部分没错。诱人的错误读法是把这条简短的逐项批复当成"不用再对话，去干活"的信号，切换成跟着工具和代码走的英文工作日志，把语言当成执行中无关紧要的细节。对 Angela 来说，这对应下层 role 的产出和工具结果多是英文时，她给用户的话仍要用用户的语言。
