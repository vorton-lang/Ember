# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 仓库用途

这是 Yufeng Ying（应宇峰）的**个人上下文仓库**。核心目标：持续维护一份精炼的个人 profile，使任何 agent 只需将 profile 插入上下文，即可以 **80% 召回率、100% 准确率**获取用户的个人信息。

**profile 原则：**
- **准确** — 所有事实可溯源，不含推测或过时信息
- **实时** — 随对话和项目变化持续更新
- **精炼** — 只描述 WHAT（事实），不解释 WHY（动机/原因）；agent 若需要 WHY，应来本仓库查阅原始材料

**仓库职责：**
- **输出 profile**：`profile.md` 是面向所有 agent 的标准化个人信息输出，设计为可直接注入上下文
- **存储原始材料**：项目经历、财务规划、技术文档等深度上下文，供需要 WHY 的 agent 按需查阅
- **通过 skill 分发**：`personal-context` skill 注册到 `~/.claude/skills/` 后，任何项目的 agent 均可自动发现并读取本仓库（见 `register-skill.ps1`）
- **自动同步**所有 Claude Code 项目的 memory 和对话历史，作为 profile 更新的数据源
- **Git 管理**：clone 到新机器后运行 `register-skill.ps1` 即可恢复全部上下文

## Agent 在本仓库的首要职责

维护本仓库的**健康度和新鲜度**是 agent 在本仓库会话中的首要职责，该职责自动进行，用户仅作审核：

- **主动提出更新**：发现 profile 中有过时、缺失或不够精炼的信息时，主动提议修改并说明理由
- **积极维护 profile**：每次会话应检查 profile.md 的时效性，结合最新同步的 memory/session 数据识别需要更新的内容
- **处理 inbox**：SessionStart 时若有 `PROFILE_INBOX`，立即合并到 profile.md
- **清理过时数据**：同步机制会自动删除源头已删除的文件副本，agent 也应清理仓库中明显过时的内容

## 内容结构

### profile.md
面向 agent 的标准化个人信息输出。设计为可直接注入任意 agent 上下文，精炼描述用户的事实信息（WHAT），不含动机解释（WHY）。这是本仓库的核心产出物。

### financial/
个人投资分析与 FIRE（财务自由提前退休）规划，面向中国市场。

- **回测脚本** (`backtest_*.py`): 哈利·布朗永久投资组合的中国本土化回测，使用沪深300、国际金价、国债、货币基金作为四类资产
- **FIRE 测算** (`fire_*.py`): 基于杭州生活成本的退休规划模拟
- **基金筛选** (`pick_*.py`, `qdii_compare.py`): 从支付宝可购买的场外基金中筛选最优标的，包括 QDII 基金比较
- **数据依赖**: akshare、yfinance、pandas、numpy、matplotlib
- 所有脚本独立运行，无共享模块，图表输出到 `financial/output/`

### VDB/
GPU 加速 VDB（稀疏体积数据结构）的技术文档，来自实习项目 DeepFusionPoints。

- `VDB.md`: GPU-VDB 方案概述与相关工作对比
- `备忘录_DeepFusionPoints系统回顾与改进.md`: 系统设计回顾与改进方向
- `交接文档/`: 完整技术设计文档、已知缺陷、CUDA 调试与性能优化指南

### memory/
所有 Claude Code 项目的 memory 快照，按项目名隔离子目录。由 `session-init.ps1` 在本项目 SessionStart 时自动同步。

### sessions/
所有 Claude Code 项目的对话历史（JSONL），按项目名隔离子目录。同样由 `session-init.ps1` 自动同步。

## 运行金融脚本

```bash
pip install akshare yfinance pandas numpy matplotlib
python financial/<script_name>.py
```

脚本使用 `matplotlib.use('Agg')` 和中文字体配置（SimHei/Microsoft YaHei），输出 PNG 到 `financial/output/`，无需 GUI 环境。

## 自动同步机制

`session-init.ps1` 在本项目开启 Claude Code 会话时通过 SessionStart hook 自动运行（配置在 `.claude/settings.json`）：

1. 将 `~/.claude/projects/` 下所有项目的 memory 和 session JSONL 同步到仓库
2. **删除检测**：源头已删除的文件/项目目录会从仓库副本中同步删除
3. 检查 `profile-inbox.md` 是否有待处理的画像更新

## 用户画像更新

### 本仓库内
对话中识别到用户新的个人信息时，直接编辑 `profile.md`，无需走 inbox。

### 收件箱处理
当 SessionStart hook 输出包含 `PROFILE_INBOX` 时：
1. 读取 `profile-inbox.md`
2. 逐条合并进 `profile.md` 对应段落（更新已有条目或新增）
3. 删除 `profile-inbox.md`

### 其他项目
由 `personal-context` skill 指导其他项目的 agent 识别重大个人信息变化并写入 inbox，详见 skill 中的 Profile Update Protocol。

## 使用注意

- `profile.md` 是本仓库的核心产出物——维护它的准确性、时效性和精炼度是首要任务
- profile 只写事实（WHAT），不写原因（WHY）。深度上下文保留在仓库的原始材料中
- 金融脚本中的参数（年龄、城市、收益率假设等）反映用户的真实规划场景
- VDB 文档中文-英文混合书写，技术术语保持英文原文
- 仓库内容会持续扩充，新的个人上下文材料会以类似的目录结构加入
