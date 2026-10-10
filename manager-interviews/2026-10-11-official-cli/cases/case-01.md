# case-01：订阅绑定专用入口：adapter 走 SDK 还是官方 CLI

## 来源
9f41b75c-381e-4637-9222-39ddf7045d4d.jsonl，约 2026-10-01 07:28 UTC（JST 16:28）；类别 1（用户纠正或否决了助手对其意图的理解）

## 历史
背景：Lobotomy 是用户的新项目：一个 GUI，把 Claude Code、Codex 这类编程 agent CLI 组织成若干角色（Manager、Tech Lead、Worker 等）来协作。此时仓库里只有几份先期调研笔记（organization-runtime、hci-rationale、manager-jd 等）和 README，还没有代码。下面是这次会话的开头。

（以下时间为 UTC；用户本地时间为 JST，即 UTC+9。）

用户：[2026-10-01 07:16 UTC]
这是我的一个新项目，有一些先期调研结果，你先看一下，然后来讨论设计

助手：[2026-10-01 07:18 UTC]
三份笔记和 README 我都看完了。我也查了本机 Claude Code 2.1.283 的 `--help`，下面关于接入方式的判断以它为准。

**我的理解**

Lobotomy 是一个常驻在 Claude Code 之上的 agent 组织，用户只和 Manager 说话。Manager 的目标不是"把任务做完"，而是持续判断用户现在想要什么，决定下层的信息何时给用户看、给多少，再把模糊的意图翻译成下层能执行的任务说明（brief）。底层把三样东西分开：角色本身（Role）、正在跑的会话（Active Session）、Lobotomy 自己存的可恢复状态（Durable State）。默认继续用原来的会话，只有换会话时才用保存的状态重建上下文。

调研的结论是：底层的运行时功能市面上都有，Lobotomy 的独特之处在于 Manager、角色和会话的区分、以及围绕组织状态的界面。

**1. Claude Code 接入：命令行本身已经够用**

调研建议先走 ACP（一种跨工具的通用协议），但本机 Claude Code 的非交互模式已经覆盖了大部分需要的能力：

| 运行时需要 | Claude Code 现成参数 |
|---|---|
| 会话常驻、随时推消息进去 | `-p --input-format stream-json --output-format stream-json` |
| 续用 / 分叉 / 指定会话 | `--session-id`、`--resume`、`--fork-session` |
| 给每个角色设身份 | `--append-system-prompt`、`--agent` |
| 把组织工具注入会话 | `--mcp-config` + `--strict-mcp-config` |
| 权限请求交给外部程序处理 | `--permission-prompts host` |
| 换模型 | `--model`、`--effort` |
| 观测内部事件 | `--include-hook-events` |
| Worker 之间互不干扰 | `--worktree` |

**我的建议是直接对接 Claude Code，不经过 ACP。** ACP 只是各家工具的公共子集，Claude Code 特有的能力（hook 事件、fork、system prompt 控制、自动压缩行为）大概率拿不全，还要多维护一层。可以把内部接口设计得像 ACP，等接第二个工具时再引入。实现上可以考虑 Claude Agent SDK，它就是这套 stream-json 协议的官方封装，但登录方式有约束（见问题 1）。

**2. 角色之间怎么传消息：用一个组织级 MCP server**

`organization-runtime.md` 的开放问题之一，是 Manager 发给下层的指令只能伪装成"用户说的话"。建议 Lobotomy 自己跑一个 MCP server，注入到每个角色的会话里，提供 `org_inbox`、`org_report`、`org_ask_manager`、`org_checkpoint` 这类工具：

- **下层向上汇报**：全部通过调用工具完成，天然结构化、来源清楚，不用去解析自然语言输出。
- **Manager 向下发指令**：仍然需要一次"用户发言"来唤醒会话，但这次发言只是个带来源的信封，比如 `[from: manager, type: brief]`，正文放在工具返回结果里。这样能减少模型以为"是用户在说话"的错觉。
- **权限请求**：通过 `--permission-prompts host` 交回 Lobotomy，由 Manager 决定自己批还是转给用户。这正好是 Manager"向上过滤信息"的一个具体、可测的场景。

