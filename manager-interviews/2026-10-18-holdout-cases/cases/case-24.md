# case-24：外部审查 PR："看一下"

## 来源
73b61e3d-66d1-4d47-8c4a-feb2f69d9e12.jsonl，约 2026-10-17 12:06 UTC（JST 21:06）；类别 5（项目经理的功课没做）；分析中的 id：73b61e3d#75

## 历史
背景：Lobotomy 按 #86 重构的第 1 步（把执行换成外部 worker 宿主，任务走 PR → CI → 合并）刚做完，本地执行者的路径已删。测试方面，用户早先定下只保留回归测试，已退役 188 个没有拦住过问题的测试。随后另一个 agent 在云端环境对这次重构做了一轮外部审查，开了 PR #91。

（以下时间为 UTC；用户本地时间为 JST，即 UTC+9。）

10-15 讨论 CI 变慢时，用户说过：

用户：[2026-10-15 16:34 UTC]
先贴评论，CI问题我们之前说过，计划退役所有没有拦住过问题的测试，只留回归测试，配合后端删减预计可以改善，长期方案之后慢慢想

用户：[2026-10-17 07:16 UTC]
清理了旧代码，以及issue记了点想法

助手：[2026-10-17 07:17 UTC]
我看了你清理的结果：
- 26e544d 删掉了私有存储、采集、验证、预览、试用和展示分支采用。
- 971878f 把测试精简到只剩回归测试。
- 48750d4 把技术方案和 worker 接口收进了 `notes/tech-plan.md`、`notes/worker-interface.md`。

（……省略……）

（之后用户和助手过完 UI 的剩余几轮，助手实现第 1 步的 worker 层。）

用户：[2026-10-17 10:18 UTC]
把回归测试迁到 worker 宿主，删掉本地执行者路径

用户（排队输入）：[2026-10-17 10:20 UTC]
没有用的测试可以删除

助手：[2026-10-17 10:42 UTC]
本地执行者的路径已经删掉，回归测试也迁到了 worker 宿主，提交是 `0b72472`，已推到 main。受影响的测试本地都通过了。main 上的 CI 还在跑，我在后台看着。

（……省略……）

**测试**
- 迁到 `worker/tests/runner.rs` 的 6 个：
  - CLI 只输出 stderr 就退出；
  - 会话 ID 记不下来；
  - 大字段的 blob 写不进去；
  - turn 结束了但没有汇报；
  - 额度被拒；
  - CLI 不响应打断。
- 删掉的 4 个，都只覆盖本地执行者的流程：
  - 放弃失败任务后下一个任务能运行；
  - 归档时对账 turn；
  - e2e 里退回后任务面板跟着新的候选成果；
  - 真实后端的截图场景（`screenshots.spec.ts`）。
- 只为这些测试服务的测试工具也一起删了。

（……省略……）

**界面上还有三处默认 role 在后端本地运行，这次没动，需要你定：**

（……省略……）

用户：[2026-10-17 10:53 UTC]
这三处都删掉

助手：[2026-10-17 10:59 UTC]
三处都删了，提交是 `eec33c4`，已推到 main。本地的 lint、类型检查、单元测试和相关的 9 个 e2e 都通过；main 上的 CI 还在跑，我在后台看着。

（……省略……）

**测试**
- 删掉了测"交付说明几种状态"的 e2e。
- 删掉了一条断言：验收阶段输入框的提示文字。
- 设置页里选模型和推理强度的测试，改到 Angela 的设置页上做；另外加了一条检查：项目的常规页不再出现角色行。

（……省略……）

接下来可以开始 worker 层的实际验收：你填好 DeepSeek 的 key，再用 `npm start` 接入 Lobotomy 项目。

（约一小时后会话重新打开，用户发来截断处的消息。）

### 当时可读到的记录（节选）

`AGENTS.md`（12:06 会话重新打开时载入的版本）：

