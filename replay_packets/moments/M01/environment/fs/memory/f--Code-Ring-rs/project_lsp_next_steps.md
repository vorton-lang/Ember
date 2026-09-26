---
name: ring-lsp 与脚本路径后续规划
description: RFC-041 后续待办：资源路径重设计（去相对路径）、LSP/插件功能完善清单
type: project
originSessionId: 71d26d84-02cb-4cc0-884d-d6c20ec193a5
---
RFC-041 ring-lsp 基础版本已落地。以下为用户确认的后续方向，待设计稳定后补全：

## 资源路径重设计（需新 RFC）

**Why:** 当前脚本中资源路径相对于脚本文件目录（如 `../../backgrounds/black.png`），这是 Typora 时代遗留——为了 Typora 预览和拖拽开发。进入编辑器时代后（ring-studio/VSCode + ring-lsp），素材拖动和预览都由我们控制，理论上可以全面使用 assets-relative 路径（如 `backgrounds/black.png`）。

**How to apply:** 需要分析哪种路径设计更符合人体工学（考虑编剧手写、AI 生成、IDE 补全三种场景），形成独立 RFC。影响 parser、runtime、所有脚本文件、LSP 补全逻辑。

## ring-lsp / VSCode 插件功能完善

以下功能先记录，后续逐步实现：

- 资源路径悬浮预览（hover 时显示图片/音频信息）
- 关键词拼写错误提示（如 `changBG` → 建议 `changeBG`）
- 大小写关键字支持与自动格式化（统一为规范大小写）
- `callScript` 点击跳转到目标脚本文件
- 函数/指令悬浮显示定义文档
- 路径补全更智能（按指令类型过滤文件类型）