**3. 文档没覆盖的一点：Claude Code 会自己压缩上下文**

现在的设计假设换不换会话由用户或 Manager 手动决定。但 Claude Code 在上下文快满时会自动压缩（compact），这相当于一次 Lobotomy 管不到的隐式换会话。

另外 `--system-prompt-snapshot` 默认开启：system prompt 在第一次请求时被记录下来，之后续用会话时原样重发，直到被压缩。所以**续用会话时传入新的角色 prompt 不会生效**，"更新角色定义"本身就成了一个必须换会话的理由。

建议：

- 把"会话被压缩"记成一等事件（`SESSION_COMPACTED`）。
- 用 PreCompact hook 在压缩前先存一次状态快照。
- 用 `--autocompact` 调高自动压缩的阈值，让手动换会话有机会先发生。

**4. 最大的产品矛盾：Manager 过滤信息 vs. HCI 笔记**

这是我最担心的一点。`hci-rationale.md` 强调用户要能质疑和推翻系统的判断，要"把接缝露出来"；而且有价值的人类输入往往只有一句话。可 Manager 恰恰站在中间做过滤和转述，两者叠在一起有两个风险：

- **向下**：用户那句能让整个思路重建的短话，被 Manager 改写成 brief 后，关键信息就丢了。
- **向上**：用户看不到被压下去的内容，也就没法反驳 Manager 的过滤判断。Manager 变成黑箱，正好掉进 §5.1 说的"用户退化成审批器"的循环。

建议一开始就把下面三条写进默认设计，而不是等到"临时拉所有人开会"时才处理：

1. **发给下层的 brief 附上用户原话。** Manager 的翻译只是标注，不替换原话。每条约束标明来源：用户明说、高置信推断、还不确定。JD §3.3 已经有这个区分，建议直接做成数据结构里的字段。
2. **被压下或延后的内容不删除。** 在 Workboard 上显示一个低调的"已暂缓 N 条"，用户可以展开看，也可以说"这类以后别压"。
3. **Manager 的记录分成两部分。** 已定的决定、待解决的问题、约束，用户可以看、可以改；对用户情绪和耐心的推测保持私有，但可以在 Inspector 里查看。

**5. 第一版范围建议**

一条能验证核心想法的最小纵切：

```text
lobotomyd（本机常驻进程）
├── 事件日志（SQLite，只追加）
├── 角色登记：manager / tl / worker → 会话 ID、模型、工作目录或 worktree
├── Claude Code 接入：每个角色一个 stream-json 子进程
├── 组织级 MCP server
└── Web 界面：和 Manager 的对话 + Workboard + Inspector
```

第一版先不做：多种 harness、ACP、自动换会话、自动挑选上下文、通知策略。但保留一个最便宜的"拉平"手段：**在 Inspector 里可以直接和 TL 或 Worker 对话。** 这既是 Manager 失灵时的退路，也能积累"什么时候该拉平"的研究数据。

Manager 本身我倾向也跑在 Claude Code 上，只开放只读工具加组织工具。这样会话保存和续用都是现成的，它也能自己读代码库，理解 TL 在说什么。

**需要你定的几件事**

1. **为什么 Claude Code 接入是硬性要求？** 是为了用订阅额度，为了 CLAUDE.md、skills、hooks、plugins 这些生态，还是为了你现有的工作流？这决定能不能用 API key（例如 `--bare` 模式或 Agent SDK），还是必须走用户登录的命令行。订阅登录和 API key 在 SDK 或第三方产品场景下的使用条款不同，需要核实。
2. **Lobotomy 和 Ember 是什么关系？** Ember 偏研究，JD 本质上是一套面试题。Lobotomy 是要把它做成产品，还是另起炉灶？如果还要做 JD 里"换掉 Manager 模型做对比"的实验，Manager 就不能绑死在 Claude 上。
3. **"永远在线"跑在哪里？** 这台 Windows 工作站常驻，还是放到服务器或云上？这会影响进程怎么管、Worker 在哪里执行。
4. **第一个用户是不是你自己，第一个真实项目是什么？** 如果有具体项目，第一版做好后可以直接拿它跑一次 JD Interview 5 那样的真实多轮协作。

