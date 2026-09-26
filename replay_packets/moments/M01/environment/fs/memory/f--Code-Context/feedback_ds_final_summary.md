---
name: ds-final-summary
description: "DS dispatch prompts must instruct model to include full report in final message, because --output-format json only captures the last turn"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 229903ec-5833-4fc6-9f23-50b7b83c305e
---

DS dispatch 的提示词末尾必须加类似"请在最终回复中输出完整报告全文，不要分散在多轮中"的指令。

**Why:** `claude -p --output-format json` 只返回最后一条 assistant 消息。多轮 web 搜索任务中，DS 会在中间轮次输出调研内容、最后一轮只写总结，导致实际报告内容丢失。

**How to apply:** 在所有 DS `-WebOnly` 和 `-ReadOnly` 的 prompt 末尾追加：`重要：你的最终回复必须包含完整的结构化报告全文。不要假设中间轮次的输出会被保留——只有最后一条消息会被返回给调用方。`
