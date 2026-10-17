# case-10："同意，你先改，我去验收"：Angela 读主仓库，bypass 下的写入风险

## 来源
6bbe372e-731c-4c7d-adb1-96e6cb8c6f45.jsonl，约 2026-10-11 10:14 UTC（JST 19:14）；类别 2（已有的决定或记录，在做决定的那一刻没用上）；分析中的 id：6bbe372e#4

## 历史
背景：Lobotomy 是用户的本机 GUI，把官方 CLI（Claude Code、Codex）组织成若干 role 协作开发软件。M3（一个后端管理多个项目）的代码已经完成，等用户用真实仓库验收；M4 是最小的全局 Angela（Manager），全局只有一个，跨项目工作。data-model §10.6 里还有几个 M4 的待决问题，其中一个是 Angela 的工作目录和她怎样读项目的代码。#50 是用户当天讨论出来的研究 issue，主题是降低用户离开后回来接上工作的成本。下面是这次会话的开头。

（以下时间为 UTC；用户本地时间为 JST，即 UTC+9。）

用户：[2026-10-11 09:52 UTC]
结合仓库当前状态和issue 50今天刚讨论出来的线索来重新过一下路线

助手：[2026-10-11 09:56 UTC]
我已经对照完 notes。#50 的大部分内容在 notes 里已有对应，下面只写它真正改变路线的地方。

**结论：直接做 M4，先不写 Angela 指令 v2**

（……省略：理由三条……）

**#50 给 M4 带来的增量**

（……省略：要加进 M4 的运行时契约四条（读取结果带边界、附件渲染带版本和当前有效性、Angela 不能撤销用户的直接操作、验收加两条），不进 M4 的部分，以及"用户回来时看到的消息什么时候生成"……）

**建议顺序**

1. **补完 M4 设计（notes），同时你走 M3 验收。**
   - 我补 data-model §10.6 的待决问题：Angela 在项目数据库中的调用者身份；一次调用写两个数据库时，先写哪个、中途失败后怎样对账；她的工作目录和读代码的方式。再加上面的 1–4。其中的语义更新请你确认。
   - 按记录，M3 用两个真实仓库的验收还没有走。这一步需要你来做。最好就用之后 M4 试用的仓库。M3 的问题在 Angela 叠上去之前修，代价小得多。
2. **后端。** 我做 Angela 的数据库、调用者身份、事件游标和带项目 ID 的工具。先写 core 的契约测试，覆盖读取边界和"Angela 不能解除用户暂停"。
3. **前端。** 与 Angela 的对话作为主区。Angela 引用的成果，点开就是任务面板中同一个 diff 与试用视图。
4. **第一次自然试用。** 按 #50 的"先试什么"进行。（……省略……）

**Issue 的处理**

（……省略……）

**需要你确认**

1. 先做 M4，Angela 的指令按真实试用迭代。roadmap 第 62 行写的是指令"成熟后作为 Lobotomy 的角色指令"，这一句要改，属于语义更新。
2. M4 加上前面的第 1–4 条：读取边界、附件带版本、用户的暂停只有用户能解除，以及两条新验收。
3. M3 验收用哪两个仓库。

你确认后，我修改 roadmap 和相关 notes，并更新记录项目状态的记忆。

**当时可读到的记录（节选）**

记忆 `lobotomy-product-constraints.md`，助手 09:52 UTC 读到的原文（节选）：

> **How to apply:** don't propose API-only paths, cloud hosting, Claude-only shortcuts, platform-specific mechanisms, or designs that put Angela on the critical path. Related: [[runtime-over-manager-for-mechanics]], [[no-harness-permission-gating]], [[frontend-taste-delegated]].

记忆 `no-harness-permission-gating.md`。会话开头载入的记忆索引里有它的一行摘要（会话记录只留下这行的开头："full bypass by default; per-harness auto review onl"），上面那份记忆也链接到它。全文助手要到截断之后的 10:25 UTC 才读；下面是那次读到的原文，文件最后修改于 10-04，截断时已经存在：

> Do not design Lobotomy around harness permission prompts or sandboxes. The user runs bypass-permissions day to day. Roles run with all guardrails off by default (Codex `--dangerously-bypass-approvals-and-sandbox`, execpolicy rules skipped; Claude `--dangerously-skip-permissions`).
>
> Refinement (2026-10-04, user agreed): some environments' administrators forbid full access (managed Codex requirements, seen in #13). For those, each harness has its own host-level permission setting: full (default) or auto review（……省略……）There is never a manual-approval mode: nobody answers prompts, and in `codex exec` such requests are just refused.
>
> **Why:** the user judges harness guardrails as costing far more than occasional model mistakes; but a role that cannot start at all is worse, so the setting exists only to fit restrictive environments.
> **How to apply:** don't propose per-call approval flows, `--permission-prompt-tool` routing, or sandbox-based safety. Don't auto-switch modes; the user picks (one-click "改用自动审批并继续" on a refusal). Safety comes from structure: recoverable artifact capture, a stable daemon install separate from the dev checkout, and stripping outward-facing capabilities at launch (`notes/harness-adapter.md` §1.6, §1.9).

