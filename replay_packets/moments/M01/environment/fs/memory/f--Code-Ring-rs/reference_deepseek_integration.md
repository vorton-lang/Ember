---
name: DeepSeek V4 API integration
description: DeepSeek V4 Pro 能力评测与调用规范，通过 .claude/ds-claude.ps1 隔离调用，含 prompt 工程最佳实践
type: reference
originSessionId: 6c2f98d8-ff9e-4e2f-8b76-94017c7edb1e
---
## 接入方式

- Anthropic 兼容接口：`https://api.deepseek.com/anthropic`
- API key：环境变量 `DEEPSEEK_API_KEY`
- 调用入口：`.claude/ds-claude.ps1`，子进程隔离 env vars，主会话保持纯 Anthropic 连接
- 模型：`deepseek-v4-pro[1m]`（主力）/ `deepseek-v4-flash[1m]`（轻量/子代理）
- 技术规范文档：`docs/workflows/deepseek-subagent-spec.md`

## 能力矩阵（2026-05-11 系统性评测更新）

| 任务类型 | 评分 | 关键条件 |
|----------|------|----------|
| 网络搜索整理 | ★★★★★ | `-WebOnly` 模式 |
| 文档/信息聚合 | ★★★★★ | `-ReadOnly` 模式 |
| 代码骨架生成 | ★★★★☆ | 需明确 spec |
| 代码精确阅读 | ★★★★☆ | **必须**加反幻觉 prompt（不加则 ★★☆☆☆） |
| 跨文件分析推理 | ★★★★☆ | 行号精确度 ±2 行 |
| 代码写入（小任务） | ★★★★☆ | 能识别项目测试模式 |
| 指令遵循 | ★★★★☆ | 否定指令遵循略弱 |

### 决定性发现：反幻觉 prompt

加入 "不要猜测，只报告你看到的" 后，代码阅读准确率从 13% → 96%（7x 提升）。
此指令为代码阅读类任务的**硬性要求**。

## 推荐用法

| 场景 | 模式 | prompt 要求 |
|------|------|------------|
| 查外部 API 文档 | `-WebOnly` | 松散描述即可 |
| 读项目代码做分析 | `-ReadOnly` + 反幻觉指令 | 精确指令 |
| 代码骨架生成 | `-ReadOnly`（从 permission_denials 提取） | 明确 spec |
| 小范围代码修改 | `-AllowedTools "Read,Grep,Glob,Edit"` | 分步指令 |
| 大范围修改 | 全能 + Opus 事后审查 | 分步指令 |

## 成本参考

简单任务 $0.20-0.28，跨文件分析 $0.30-0.76，深度 web 搜索 $1.00-1.50。

## 已知问题

1. 多行 here-string prompt 可能触发 API 参数解析错误 → 用单行双引号
2. PSReadLineOption/stdin 警告 → 不影响功能
3. DS 在受限模式下仍会尝试越权工具 → 被拒后回退，浪费 1-2 turn
