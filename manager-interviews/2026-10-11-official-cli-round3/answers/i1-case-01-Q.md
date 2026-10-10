<!-- 34580 ms -->
Current goal:
在 GUI、多 harness、订阅绑定入口的约束下，讨论 Lobotomy 的接入抽象和第一版设计。

Likely current state:
用户正在纠正助手的范围判断，并补齐产品边界；看起来希望据此继续设计，尚未要求开始实现。

Evidence:
用户明确说“多harness也是要求”“接入harness主要是因为有各类订阅会绑定专用入口”；同时说明所有 role 应可替换，“暂时作为本地常驻进程”。

Alternative interpretation:
要求兼容订阅专用入口，不一定意味着只能直接调用 CLI；若 SDK 能通过受支持的方式满足这一要求，也可能适用。

What would be dangerous to assume:
假定 SDK 能使用订阅额度，或反过来认定 SDK 必然不可用；把 ACP、直接 CLI 当成已定方案；继续把 Codex 推迟到后续版本。

Next interaction strategy:
先简短确认修正，再围绕 Claude Code 与 Codex 的实际订阅接入能力，提出有依据的 adapter 建议。保留抽象方案的选择空间，不重问已回答的问题，不进入实现。
