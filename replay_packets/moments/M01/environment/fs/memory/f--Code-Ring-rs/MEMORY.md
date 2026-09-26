# Ring-rs 项目记忆

> **新机器设置**：clone 后运行一次 junction 命令（需管理员或开发者模式）：
> ```
> mklink /J "%USERPROFILE%\.claude\projects\<escaped-repo-path>\memory" "<repo>\.claude\memory"
> ```
> `<escaped-repo-path>` 是仓库绝对路径中 `\` 和 `:` 替换为 `-` 的形式。

## 项目概述
视觉小说引擎（Rust）。主要 crate：`vn-runtime`（纯逻辑）、`ring-player`（宿主，Dioxus 0.7 Desktop）、`ring-render`（共享渲染）、`ring-resources`（资源管理）、`ring-audio`（音频）。
脚本格式 `.rks`（Ring Script），支持变量/条件分支。默认 `cargo run` 执行 `ring-player`。

## 关键约束
- Runtime 与 Host 通过 `Command` / `RuntimeInput` 通信，禁止其他耦合
- Runtime 禁止 IO/渲染/真实时间；Host 禁止脚本逻辑
- 所有状态可序列化（存档支持）
- 禁止顺便重构无关代码
- **0.x 不维护向后兼容**——破坏性变更直接改，发起者全量修调用方

## 仓库导航（快速定位）

### 文档入口
- 导航地图：`docs/engine/architecture/navigation-map.md`
- 架构约束：`ARCH.md`
- 脚本语法：`docs/authoring/script-syntax.md`
- RFC 索引：`RFCs/README.md`
- 工作流指南：`docs/workflows/`（Command 管线、语法扩展、RFC 流程、领域分区）
- 经验沉淀：`docs/maintenance/lessons-learned.md`
- 符号索引：`docs/engine/symbol-index.md`

### 领域不变量
详细 Do/Don't 规则见 `.claude/rules/domain-*.md`，CLAUDE.md 中有速查引用表。

### 不要读/改的目录
`target/`、`dist/`、`saves/`、根目录 `*.zip`

## 常用命令
```
cargo check-all          # 一键门禁（fmt/clippy/test）
cargo test -p vn-runtime --lib
cargo script-check       # 脚本语法检查
cargo cov                # 覆盖率报告
cargo gen-symbols        # 符号索引刷新
cargo mutants            # 变异测试
```

## 开发环境
- 主力 AI 工具：Claude Code（Opus 1M context）
- 备用 AI 工具：Cursor（.cursor/ 文件保留）
- CC hooks：PreToolUse 在 git commit 前自动运行 cargo check-all
- CC settings：`.claude/settings.json`（hooks）+ `.claude/settings.local.json`（permissions）
- Dioxus 知识参考：`.claude/rules/dioxus-desktop.md`（0.5-0.7.3 Desktop 相关）

## 脚本语法要点（RFC-039 新格式）
- 文件扩展名：`.rks`（Ring Script）
- 对话：`角色名："内容"` / 旁白：`："内容"`
- 演出：`changeBG "path"`（简单背景）/ `changeScene "path" with X`（复合场景，必须带 with）
- 立绘：`show "path" as alias at position with transition` / `hide alias`
- Rule 过渡：`with rule("mask.png", duration: N, reversed: bool)`
- 分支：Markdown 表格；跳转：`goto label`；跨文件：`callScript "path.rks"`
- 标签：`* label_name`（单星号+空格）
- 变量：`set $var = value`；条件：`if/elseif/else/endif`
- 节奏：`wait N`（秒）/ `wait N nobreak`（不可打断）；对话：`notend`（阻止 Auto 推进）
- 音乐：`bgm "path"`（循环）/ `sfx "path"`（单次）
- 注释：`// 说明文字`（以 `//` 开头）

## 记忆文件索引
- [Harness 变更记录](feedback_harness_2026_04.md) — 2026-04 harness 迭代决策记录
- [DeepSeek V4 集成与评测](reference_deepseek_integration.md) — 能力矩阵 + 反幻觉 prompt 发现 + 调用规范。详细规范：`docs/workflows/deepseek-subagent-spec.md`
- [ring-lsp 后续规划](project_lsp_next_steps.md) — 资源路径重设计 + LSP/插件功能完善清单
- [数学公式渲染方案](project_latex_formula_rendering.md) — Typst+MiTeX 双语法，backlog 待富文本管线就绪
- [0.x 不维护向后兼容](feedback_no_backward_compat.md) — 破坏性变更直接改，不加兼容层
- [WebGAL issue 扫描](reference_webgal_issues.md) — 每月扫描 WebGAL/WebGAL_Terre issue 获取需求灵感
