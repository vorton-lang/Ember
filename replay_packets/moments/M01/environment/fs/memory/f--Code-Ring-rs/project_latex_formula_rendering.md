---
name: LaTeX/数学公式渲染方案调研
description: 对话文本中嵌入数学公式的技术方案选型结论（Typst + MiTeX 双语法），暂未实施
type: project
originSessionId: 435288da-eb12-4437-a214-06812be28c10
---
## 决策：Typst 原生 + MiTeX 双语法

2026-05-12 调研结论，暂列 backlog，等需要富文本支持时统一推进。

**选定方案**：Typst 原生渲染（纯 Rust → SVG）+ MiTeX（185KB，LaTeX→Typst 自动转换），同时支持 Typst 和 LaTeX 两种公式语法。

**Why:** 覆盖更多用户群（LaTeX 用户 + Typst 用户）；纯 Rust 管线与打字机效果天然兼容（同步渲染，无 JS eval 异步闪烁）；不在乎包体积。

**How to apply:**
- 渲染管线：脚本 `$...$` → Parser 提取公式 → MiTeX 转换（若 LaTeX）→ typst compile → typst-svg 导出 → inline SVG 嵌入 WebView
- 核心依赖：`typst` + `typst-svg` + `typst-kit`（字体）+ MiTeX（LaTeX→Typst）
- 需实现 `World` trait（7 方法，`typst-as-lib` 可简化）；字体管理用 `typst-kit`
- 前置条件：需先建立富文本渲染管线（当前对话文本是纯文本直出）
- 备选：若 Typst 集成过重，KaTeX（JS）是最简路径但有异步闪烁问题
