---
name: v3 Godot port
description: 2026-04-19 pivot from MonoGame to Godot 4 + C# with Unity API Shim approach for faster feature parity
type: project
originSessionId: 33f20642-9caf-49b1-8a92-3476277cfcf3
---
BetterArc v2 (MonoGame) 被放弃，原因：进度太慢、代码是 AI 重写非复制导致 bug、假测试无效力。

v3 改为 Godot 4 + C# 移植，核心方法：
- ArcCreate C# 文件原样复制到 Godot 项目
- Unity API Shim 层让代码零修改编译
- Shim 内部代理到 Godot API
- Bug 面从"整个代码库"缩小到 Shim 层

**Why:** 用户需要尽快获得 feature-complete build 用于替换素材和微调手感实验，不想继续在渲染对齐上浪费时间。用户有 Godot 开发经验。

**How to apply:** 所有后续开发围绕 docs/superpowers/plans/2026-04-19-godot-port.md 实施计划进行。严格遵守机械复制纪律。
