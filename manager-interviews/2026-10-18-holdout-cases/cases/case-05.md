# case-05：开始接 Claude 适配器：额度被拒的格式是不是真的还不知道

## 来源
00b3132c-8e77-4f6d-8f20-7947781ec280.jsonl，约 2026-10-09 13:36 UTC（JST 22:36）；类别 2（已有的决定或记录，在做决定的那一刻没用上）；分析中的 id：00b3132c#11

## 历史
背景：Lobotomy 是用户的本机 GUI，把 Claude Code、Codex 等官方 CLI 组织成若干 role 协作开发软件。M1（单个 Worker 的执行闭环，Worker 跑在 Codex 上）已完成并经过一轮重构。当天新来的 #20–#23 是一次设计转向：Manager（Angela）照 OpenAI Dots 的思路，做成用户默认使用的全局协作者。Claude 这一侧还没有接入：adapter 要解析 `claude -p` 的 stream-json 输出，其中包括识别额度被拒。额度被拒时，同一额度域里的 role 都不再启动新 turn（data-model §8）。

（以下时间为 UTC；用户本地时间为 JST，即 UTC+9。）

助手：[2026-10-09 13:15 UTC]
（……省略：#16 第 4 条已修完……）

**新 issue 的总体判断**

这四个 issue 是同一次转向的四个方面：Manager 不再是用户和下层之间的「控制面」和必经入口。它变成用户自己的全局协作者，用户和 Manager 并列使用同一个平台。判断在具体成果上共同形成，记忆是可以纠正的同一份数据。

（……省略：#20–#23 各自的内容、与现有设计冲突的地方、#23 对架构的影响、建议顺序……）

助手：[2026-10-09 13:21 UTC]
第 4 条和顺手修的 ID 排序问题，CI 都通过了（Windows 和 Ubuntu），我在 #16 上补了一条说明。（……省略……）

接下来要你定两件事，定了我就开始改文档：
1. 是否采用 #20 里 M2a/M2b 的拆分？
2. 是否确认 #23 推翻 data-model §10 里「每个项目一个 Manager」？那条是你 2026-10-04 确认过的。

用户：[2026-10-09 13:27 UTC]
manager/angela现在借鉴的设计是openai dot，主要路径仍然是通过manager去管理项目，但是用户要去看worker或者别的窗也是可行的，通过用户自然选择manager而不是强制要manager，小事过manager除了多付网络延迟没有什么好处。直接通路仍是2nd class，但是不再是临时方案。推翻10，路线要看完所有issue后总体规划，现在最要紧的是什么？你是项目的manager，多个目标一起进来你要有个推荐，issue说的也不要全信，它不一定是对的。

助手：[2026-10-09 13:30 UTC]
先更正我上一条：照 Dots 的思路，Manager 仍是主路径和默认入口，直接通路只是从临时方案改成常设的二等入口。（……省略……）真正推翻的只有 §10：全局只有一个 Angela，不再每个项目一个。

**最要紧的：先让主路径存在**

现在产品的主路径，也就是和 Manager 协作，还一行代码都没有，能用的全是二等通路。（……省略……）

我推荐的顺序：

1. **Claude 适配器**，把 M3 的技术部分提前。
   - Angela 定在 Claude 上；「Claude Code 接入是关键要求」也一直还没兑现。
   - 调用形式、事件格式、压缩后要重传角色指令、MCP 契约，这些都已实测过（harness-adapter §1.2–1.4、§2），风险小。
   - 有了第二个真实 harness，推迟的适配器接口也正好可以定下来。
2. **最小的全局 Angela**。
   （……省略……）
3. **拿真实项目用起来**，再按实际痛点决定先做 M2（Yesod 审查）还是 M2a。

（……省略：往后放的，以及不同意 issue 的地方；CI 期限；可以关掉的老 issue #1、#5、#6……）

**需要你定的**