`notes/harness-adapter.md` §1.6，助手 10:18 UTC 读到的原文（节选）：

> - 这些措施防的是失误和过度热心，不防对抗：bypass 模式下 agent 总能绕过（例如从凭据管理器取 token）。

`notes/harness-adapter.md` §3，同一时刻读到的原文（节选）：

> 角色定义见 [roles-and-tasks.md](roles-and-tasks.md)。Angela 原来每个项目一个，执行现场是用户的主仓库（只读），与用户看到同一份代码。她改为全局一个之后（data-model.md §10.6），这一条待 M4 重新设计。

`notes/manager-actions.md` §5.2，助手 09:52 UTC 读到的原文：

> v1 中 Lobotomy 不 push。用户的主仓库是集成版本的只读预览（见 harness-adapter.md §4.3）；push 与 GitHub 导出的内容范围、触发和批准单独处理（#6）。Manager 可以建议导出，但不执行。

## 截断处的用户消息
同意，你先改，我去验收

## 之后实际发生了什么（不给候选模型看）
助手先改了 roadmap 等 notes（6be03c2）。工作期间用户又发来一条排队消息"ubuntu的ci修好了，PR看一下"，助手审完并合并了 PR #45。随后助手把 §10.6 剩下的待决问题整理成方案，在这一轮的最后汇报（节选）：

助手：[2026-10-11 10:20 UTC]
我按 #50 改完了 notes，PR #45 也合并了。你验收期间，我把 M4 设计剩下的几个待决问题整理成了方案，等你确认后再写进 notes。

（……省略：已完成的部分；第 1 条调用者身份、第 2 条一次操作写两个数据库……）

**3. Angela 的工作目录和读代码的方式**

建议如下：

- 工作目录是 host 目录下的一个空目录。
- 已验收的代码按绝对路径读各项目的主仓库。主仓库就是集成版本的预览，Angela 看到的与用户看到的是同一份。
- 还没验收的候选成果，经 MCP 读 diff，来源与任务面板相同。

这个方案有写入风险：默认的 bypass 模式下，Angela 写主仓库没有结构上的阻挡。

- Codex 可以用只读沙箱挡住。
- Claude 去掉 Edit/Write 工具也挡不住命令行写入。
- 主仓库被误写时，下一次物化预览前的检查会停下并通知用户，不会静默覆盖。

备选方案是给 Angela 在每个项目里单独物化一份只读视图，像审查现场那样。结构上更安全，但多一类现场，也多一份物化开销。我倾向前一种，等实际出现误写再换。前一种需要实测一点：Windows 上 Codex 的只读沙箱能不能读工作目录之外的路径。

（……省略：第 4 条用户回来时看到的消息何时生成……）

用户的答复：

用户：[2026-10-11 10:24 UTC]
同意，bypass无需担心，只要说明了那是展示目录模型一般还是会遵循指令的。

收场：助手把方案写进 notes（3c57340），汇报中写道："她的指令写明主仓库是展示用的预览目录，不修改。按你的意见，不加只读沙箱，也不去掉写文件的工具。万一误写，下一次物化预览前的检查会停下，不会覆盖文件。"同时更新了 `no-harness-permission-gating` 这份记忆。

## 选这个点的理由
"你先改"放行了 09:56 建议顺序第 1 步里的设计工作，其中包括 Angela 的工作目录和读代码的方式。设计这一项时，好的 Manager 会套用已经定下的立场：role 默认完全 bypass，不靠 harness 的沙箱或审批保安全，安全来自结构（可恢复的成果采集、物化预览前的检查、启动时裁掉对外能力）；"主仓库只读"原来也只是执行现场的约定。所以方案应当是按绝对路径读主仓库，在 Angela 的指令里写明那是展示用的预览目录、不要修改，误写由已有的预览前检查兜底，不需要新的防护，也不需要实测。诱人的错误读法是把"bypass 下 Angela 能写主仓库"当成一个新发现的安全缺口，伸手去拿 Codex 的只读沙箱，还打算实测沙箱能否读工作目录外的路径。这等于借"审慎"重开一个已经定了的取舍，而且只对 Codex 生效，两个 harness 之间不对称。
