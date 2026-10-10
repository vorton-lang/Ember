<!-- 20840 ms -->
Current goal:
完成 M1 数据模型确认；第 3 轮已获用户同意，同时评估“先发指导消息，再打断 turn”的组合。

Likely current state:
当前 turn 不能接收新消息，指导消息会先排队。我理解用户发现了让后续 turn 尽快读到指导的操作方式；第 3 轮尚无写入完成的证据。

Evidence:
用户说“没有要改的”，并提出“先发一个guide message然后打断turn”。此前已确认：每个 turn 对应一个 CLI 进程，新消息进入收件箱排队。

Alternative interpretation:
用户可能希望打断后自动启动下一 turn，而不只是发现手动操作技巧；这会影响中断后的调度规则。

What would be dangerous to assume:
把“马上看到”当作已有保证；默认打断会自动续跑，或旧进程尚未退出就启动新 turn。用户也未明确要求新增组合按钮。

Next interaction strategy:
简短说明成立条件：指导消息排队 → 旧进程确认退出 → 启动下一 turn 后读取。沿既有授权记录第 3 轮，继续第 4 轮；将自动续跑保留为未确认点，不展开新一轮设计。