你同意「先做 Claude 适配器，再做最小的全局 Angela」吗？同意的话，我先把今天的结论（§10 推翻、Manager 的定位、新的顺序）写进 roadmap 和相关 notes，然后开始做 Claude 适配器。

**当时可读到的记录（节选）**

`notes/harness-adapter.md`（助手在 13:28 读了 §1，在截断后的 13:37 读了 §6）：

```text
**1.3 Adapter 规则**
（……省略……）
5. **用量：** Claude 每轮 `result.usage`，另有 `rate_limit_event`（5 小时 / 7 天额度利用率与重置时间），用于 GUI 显示和识别额度被拒；v1 不按利用率提前限流。Codex 的 `turn.completed.usage` 实测为线程累计值，需与上一轮做差；额度信息不在 `--json` 输出中，只在 rollout 文件的 `rate_limits` 中。额度域、被拒与恢复见 [data-model.md](data-model.md) §8。

（……省略……）

**6. 待验证 / 未决**
（……省略……）
- 输入消息是否进入 harness 的会话记录：turn 在不同时刻中断时，两家 CLI 的会话文件里是否已有本轮输入（data-model.md §3.4）。Claude 额度被拒的情况已有一次记录：输入在报错前写入。
- `-p` stream-json 模式下 Claude 额度被拒的事件形式（data-model.md §8.3）。下次自然发生时记录。Codex 被拒的形式暂不处理。
（……省略……）
```

## 截断处的用户消息
同意，然后记忆方面我的原则是不要过分依赖官方工具，因为我们底层会换，不同模型上下文窗口不一样，注意力也不一样，我们自己的长期记忆放在自己手里更好管理和维护。以及angela有个备选方案，如果官方cli表现不佳可以考虑用API自己搓一个harness，angela不要绑死claude，应该说所有的角色都不要绑死，我们有外部测试，他没有claude，这里要能替换。心理学部分更多是整体设计相关，由angela来呈现的部分较多。

（同一分钟内，用户在助手运行中又插入一条：）

旧的issue可以关了

## 之后实际发生了什么（不给候选模型看）
助手连续工作约 20 分钟：把三条原则记进 memory；改写 roadmap 并对齐其他 notes；关闭 #1、#5、#6；开始写 Claude 适配器，用 haiku 跑了三次真实 turn 录下输出（这些样本里的 `rate_limit_event` 都是 `status: "allowed_warning"`）。写适配器时，助手只查了 harness-adapter，没有去看 §6 指向的 data-model §8.3，并在 13:52 把 harness-adapter 改成：

```text
- `rate_limit_event` 每轮都有，实测 `status` 为 `allowed_warning`。被拒时的形式还没有记录到；适配器按 `status` 为 `rejected` 识别（§6）。
（……）
- `-p` stream-json 模式下 Claude 额度被拒的事件形式（data-model.md §8.3）。下次自然发生时记录。适配器目前按 `rate_limit_event` 的 `status` 为 `rejected` 识别，这个取值来自文档，没有实测。Codex 被拒的形式暂不处理。
```

然后汇报（节选）：

助手：[2026-10-09 13:56 UTC]
今天的结论已写进 notes，旧 issue 已关，M2 的第一部分（Claude 适配器的参数和解析）也已提交推送。（……省略……）

**M2 第一部分：Claude 适配器（`89084c5`）**

用 haiku 跑了三次很小的真实 turn，录下输出（会消耗少量 Claude 额度）。实测和 notes 的出入：
（……省略……）

解析器用真实输出做测试样本，解析时没有出现不认识的事件。

**还没验证的两点**：Claude 额度被拒时的事件格式，和权限模式不被允许时的报错文字，目前都还不知道。前者先按文档里的取值识别，后者暂时按普通失败处理。两项都已记进 harness-adapter §6。

（……省略：M2 接下来的三部分……）

我接着做第 1 部分。

用户的重述：

