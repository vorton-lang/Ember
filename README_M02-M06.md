# M02–M06 交互回放包

以下保留 M02–M06 的包说明与历史恢复限制；当前通用 runner、OpenRouter 配置与日志格式见 [README.md](README.md)。

## 启动

```powershell
pip install -r requirements-replay.txt
$env:DEEPSEEK_API_KEY="你的key"
python tools/replay_deepseek.py --moment M03 --model deepseek-v4-pro --effort max
```

把 `M03` 换成下表任一 moment。Flash 使用 `--model deepseek-flash`。
终端逐行输入；模型可主动调用 `Read / Glob / Grep / Skill / AskUserQuestion`。
随时 Ctrl+C 结束并保存。没有 simulator、自动评分或自动替用户回答。

| Moment | 历史分叉点 | 可选历史起跑轮次 | 恢复的仓库文件 | Git 提交 |
|---|---|---|---:|---|
| M02 | 设计方向复盘 | 1 | 585 | 89d2eb78364e |
| M03 | 公理体系审视 | 1 | 591 | 1fb7f0fd853e |
| M04 | 项目为何存在 | 1 | 592 | 958ddb1dd2c8 |
| M05 | JS differential oracle | 1、2、3 | 564 | fe7843d15349 |
| M06 | Type RC / 完整内存回收 | 1 | 569 | 574b92d263fd |

`--start-round 1` 是该 moment 的 anchor，不一定是原会话第一条消息。
M02、M04–M06 保留 anchor 前的历史会话及工具往返；M03 是新会话。
因此前置历史里已有的想法不能算 candidate 独立发现。

当前 canonical continuation 只为 M05 保留了更多直接 human turn，其他四包只有第 1 个起跑点。
这不限制运行后继续交互的轮数。

```powershell
python tools/replay_deepseek.py --moment M05 --list-rounds
python tools/replay_deepseek.py --moment M05 --start-round 2 --model deepseek-v4-pro --effort max
```

## 保存结果与离线检查

结果位于 `runs/M03/<时间>-<模型>-r1/`，包含：

- `conversation.md`：方便阅读的历史前缀及本次对话。
- `transcript.jsonl`：API 响应、thinking（若 API 返回）、工具输入和返回、现场用户输入。
- `initial_request.json`：首次请求完整 system/messages/tools/参数，不含 API key。
- `run.json`：moment、切点、请求/返回 model、文件哈希、恢复限制、运行状态。

`initial_request.json` + `transcript.jsonl` 可以检查上下文和工具读取来源。
历史模型的 hidden thinking 不转交 candidate；本次模型返回的 thinking 仅按 API 返回值保存。

```powershell
# 不调用 API，不需要 key：保存起跑时会发送的请求
python tools/replay_deepseek.py --moment M03 --dry-run

# 检查资源哈希、时间边界和初始输入
python tools/replay_deepseek.py --moment M03 --check-environment
```

## 信息边界与恢复精度

每包仍为 `partial`。使用该 anchor 之前主分支的 Git tree，文件仅通过工具按需读取；
`historical/`、`provenance/`、相邻 moment、宿主机器文件不挂载给 candidate。
第 1 轮 runner 不打开 historical/provenance；指定后续轮次才有意加载已发生的历史前缀。

- 每包恢复 3 个项目 skill：discussion、full-audit、worker。后两者可读，但其 shell/写入/派工要求无法执行。
- 原始 CC 的完整系统提示词与全局 memory 没有恢复。仍沿用 M01 的简化 system + 可恢复注入信息。
- CLAUDE.md 等仓库文件在 environment 中可读；没有将整个仓库或文档提前灌进 system。
- 编译产物和二进制在考古仓库中已被排除：每包缺 42–43 个此类文件。全部缺项列在 environment/manifest.json。
- 快照不代表已经确认的现场未提交状态；后台 worker 的并发改动也没有模拟。
- M03 的 philosophy.md、worker_feedback.md、lang-design.md 片段已与原始首轮读取逐项核对一致。
- M05 的历史前缀缺一条 Grep 返回，runner 插入明确的“历史结果缺失”错误并在 run.json 记录，不伪造内容。
- 后续 `--start-round` 仍使用 anchor 的只读 environment；历史前缀里的写操作不会重放到文件系统。
- 仅恢复历史可见输入，不向模型提供研究标签、期待答案或评分目标。

目录保留 M01 的 packet/context/workspace/environment/historical/provenance 结构。
`bundle_manifest.json` 记录打包版本和各包哈希；`replay_validation.json` 记录离线检查结果。
本包没有实际调用付费 API，已通过消息配对、工具读取、隔离和中断保存的离线验证。

通用 runner 也支持已有的 M01 包：将二者解压到同一目录后使用 `--moment M01`。
