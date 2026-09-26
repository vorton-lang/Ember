# Context

个人上下文仓库。持续维护精炼的个人 profile，使任何 agent 只需将 profile 插入上下文即可获取我的个人信息。

## 核心产出

[`profile.md`](profile.md) — 面向 agent 的标准化个人信息，设计为可直接注入上下文。只写事实（WHAT），不写原因（WHY）。

## 结构

- `profile.md` — 个人 profile（核心产出物）
- `financial/` — 投资分析与 FIRE 规划脚本
- `VDB/` — GPU-VDB 技术文档（实习项目）
- `memory/` — 各项目 Claude Code memory 快照（自动同步）
- `sessions/` — 各项目对话历史 JSONL（自动同步）

## 自动同步

每次在本仓库开启 Claude Code 会话时，`session-init.ps1` 通过 SessionStart hook 自动同步所有项目的 memory 和对话历史，并检测已删除文件。

## 跨项目分发

运行 `register-skill.ps1` 将 `personal-context` skill 注册到 `~/.claude/skills/`，使其他项目的 agent 可自动发现并读取本仓库。
