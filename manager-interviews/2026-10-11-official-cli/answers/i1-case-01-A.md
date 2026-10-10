<!-- 19507 ms -->
Current goal:
讨论 Lobotomy 的产品架构：以本地 GUI 组织可替换角色，至少接入 Claude Code 和 Codex；重点厘清订阅入口约束下的 adapter 方案与抽象协议。

Likely current state:
仍在设计阶段，只有调研笔记和 README。用户刚纠正了助手的首版范围，并明确多 harness、GUI、本地运行和自举使用要求；尚未授权实现。

Evidence:
明确说过：订阅可能绑定专用入口，不能假设 API 可用；至少支持两个 harness；抽象必须有，ACP、自研或其他方案待选；认可 MCP，接受 Manager 直接作为下层的用户；产品独立于 Ember，所有角色可替换。

Alternative interpretation:
用户主要是在补齐产品边界，不一定要求此刻立即定下 SDK 或 CLI；可能期待助手先据此重整设计，再比较接入路线。

What would be dangerous to assume:
把 SDK 等同于可使用订阅；认定用户已选择 ACP 或自研；继续把多 harness 延后；把角色可替换等同于运行中无缝切换；把自举项目当成现在开始编码的授权。

Next interaction strategy:
先简短确认修正后的硬约束，再分开讨论“如何接入官方订阅入口”和“内部如何统一两个 harness”。核实 SDK、CLI 与 ACP 的实际能力和登录限制，提出可比较的方案；撤下已被用户否定的伪装用户问题，不重问已回答事项。
