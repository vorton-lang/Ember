# EMBER

**Emergent Master Behavior Elicitation & Recovery**

EMBER 研究一个问题：**现代模型能否通过合适的提示词与协作环境，恢复长期人机协作中的主动判断能力？**

我们关注的不只是模型能否完成当前任务，还包括它能否发现问题的另一种表述、理解局部工作与整体目标的关系、从少量纠偏中调整方向，以及帮助用户推进尚未完全定义的问题。

项目从真实协作中的关键时刻出发，让不同模型在相同的历史起点重新参与讨论，再比较模型、harness 与交互方式如何影响后续走向。

## 研究方向

- **比较模型**：固定上下文和协作环境，观察不同模型如何理解问题、回应纠偏与推进讨论。
- **比较 harness**：固定模型，比较不同提示词与协作规则能否稳定改善这些行为。
- **形成可用成果**：将有效的方法整理为日常可用的 harness / skill，并用实验记录支撑后续研究报告。

EMBER 是一个轻量的实验项目，目前提供历史回放、终端交互与结果记录。内置 `minimal` harness，支持自定义提示词；其他实验 profile 和自动评估尚未内置。

## 快速开始

需要 Python 3.10+ 和 OpenRouter API key。从仓库根目录运行：

```powershell
pip install -r requirements-replay.txt

# PowerShell
$env:OPENROUTER_API_KEY="你的 key"
python tools/replay.py --moment M03 --model anthropic/claude-opus-4.6 --provider anthropic
```

在 Bash / Zsh 中，用 `export OPENROUTER_API_KEY="你的 key"` 设置 key，再运行相同命令。

在终端直接回复模型即可。模型提问时，可以输入选项编号，也可以自由回答，没有倒计时。按 **Ctrl+C** 结束并保存对话。

模型与 provider 的可用性以你的 OpenRouter 账户和服务端支持为准。

## 选择回放起点

每个 moment 是一次真实协作的历史分叉点。模型获得该起点之前的上下文，之后的讨论由你继续参与。

| Moment | 讨论主题 |
|---|---|
| M01 | 概念与公理体系的形成 |
| M02 | 设计方向复盘 |
| M03 | 公理体系审视 |
| M04 | 项目为何存在 |
| M05 | JS 后端与独立验证的取舍 |
| M06 | Type RC 与完整内存回收 |

部分 moment 支持从后续历史轮次开始：

```powershell
# 查看可用起点
python tools/replay.py --moment M05 --list-rounds

# 从第 2 个历史起点继续讨论
python tools/replay.py --moment M05 --start-round 2 --model anthropic/claude-opus-4.6 --provider anthropic
```

`--start-round` 选择的是历史起点，不限制本次交互的轮数。历史前缀里已经出现的想法，不应算作本次模型的独立发现。

## 配置实验

| 参数 | 用途 |
|---|---|
| `--model vendor/model` | 选择 OpenRouter 模型 |
| `--provider anthropic` | 固定服务提供方，默认不允许 fallback |
| `--effort high` | 设置推理强度；默认 `default`，使用服务端默认配置 |
| `--temperature 0.7` | 设置采样温度；默认使用服务端配置 |
| `--system-prompt-file PATH` | 加载自定义 harness 提示词，仍保留历史上下文 |
| `--max-tokens 32768` | 设置单次响应的输出上限 |

参数支持范围因模型与 provider 而异。完整选项见 `python tools/replay.py --help`。

比较模型时，尽量保持 moment、起点、harness、推理设置与交互方式一致；比较 harness 时，保持模型和其他条件一致。正式记录建议指定 provider，减少自动路由带来的变量。

### DeepSeek 直连

也可以使用 DeepSeek API，用于日常回放或与 OpenRouter 做对照：

```powershell
$env:DEEPSEEK_API_KEY="你的 key"
python tools/replay.py --gateway deepseek --moment M03 --model deepseek-v4-pro --effort max
```

原有 `tools/replay_deepseek.py` 入口仍可使用。跨入口比较时，请显式设置相同的实验条件。

## 查看结果

每次运行的结果保存在 `runs/<moment>/<时间>-<模型>-r<轮次>/`。

- **`conversation.md`**：阅读和分享本次对话。
- **`run.json`**：查看实验配置与运行状态。
- **`transcript.jsonl`**：查看完整交互与工具记录。
- **`initial_request.json`**：检查模型在起跑时收到的输入。

结果适合用于逐轮分析：模型有没有重新理解问题？用户的一次纠偏是否改变了后续方向？协作让用户更容易继续思考，还是增加了整理负担？当前没有自动评分，也不会自动替用户回答。

## 运行前检查

以下命令不调用模型，也不需要 API key：

```powershell
# 检查回放环境
python tools/replay.py --moment M03 --check-environment

# 生成并检查初始请求
python tools/replay.py --moment M03 --provider anthropic --dry-run
```

M01 的原始文件已恢复，全部 205 个环境资源文件通过完整性校验。

回放环境是部分历史恢复，不等同于原产品的完整运行环境。各包的内容与恢复限制见 [回放包说明](README_M02-M06.md)。模型在所选起点之后的历史答案与研究评价不作为回放输入。

## 开发

运行离线测试：

```powershell
python -m unittest discover -s tools/tests -v
```

线上 API 兼容性仍需使用目标模型与 provider 实测。