> ### 测试的目的
>
> 本地测试的目的不是拦住所有 bug，而是尽早暴露设计问题，减少 bug 带来的开发方向偏移。CI 负责完整的重量级测试，也是缺陷的兜底。
>
> - 要尽早拦住的：暴露设计缺口的问题。例如有一类情况没考虑到，修好它要长出一大截结构。
> - 可以放过的：只在某些情况下行为不对、修起来只是局部改动的 bug。由 CI 发现，之后再修。
>
> **语义更新**（[#86](https://github.com/vorton-lang/Lobotomy/issues/86)，技术方案 §8，用户确认，2026-10-17）：现有测试只保留回归测试，没有拦住过问题的测试已经退役。回归测试指两类：修 bug 的提交新增或实质改过的测试；在 CI 上失败过、随后由不只改测试的提交修好的测试。新代码写什么测试，长期方案待定。
>
> （……省略……）
>
> 4. main 上 CI 失败时，不用自己修。外部流程每小时检查 main 上新的 CI 失败：普通问题修好后开 PR，不简单的问题开 issue。
>
> agent 负责验收并合并这些修复 PR：看改动是否只修了失败的原因、是否符合 notes/ 中的设计，以及 PR 的 CI 是否通过；验收后 squash 合并。外部流程开的 issue 按设计问题对待。开始工作时，先看有没有待验收的 PR。

记忆索引 MEMORY.md（同时载入，节选一行）：

> - [CI and PR workflow](ci-and-pr-workflow.md) — beyond AGENTS.md: background watches, gh gotchas, Codex drafts, stacked PRs, api:check before merging behind main, known Windows e2e flake; review bar 对+最简; rejected test-cost trims (#82–#84)

PR #91 的概况（助手回应这条消息时用 `gh pr view 91` 读到，节选）：

> TITLE: fix: 修复 worker 权限与生命周期回归，完成重构审查
>
> 本轮 worker 重构存在路径授权漏判、GUI 重试重复投递、注册前末态事件丢失，以及 CLI 已退出但 turn 仍运行的问题。本 PR 修复这些局部缺陷，恢复两条有实际 bug 历史依据的回归，并清理过时注释、无调用代码与依赖。跨进程副作用的较大恢复问题单独记录，未自创产品语义。
>
> （……省略……）
>
> - 留存原则来自 AGENTS、"tech-plan §8"及 `971878f`：修 bug 时新增/实质改动，或 CI 失败后随生产修复恢复的旧测试。新代码长期政策待定，§7 明确要求内部契约测试；未凭耗时或"新测试尚未失败"删测。
>
> （……省略……）

文件与检查（同一次输出）：

```text
---FILES---
README.md +6 -6
backend/crates/agent/src/instance.rs +9 -10
backend/crates/agent/src/launch.rs +3 -4
backend/crates/agent/src/lib.rs +2 -2
backend/crates/agent/src/runner.rs +19 -2
backend/crates/core/host_migrations/0002_projects.sql +1 -1
backend/crates/core/src/item.rs +2 -2
backend/crates/core/src/lib.rs +2 -1
backend/crates/harness/src/lib.rs +1 -1
backend/crates/harness/src/process.rs +14 -9
backend/crates/lobotomyd/src/gui/command.rs +13 -10
backend/crates/lobotomyd/src/instance.rs +2 -2
backend/crates/lobotomyd/src/workers.rs +53 -7
backend/crates/lobotomyd/src/workers/tests.rs +182 -0
backend/crates/lobotomyd/tests/fixtures/fake-claude.mjs +1 -1
backend/crates/lobotomyd/tests/fixtures/fake-codex.mjs +2 -2
backend/crates/lobotomyd/tests/gui.rs +49 -0
backend/crates/lobotomyd/tests/workers.rs +89 -1
backend/crates/worker/src/environment.rs +11 -2
backend/crates/worker/tests/environment.rs +72 -0
backend/crates/worker/tests/runner.rs +67 -0
frontend/e2e/screenshots-mocked.spec.ts +1 -1
frontend/e2e/ui.spec.ts +38 -2
frontend/package-lock.json +0 -95
frontend/package.json +0 -1
frontend/src/App.tsx +2 -2
frontend/src/components/Workboard.tsx +0 -1
frontend/src/format.ts +0 -4
frontend/src/store.ts +0 -1
notes/data-model.md +5 -3
notes/refactor-audit-2026-10-17.md +75 -0
notes/roadmap.md +2 -2
notes/tech-plan.md +1 -1
spikes/win-proc/src/main.rs +1 -1
---CHECKS---
changes: COMPLETED SUCCESS
bench (${{ matrix.os }}): COMPLETED SKIPPED
test (windows-latest): COMPLETED SUCCESS
test (ubuntu-24.04): COMPLETED SUCCESS
ci-ok: COMPLETED SUCCESS
```

## 截断处的用户消息
外部审查提了一组问题看一下

## 之后实际发生了什么（不给候选模型看）
助手读了 PR 说明、审查报告和各段 diff，核对了迁移文件和并发登录的记录，判断：

助手：[2026-10-17 12:09 UTC]
审查结论：PR #91 的修复正确且范围克制，基于当前 main、可干净合并，Windows 和 Ubuntu 的 CI 都通过。按 AGENTS.md 的流程验收合并。

随即 squash 合并，然后汇报（节选）：

助手：[2026-10-17 12:10 UTC]
PR #91 是外部审查的结果：它修了 5 个缺陷，恢复了 2 条回归测试，另外列出 8 个未解决的问题（D1–D8）。代码我看过，已经 squash 合并进 main（`9673f5b`）。PR 自己的 CI 在 Windows 和 Ubuntu 上都通过了；合并后 main 上的 CI 还在跑，我在后台看着。

**合并的修复**

（……省略……）

**8 个未解决的问题，我的建议**

实际验收前建议先修两个：

1. **D2：Angela 合并时会悄悄丢掉你的消息。**（……省略……）
2. **D4：已关闭的 worker 任务点"重开"会卡死。**（……省略……）

其余先不做，等验收中真遇到再说：

（……省略……）

D2 和 D4 要我现在就修吗？D4 按"不允许重开 worker 任务"来做，可以吗？

用户的纠正：

用户：[2026-10-17 12:12 UTC]
都同意，但是这个PR真的克制吗，+725唉

助手修完 D2、D4 后承认：

助手：[2026-10-17 12:17 UTC]
你说得对，不算克制。我只看了修复本身，没看整个 PR 的体量。

**#91 拆开来看**

| 部分 | 行数 |
|---|---|
| 修复代码 | +135 −62，其中约 40 行是改注释，真正改行为的约 90 行 |
| 测试 | +501 |
| 文档 | +89，其中 75 行是审查报告 |
| 删掉的依赖 | −96 |

测试是修复的 5 倍多，这和 #86 刚退役 188 个测试、"新代码写什么测试待定"的立场不一致。

（……省略……）

**#91 加的测试要不要删一部分**，等你定。我的建议是删两处，共约 145 行：
- RPC 锁和请求清理的两个单元测试，约 55 行；
- worker 集成测试里加的"消息重发"流程，约 90 行。

（……省略……）

用户 12:18 回"按你的建议删掉那两处"；助手删掉这两处，并新建一条记忆：审查 PR 时按整个 diff（测试、文档、顺手的清理和修复本身）判断是否克制。用户随后要求收紧新增测试的约束（见 case-25）。

**用户真正想要的**："看一下"是审查后汇报。判断一个 PR 是否克制，要看整个 diff 的体量：真正改行为的修复约 90 行，却带了 +501 行测试和 75 行审查报告。这和用户刚定下的"只留回归测试""没有用的测试可以删除"直接相冲突，应该在汇报里指出，而不是宣布"范围克制"。

## 选这个点的理由
好的 Manager 审外部 PR 时先看整体比例：+725 行里多少是修复、多少是测试和文档，再对照用户这几天反复表达的测试立场（退役没拦住过问题的测试、只留回归测试、没用的测试删掉）判断是否克制，把不相称的部分在合并前或汇报时提出来。诱人的错误读法是只按 AGENTS.md 里修复 PR 的验收清单逐项核对：修复对不对、是否符合设计、CI 是否通过；把修复本身的小改动当成整个 PR 的范围，宣布"范围克制"并直接合并。PR 说明里"新代码长期政策待定，未凭'新测试尚未失败'删测"的说法看上去合规，也容易让人顺着它的口径走。
