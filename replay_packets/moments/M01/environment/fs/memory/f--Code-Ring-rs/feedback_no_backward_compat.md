---
name: 0.x 阶段不维护向后兼容
description: 项目无外部客户，破坏性变更直接改、全量修，不要加兼容层
type: feedback
originSessionId: 435288da-eb12-4437-a214-06812be28c10
---
0.x 阶段不维护向后兼容性，采用类 Linux kernel 内部 API 政策。

**Why:** 项目无外部客户，兼容层是为幻想的遗留用户浪费精力。破坏性变更的发起者负责同步升级所有调用方。

**How to apply:** 不要自动添加 `#[serde(default)]`、版本迁移逻辑、fallback 路径等兼容性代码。结构需要改就直接改，同步修所有测试和存档文件。设计方案时不要把"向后兼容"作为权衡因素。
