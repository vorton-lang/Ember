---
name: ArcCreate 是唯一参考源
description: 项目 v2 重写：ArcCreate C# 源码是唯一实现基准，不再参考 Arcaea 本体 RE
type: feedback
originSessionId: 0b31e462-e596-4aab-9278-90c23fed8e6d
---
2026-04-19 项目重写决策：从 Rust+wgpu 转为 C#+MonoGame，ArcCreate 是唯一参考源。

**规则：** ArcCreate 源码是实现的唯一基准。翻译方式为复制 C# + 去 Unity 依赖。不再参考 Arcaea RE。

**Why:** v1 双源参考（RE + ArcCreate）导致实现混乱；C#→Rust 翻译引入大量视觉 bug 且 agent 无法自验证；人工迭代超过 3 次不可忍受。

**How to apply:**
- 所有实现参考 `re/ArcCreate/` 中的 C# 源码
- 逻辑层直接复制，仅改 using 和去 Unity 依赖
- 渲染层将 Unity Mesh/Material/Shader 替换为 MonoGame VertexBuffer/Effect/HLSL
- 验证通过 `dotnet test` 同语言比对，不依赖人眼
