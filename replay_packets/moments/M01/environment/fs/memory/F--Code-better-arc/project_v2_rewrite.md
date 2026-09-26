---
name: v2 重写：C# + MonoGame
description: 2026-04-19 项目从 Rust+wgpu 重写为 C#+MonoGame，核心动机是 agent 自验证能力
type: project
originSessionId: 0b31e462-e596-4aab-9278-90c23fed8e6d
---
2026-04-19 决定删除全部 v1 代码（~8000 行 Rust），从零重写为 C# + MonoGame。

**Why:** v1 的根本问题是 agent 无法自验证渲染正确性——视觉 bug 只能靠人眼发现，人工迭代超过 3 次不可忍受。C# 同语言允许将 ArcCreate 原始代码作为 reference implementation 直接在测试中比对。

**How to apply:**
- 设计文档: `docs/superpowers/specs/2026-04-19-betterarc-v2-rewrite-design.md`
- 技术栈: C# .NET 8+ / MonoGame 3.8 / HLSL / xUnit
- 验证管线: L0 数值 / L1 状态 / L2 截图，全部 `dotnet test` 自动化
- 开发顺序: Phase 1 基础设施 → Phase 2 逻辑层 → Phase 3 渲染 → Phase 4 交互 → Phase 5 Android
