# Prompt candidates

这些候选用于固定模型、工具和回放上下文，只改变行为指令。默认 `minimal.md` 保留原样。它们不声称恢复了任何产品完整的实际 system prompt。

## 固定来源

| 候选 | 上游 | 固定 commit |
|---|---|---|
| `cc-2.1.142` | [Piebald v2.1.142](https://github.com/Piebald-AI/claude-code-system-prompts/tree/v2.1.142) | `d325d10da473ad294ccec97ff15bda8053c9bde0` |
| `cc-2.1.162` | [Piebald v2.1.162](https://github.com/Piebald-AI/claude-code-system-prompts/tree/v2.1.162) | `4cd566a1ec0403e01055d3d400092b087a076697` |
| `cc-2.1.172` | [Piebald v2.1.172](https://github.com/Piebald-AI/claude-code-system-prompts/tree/v2.1.172) | `94e0b89bb6e7eedc34e871e18d862af6385f4c32` |
| `codex-5.3` | [OpenAI models.json](https://github.com/openai/codex/blob/dfd03ea01bbec2613013b477fb82abc67534a7d7/codex-rs/models-manager/models.json) | `dfd03ea01bbec2613013b477fb82abc67534a7d7` |

Codex 取 `models[slug="gpt-5.3-codex"].base_instructions` 的完整字符串作为原文。该名称不限制调用的模型，也不代表换成 GPT。未叠加 personality template 或产品 developer 指令。

原文与许可证保存在 `sources/`。Claude Code 原文包含归档注释；Codex 原文是 JSON 解码后的字符串，不额外添加换行。SHA-256 按 UTF-8、LF 计算，允许 Windows checkout 的 CRLF 转换。

## 拼装选择

Claude Code 不是单条静态 prompt。这里选择主代理的工程任务解释、代码质量、行动安全和沟通指令；顺序明确保存在 `manifest.json`。这是可审计的实验选择，不能用归档中存在某片段证明当时产品一定启用了它。

| 版本 | 沟通段 | 探索性问题指令 |
|---|---|---|
| 2.1.142 | `communication-style`，含一两句结束总结 | 无该独立片段 |
| 2.1.162 | `communication-style` | 保留 2–3 句话给建议和权衡、等用户同意再实现 |
| 2.1.172 | `outcome-first-communication-style`，优先可读性 | 同样保留 |

2.1.172 不叠加旧沟通段。所有 CC 候选选择短版 `action-safety-and-truthful-reporting`，不叠加长版 `executing-actions-with-care`。独立 `concise-output-short` 因触发条件未知而排除；所选片段内部的简短要求不删改。晚期出现的范围控制、注释及 emoji 等主代理片段按版本纳入。

不纳入子代理、worker/coordinator、plan/auto 模式、记忆后台任务、浏览器/平台集成、辅助功能提示及原生工具说明。TodoWrite/Agent 的指导也排除，因为回放工具中没有对应能力。没有加入 Superpowers 强制调用规则。

## 适配边界

`manifest.json` 中每个 part 都保存原文路径、哈希、来源 URL、准确的 before/after 和修改理由。构建器只做这些替换及归档头移除，不摘要或改写其余行为正文。

- 使用相同的中性助手身份，避免让 Claude 自称 GPT-5，或给出错误的原产品身份。
- 搜索/读取映射到 `Grep`、`Glob`、`Read`；并行调用映射到多个 `tool_use` block；Codex commentary/final 映射到工具间文本/回合结束文本。
- 去除原生 shell/edit 调用方式、共享本机文件的错误断言、未实现的 hooks/权限语义及可点击链接保证。
- CC 的未恢复 identity/security-note 占位符不猜填；已有安全段保留。审批持久化条件取 false；新版沟通条件取展示工具间文本的 terminal 分支。
- 每个新增候选附加相同的 `runtime-adapter.md`，明确只有五个工具、环境只读、不能运行 shell/测试/子代理。其他编辑、执行及验证倾向仍作为行为指令保留，受这个实际能力边界约束。

默认 minimal 没加新版 adapter，以保持已有基线逐字不变。因此 minimal 与新增候选之间还存在运行说明详细程度差异；新增候选彼此使用完全相同的 adapter。不要把 minimal 对比直接解释成单句提示词的因果效应。

## 复现和检查

```powershell
python tools/harness_profiles.py --check
python tools/harness_profiles.py --write
python tools/replay.py --list-harnesses
python tools/replay.py --moment M03 --model anthropic/claude-opus-4.8 --provider anthropic --effort high --harness cc-2.1.172 --dry-run
```

`--check` 验证原文哈希和构建结果；`--write` 从本地固定来源重建，无需联网。每次命名候选运行也会检查一致性。需要任意改 prompt 时使用 `--system-prompt-file`，与 `--harness` 互斥，日志标为 custom。

`run.json.harness_provenance` 保存本次使用的完整适配记录；`harness_sha256`、`system_sha256` 和 `initial_request_sha256` 标识实际条件。该记录、来源标签、commit 和片段标题不进入模型 system。模型只能访问冻结环境，不能通过 Read/Glob/Grep 读取本仓库的候选原文、manifest、评语或 runs。

离线测试检查实际 `initial_request.json`：相同 M03 条件下，除 system 和独立 session ID 外，请求完全相同；版本、研究假说、评分轴和后续历史不注入提示词。它不证明历史环境自身绝无污染，也不覆盖模型主动加载 skill 后出现的指令。线上服务端接收和模型行为仍需实测。

## Attribution

Claude Code excerpts are from Piebald-AI/claude-code-system-prompts (MIT; see each source directory's LICENSE). Codex excerpts are from OpenAI Codex (Apache-2.0; see sources/codex/LICENSE and NOTICE). Generated profiles are modified by EMBER; all modifications are enumerated in manifest.json.