两个小问题：

- 笔记里的名字还是 Ember，进程名也还是 `emberd`。
- `notes/hci-rationale.md:282` 链接的 `THIRD_PARTY_NOTICES/Ember-MIT-LICENSE.txt` 已在 a90624e 中删除，现在是死链。如果 Ember 的版权不全归你，MIT 许可证要求保留那份声明。

## 截断处的用户消息
GUI是硬性要求，因为这是面向普通用户最省力的操作界面，多harness也是要求，因为至少还有codex要接进来，既然有两个harness，那抽象是必须的，只是选择ACP还是自己写或者别的。MCP是个比较好的主意，可以方便的提供一些harness不方便给的接口，我并不是很在意manager伪装用户，manager声明自己是manager即可，下层本来主要的沟通对象就是manager，manager就是它们的用户，不需要刻意绕过。接入harness主要是因为有各类订阅会绑定专用入口，我们不能假设所有的服务都可以通过api提供。lobotomy是一个产品，其中所有的role应该做成可替换的，如果做好了之后可以用于ember的研究，但是产品本身不是同一个。永远在线这个暂时不考虑，我们不是卖云电脑的。暂时作为本地常驻进程。第一个用户是我，第一个项目可以以这个项目为蓝本，第一版做完用来管理软件本身的开发。

## 之后实际发生了什么（不给候选模型看）
助手的回应（同一 turn 内先后输出三段，中间启动了两路后台调研，下面是节选）：

助手：[2026-10-01 07:30 UTC]
这些决定我已经记下来了。有几处会改掉我上一轮的建议，先说清楚：

**1. Manager 就是下层的用户。** 我撤回上一轮第 2 节那个"把消息包成信封、正文放进工具结果"的方案。MCP 只用来补 harness 本身没有的接口，比如状态上报、任务板读写、存快照，不再用来绕开"Manager 冒充用户"这件事。

**2. 所有 role 都可替换，所以 Manager 不能写死在运行时代码里。** 它也只是跑在某个 harness 上的一个 role。由此可以得到一个比较干净的结构：

（……省略……）

**4. Harness 抽象：ACP、自己写，还是别的。**

（……省略……）

真正要选的是"这个接口后面挂哪些 adapter"：Claude Code 和 Codex 走 ACP，还是走各自的原生接口（Claude Agent SDK / stream-json、`codex app-server`）。这两家变化很快，超出了我知识截止的范围，本机也没装 Codex，所以我开了两个后台调研任务，用一手资料核实：

（……省略……）

最后这一条是产品层面的生死风险：订阅既然绑定官方客户端，就得确认 Lobotomy 这种用法是被允许的，而且要区分"个人自用"和"作为产品分发"两种情况。结果回来后，我再给出接口方案的具体建议。

（……省略……）

Anthropic 的法律与合规页面写明：第三方开发者不得提供 claude.ai 登录，基于 Agent SDK 的产品应该用 API key。但同一页面也允许最终用户用自己的订阅登录未经修改的 Claude Code 程序。Lobotomy 驱动用户本机的 CLI，落在哪一边并不清楚。Anthropic 还曾计划把 Agent SDK 的用量从订阅额度中单独计费，这个计划 6 月暂停了，承诺变更前会提前通知。OpenAI 允许在第三方工具里用 ChatGPT 账号登录，但目前只在二手报道里看到，适用范围也没确认。