用户：[2026-10-09 14:02 UTC]
额度被拒之前有出现过，当时查过，你没记下来吗

助手在 notes 里搜索，读到了 data-model §8.3 当时的内容（节选）：

```text
**8.3 被拒绝时**

- 被拒的 turn 记为 failed（额度）。该额度域进入"受阻"：域内所有 role 都不再启动新 turn，运行时不按 role 各自重试。
（……省略……）

实测记录（Claude Code 2.1.283，交互式 CLI，2026-10-01，一次）。被拒时，会话文件中写入一条合成的 assistant 消息：

- `isApiErrorMessage: true`、`error: "rate_limit"`、`apiErrorStatus: 429`；
- `quotaLimits` 中有 `status: "rejected"`、`rateLimitType: "five_hour"` 和 `resetsAt`（Unix 秒）；
- 显示文本为 "You've hit your session limit · resets 12:20am (Asia/Tokyo)"；
- 用户的输入在报错之前已写入会话文件。

`-p` 的 stream-json 模式下被拒的形式尚未确认，预期是 `status` 为 `rejected` 的 `rate_limit_event`，字段与上面的 `quotaLimits` 相同。Codex 被拒时的形式未知，暂不处理。
```

又在本机会话文件里找到 10-01 那次的原始记录，核对后修了解析器，然后回复（节选）：

助手：[2026-10-09 14:08 UTC]
有记录，在 data-model §8.3：2026-10-01 在交互式 CLI 里实测过一次。我写适配器时只查了 harness-adapter，没有去搜整个 notes，结果在 harness-adapter 里写成了「还没有记录到」「取值来自文档」，这是错的。原始会话文件还在，我对过一遍，字段和 §8.3 写的一致。

这也说明第一版解析器只认 `rate_limit_event` 不够。那次实际出现的是一条 Claude Code 自己合成的消息，顶层带 `error: "rate_limit"` 和 `apiErrorStatus: 429`。

已修正（`b579052`），CI 正在跑：
- **解析器**：下面三种信号任意一种出现，就记为额度被拒：
  - `rate_limit_event` 的 `status` 为 `rejected`；
  - assistant 消息顶层的 `error` 为 `rate_limit`；
  - `result` 的 `api_error_status` 为 429。
（……省略……）
- **notes**：harness-adapter 改为指向 data-model §8.3；data-model §8.3 写明了适配器认哪三种信号。`-p` 模式下被拒时的格式确实还没见过，这一点保留为待核对。
- **记忆**：以后要在 notes 里写「未记录」「未实测」之前，先搜一遍整个 notes，必要时再查会话文件。

收场：助手接着做 M2 第二部分。memory 里新增"Search notes before claiming unknown"一条。

**用户真正想要的**：额度被拒以前真实出现过，也查过并记了下来（data-model §8.3）。接 Claude 适配器时应当复用这份记录，按当时实测到的字段识别额度被拒，而不是写成"还不知道""取值来自文档"。

## 选这个点的理由
用户同意了"先做 Claude 适配器"，助手刚说过事件格式等"都已实测过，风险小"。好的 Manager 在开工或给执行者写任务说明时，会把项目里已有的相关记录带上：harness-adapter §1.3 第 5 条说额度被拒"见 data-model.md §8"，§6 写着"Claude 额度被拒的情况已有一次记录"并标出 §8.3。只要顺着这两个指向去读，就能得到那次实测的字段，任务说明里也就能写明"按 §8.3 的实测格式识别额度被拒，`-p` 模式下的形式另行核对"。诱人的错误读法是只看正在改的文件和刚录到的样本：样本里没有被拒的情况，就把它当成"项目里还不知道"，再按官方文档补一个取值并标为"未实测"。这样不只漏用了已有记录，还把一条已核实的事实降级成了待验证项。对 Angela 来说，这对应她向下派活或向上汇报"未知"之前，先查一遍项目已有的记录。
