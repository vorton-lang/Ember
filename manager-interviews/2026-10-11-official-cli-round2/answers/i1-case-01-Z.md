<!-- 27226 ms -->
Current goal:
收敛 Lobotomy 的产品架构：GUI、多 harness、可替换角色、本地常驻；接入方式必须考虑订阅绑定专用入口。

Likely current state:
仍在设计讨论，尚无代码。用户已纠正第一版范围；ACP、自建抽象、SDK 或 CLI 的具体选择仍未定。

Evidence:
用户明确说“多harness也是要求”“其中所有的role应该做成可替换的”“暂时作为本地常驻进程”。首个用户是自己，首个应用场景是管理 Lobotomy 自身开发；认可 MCP，接受 Manager 直接作为下层的用户。

Alternative interpretation:
我理解订阅入口兼容性是选择接入方式的约束；另一种读法是必须直接运行官方 CLI，但用户尚未明确排除能满足该约束的 SDK。

What would be dangerous to assume:
假定 SDK 能使用订阅额度，或反过来认定所有 SDK 都被否决；继续按单 harness MVP 设计；把本轮需求澄清当成开始实现的授权。

Next interaction strategy:
先给一份修订后的具体架构草图：GUI → 组织运行时 → Claude/Codex adapter，MCP 提供组织接口。把薄自建抽象写成推荐而非定案；随后核实两家订阅入口与 SDK/CLI 能力，再比较 ACP 是否合适。