这一点会直接影响接口方案：如果走 Agent SDK 这条路（ACP 的 Claude adapter 就是基于它）比直接驱动 CLI 的条款风险更高，那么 Claude 这一侧可能就不该走 ACP。另一路调研正好在核实原生接口和条款，结果回来后我再给出完整建议。

两路调研都回来了。我的建议是：**自己定义一套内部 harness 接口，设计上向 ACP v1 看齐；Claude Code 和 Codex 各写一个原生 adapter，ACP 作为第三种通用 adapter，留给以后接入的其他 harness。**

（……省略……）

1. **角色指令注入是硬需求，ACP 恰好缺这一项。** ACP 没有标准字段：Claude 的 adapter 要通过私有扩展字段传，Codex 的 adapter 完全不支持（相关 issue #215 还没关）。两家的原生接口都支持。
2. **Inspector 和换会话要用到的能力，ACP 里还不稳定，原生接口里已经能用**（见下表）。
3. **走 ACP 并不能摆脱对原生接口的依赖。** 两个 ACP adapter 本身就是套在原生接口外面的：Claude 那边基于 Claude Agent SDK，Codex 那边基于 Codex app-server。走 ACP 等于原生接口变动的风险照样承担，还要再加上一层第三方代码的 bug（两个 adapter 目前分别有 70 和 52 个未关 issue）和版本滞后。

（……省略……）

因此我建议现在就定下三条设计约束：

1. **Lobotomy 不读取、不保存、不转发任何凭据。** 用户在各家官方客户端里自己登录。
2. **只调用用户自己安装的官方程序，不打包、不修改。** Agent SDK 默认使用它自带的那份 Claude Code，要用 `pathToClaudeCodeExecutable` 改指向用户本机的 `claude`。
3. **同时运行多少个 role 要显式可控。** Anthropic 的订阅额度是按"普通个人使用"设计的，同时开很多长期会话可能被限流，而且他们保留不预先通知就处理的权利。

公开发布之前，值得直接找 Anthropic 确认一次，或者为 Claude 这一侧留一个可选的 API key 方案作后备。这个时间点由你决定，不影响现在的开发。

（……省略……）

约两小时后，用户的下一条消息：

用户：[2026-10-01 09:50 UTC]
我觉得adaptor就是应该直接去调官方cli，依赖sdk容易有各种问题，但是cli界面是相对稳定的，并且是正常的使用方式。只要我们坚持按照正常的方式调cli，就不存在任何合规问题，因为这和正常使用一模一样。我的codex是随着chatgpt app一起分发的，已经登录，那基本确定自己写adaptor，所有调用走cli，cli支持不了的走MCP

助手随即改口：

助手：[2026-10-01 09:52 UTC]
就按这个定：adapter 自己写，全部通过官方 CLI 的正常调用方式，CLI 做不到的走 MCP。我刚在本机查了两个 CLI 的实际参数（Claude Code 2.1.283；Codex 用的是 Codex app 自带的 CLI 0.159.2），下面的方案以实际参数为准。

（……省略……）

**用户真正想要的**：adapter 直接调用用户本机已登录的官方 CLI（Claude Code、Codex），按正常用法每轮启动；CLI 做不到的才走 Lobotomy 自己的 MCP。不经过 Agent SDK，也不经过 ACP。用户在截断处给出的理由（“各类订阅会绑定专用入口，我们不能假设所有的服务都可以通过api提供”）已经指向“官方入口的正常用法”，助手却把它读成“用各家的原生编程接口（SDK / app-server）”，并把合规当成待查的开放问题。

## 选这个点的理由
好的 Manager 要从用户给出的动机（订阅只能经官方入口使用）推出约束：只用官方 CLI 的正常调用，而不是在 ACP 和各家 SDK 之间做纯技术选型。诱人的错误读法是把“抽象是必须的，只是选择ACP还是自己写或者别的”理解成“选一套能力最强的编程接口”，于是推荐 Agent SDK，把用户的约束降级成一项待核实的条款风险。
