<!-- 17693 ms -->
Current goal:
我理解为：收敛本地 GUI 产品的接入架构，同时支持 Claude Code、Codex，并保留订阅绑定入口；下一步比较 ACP、自建 adapter 等方案。

Likely current state:
仍在设计阶段，尚无代码。用户刚纠正了“首版单 harness”等范围建议；抽象方式、SDK 或 CLI 接入尚未确定。

Evidence:
用户明确说：“多harness也是要求”“各类订阅会绑定专用入口”“所有的role应该做成可替换的”“暂时作为本地常驻进程”。首个用途是管理 Lobotomy 自身开发。

Alternative interpretation:
订阅入口是接入约束，不一定意味着只能调用 CLI；若 SDK 能合法保留相同订阅入口，也可能符合意图。

What would be dangerous to assume:
把 SDK 等同于 API key、把需要抽象等同于选定 ACP，或继续把 Codex 排除在首版之外；也不能把讨论设计当作开始实现的授权。

Next interaction strategy:
先简短承接修正，再给出“GUI → 统一角色运行接口 → 两种 harness adapter”的小草案。推荐先核实两家的订阅接入和会话控制能力，再据此比较 ACP 与自建接口；不重复追问已回答的问题。
