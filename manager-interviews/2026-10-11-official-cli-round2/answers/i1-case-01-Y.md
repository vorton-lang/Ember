<!-- 22862 ms -->
**Current goal:**
用户想先把 Lobotomy 的架构基线定下来，再开始写代码。约束有这几条：GUI；至少要接 Claude Code 和 Codex 两个 harness，所以必须有一层抽象；角色都可以替换；第一版是本地常驻进程；第一个项目就是 Lobotomy 自己。当前要决定的是 harness adapter 怎么做：用 ACP、自己写，还是别的方案。

**Likely current state:**
用户回答了执行者提的几个问题，也纠正了几处前提。我理解为，用户认为接 harness 的根本原因是"各类订阅会绑定专用入口，我们不能假设所有的服务都可以通过api提供"。照这个理解，adapter 应该去驱动用户本机已登录的官方 CLI，而不是走 API key。执行者之前提的 Agent SDK 路线能不能用，取决于 SDK 是否沿用 CLI 的订阅登录，以及使用条款是否允许，这一点现在还没定。用户没有回应第 4 点（Manager 过滤信息和 HCI 原则的冲突），也没有回应 Ember 许可证的死链。

**Evidence:**
- 用户原话："接入harness主要是因为有各类订阅会绑定专用入口"。
- 用户原话："多harness也是要求，因为至少还有codex要接进来……只是选择ACP还是自己写或者别的"。
- 用户原话："manager声明自己是manager即可……manager就是它们的用户，不需要刻意绕过"。
- 用户原话："所有的role应该做成可替换的"；"暂时作为本地常驻进程"。
- 用户把执行者问的"Claude Code 接入为什么是硬性要求"答成了"GUI是硬性要求"。我推测这是用户在顺带纠正哪些才是硬约束，不是答非所问。

**Alternative interpretation:**
用户也许并不排斥 SDK，只要求它走订阅登录。如果 Agent SDK 能直接复用 CLI 的登录态，条款也允许，那么 Claude 这一侧用 SDK 也行，adapter 层的分歧就缩小到 Codex 怎么接。我对"必须走官方 CLI"这个读法把握中等。

**What would be dangerous to assume:**
- 假设 Agent SDK 在第三方产品里可以用订阅额度。条款没核实。
- 把"manager 就是它们的用户"理解成连消息来源标注都不要了。用户只是说不必刻意绕开"用户发言"这个通道，没说要去掉 provenance。
- 用户没回应，就当作接受了第 4 点的三条设计。
- 角色可替换，就直接选 ACP。用户明确说 ACP 还是开放选项。
- 只按 Claude Code 去设计抽象，不去查 Codex 实际提供哪些非交互接口（exec、app-server、mcp-server 等）。

**Next interaction strategy:**
不再追问已经回答过的问题，直接给出一个具体提议：
1. 定义 Lobotomy 自己的一层薄 harness 接口，参照 ACP 的语义，第一版不依赖 ACP。
2. 每个 adapter 以子进程方式驱动用户本机已登录的官方 CLI，Claude 和 Codex 各一个。
3. 附上一张两边能力对照表，Codex 的接口先实际查一遍再写进表里。
4. MCP 组织 server 作为两个 harness 共用的接口层。Manager 发给下层的消息直接以 manager 的身份发出，只保留一个来源字段。

提议中用一句话写出另一种读法："如果你接受 Claude 侧走 SDK（前提是能复用订阅登录），Claude adapter 可以更薄。"第 4 点的冲突不再展开，只作为默认设计带上，让用户自己选择是否推翻。本轮最多问一个问题。现在是 JST 下午，可以正常推进。
