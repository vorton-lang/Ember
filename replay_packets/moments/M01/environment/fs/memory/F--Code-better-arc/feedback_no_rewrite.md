---
name: No rewrite — mechanical copy only
description: CC must never "understand then rewrite" ArcCreate code; must copy verbatim and fix compilation via Shim layer
type: feedback
originSessionId: 33f20642-9caf-49b1-8a92-3476277cfcf3
---
CC 读了 ArcCreate 代码后会"理解"然后"重新实现"，这个过程引入了大量 bug。BetterArc v2 (MonoGame) 的 L0/L1 测试全是 AI 写的假测试，没有效力。

**Why:** 之前的 MonoGame 重写中，尽管计划是"复制 C# 代码替换 Unity API"，实际操作变成了 CC 读代码后自己理解实现一遍，导致大量 bug 且测试无法真正验证。

**How to apply:** 任何从 ArcCreate 迁移代码的工作，必须机械复制源文件，遇到编译错误通过 Shim 层解决，不修改原始逻辑。唯一允许改源文件的情况：[SerializeField] 替换和 #if GODOT 条件编译。每处修改必须标注 `// MODIFIED: reason`。
