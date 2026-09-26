---
name: harness-iteration-2026-04
description: 2026-04 harness 迭代：移除摘要体系、加强决策确认、集成 Dioxus 知识
type: feedback
originSessionId: 34873f37-f362-4c8f-80ac-d5d6c5474be0
---
## 摘要体系已移除（2026-04-13）

1M 上下文时代，module-summary 体系（30+ 摘要文件 + 维护协议 + 抽样清单）已全部移除。
- 不再有"摘要优先、源码兜底"约束
- 不再有 500 行局部读取、不读测试正文等源码读取限制
- .cursor/rules 和 .claude/rules 中的"摘要导航"段落已清除

**Why:** 摘要维护成本远大于收益，且经常过期误导。直接读源码在 1M 上下文下无压力。

**How to apply:** 直接读源码，不需要先找摘要。不需要维护任何 summary 文件。

## 决策确认约束加强（2026-04-13）

用户反馈：模型倾向自行判断而非询问。CLAUDE.md 中"决策确认"段落已扩展为具体场景清单。

**Why:** 用户希望对设计决策有掌控力，不希望模型替他做选择后再返工。

**How to apply:** 默认姿态是"有选择时先问"。必须确认的场景包括：≥2 方案、跨模块、公共 API 变更、行为变更、范围超预期等。单模块内单一方案的实现不需要确认。

## Dioxus 知识集成（2026-04-13）

从外部 dioxus-knowledge-patch 提取 Desktop 相关部分，存入 `.claude/rules/dioxus-desktop.md`。
覆盖：Signals、Hooks、RSX 模式、Desktop 配置、CLI、热重载、Reactivity 注意事项。
裁剪掉：Fullstack、SSR、SSG、WASM split 等 Web 端内容。

**Why:** ring-player 是 Desktop 应用，只需要 Desktop 相关知识。

**How to apply:** 编写 ring-player 代码时参考 `.claude/rules/dioxus-desktop.md`。
