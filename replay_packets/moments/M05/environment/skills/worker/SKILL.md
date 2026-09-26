---
name: worker
description: Use when user wants to execute implementation tasks — "执行", "开始工作", "下一个 wave", "worker", "修 audit", "fix", or any request to implement backlog/audit items. Reads from backlog + audit-report, generates plans, dispatches worktree subagents, maintains table status.
---

# Worker Agent

从 backlog + audit-report 读取待做 items，生成实现 plan，用 worktree subagent 并行执行，维护表状态。

**你是 orchestrator——写 plan + 调度 subagent，不自己写代码。**
**工作流规范见 `docs/workflow.md`**

## Trigger

User says: "执行", "开始工作", "下一个 wave", "worker", "并行执行", "修 audit", "fix audit", "处理审计项", or `/worker`.

## 写入范围

- 代码：`compiler/`, `std/`, `tests/`（通过 subagent 在 worktree 中执行）
- 文档：`CLAUDE.md`（功能变更后更新）
- 表状态：`docs/backlog.md` 和 `docs/audit-report.md` 的状态字段

**不触碰**：`docs/design.md`

## Workflow

### Step 1: 扫描两个表

```bash
# 读取待做 items
grep -n "\[queued\]" docs/backlog.md
grep -n "\[open\]" docs/audit-report.md
```

收集所有 `queued` (backlog) 和 `open` (audit-report) items。
**跳过 `waiting-feedback` 状态的 item**——这些在等 Discussion agent 处理设计问题。

### Step 2: 排序、分组与 Dispatch 核查

**优先级排序**：P0 > Critical open > P1 > Important open > P2 > Minor open > P3 > Style open

**Dispatch 核查**：对每个 item 检查 `dispatch` 标记（`mechanical` / `judgment`）：
- `mechanical`：使用 `deepseek-dispatch` skill 派发给 DS 执行（成本低，适合解法唯一确定的任务）
- `judgment`：使用 Claude worktree subagent 执行（需要设计判断力）
- **核查规则**：Worker 在执行时独立判断 dispatch 标记是否合理——Discussion 出任务时的判断可能有误。如果 Worker 认为某个 `mechanical` item 实际需要 judgment（spec 模糊、涉及多种实现方式、需要理解 Ring 编译器约定），应**升级为 `judgment`** 并在 feedback 中说明原因。反之，`judgment` item 如果 plan 生成后发现实际只需机械执行，可**降级为 `mechanical`**。

**分 Wave**：
- 同一 Wave 的 items 无文件重叠，可安全并行
- 有依赖的排后面的 Wave
- 每 Wave 最多 3 个 worktree subagent（含 DS subagent）

向用户展示 Wave 计划（含每个 item 的 dispatch 分配），等用户一次性 approve。

### Step 3: 执行 Wave

#### 3a. 状态更新：`queued`/`open` → `planning`

Edit backlog/audit-report 中对应 items 的状态标记。

#### 3b. 生成 Plan

对每个 item 读取 spec（backlog body 或 audit-report 描述），结合仓库现状生成实现 plan。

**使用 superpowers:writing-plans skill 生成 plan。**

**Spec 验证（关键）**：如果 spec 描述的代码/API/结构与仓库现状不符：
- **STOP**
- 将 item 标回 `queued` 或 `open`
- 向用户报告："B-xxx 的 spec 与仓库不符——spec 说 XXX 但实际是 YYY"
- 不继续执行，不猜测，等用户处理

#### 3c. 状态更新：`planning` → `doing`

Plan 通过后更新状态。

#### 3d. 派发 Worktree Subagent

记录 main HEAD：
```bash
git log --oneline -1   # EXPECTED_BASE
```

根据 item 的 `dispatch` 标记选择执行者：

**`judgment` → Claude Worktree Subagent（原有流程）**

```
Agent({
  description: "WT<wave><n>: <item-id> <short-desc>",
  isolation: "worktree",
  run_in_background: true,
  prompt: "<agent prompt>"
})
```

**Agent Prompt 模板**（精简版——agent 会自己读 CLAUDE.md，不重复项目上下文）：

```
你在一个隔离的 git worktree 中实现以下任务。

**首先验证 base commit：** `git log --oneline -1`，
确认为 `<EXPECTED_BASE>`。不匹配则停止报告。

## 任务
<TASK_SPEC — 从 plan 中提取的完整实现步骤>

## 验收标准
<从 backlog/audit-report spec 中复制>

## 完成检查
1. 重编译：node compiler/dist/main.js build compiler/main.ring --out-dir=compiler/dist
2. 测试：cd compiler && npm test
3. 只做 spec 范围内的改动，不做额外重构
4. 发现新 bug → 记录在 commit message 中，不自行修复
```

**`mechanical` → DS Worktree Subagent**

Orchestrator 手动建 worktree 提供隔离，然后按 `deepseek-dispatch` skill 标准流程派发：

```bash
git worktree add .worktrees/ds-<item-id> -b ds/<item-id> HEAD
```

DS prompt 中指定 worktree 绝对路径为工作目录，其余调用细节由 `deepseek-dispatch` skill 管理。DS 会读 AGENTS.md 获取项目约定。

失败处理：(a) 同一 session 追加消息让 DS 修正；(b) 升级为 judgment 由 Claude 接手。

#### 3e. 等待完成 + 验证

Agent 完成后：
1. 验证 base commit（`git log` 确认）
2. Review diff（`git diff HEAD~1 -- ":(exclude)compiler/dist/*"`）
3. 标记：✅ 通过 / ❌ 失败

#### 3f. 顺序 Merge + Amend（无 broken state）

**原则**：merge commit 必须包含完整可工作的状态——dist/ 已重编译、tracking 已更新。不允许 broken intermediate state 作为独立 commit 存在。

按冲突由少到多 merge：
```bash
cd <worktree-path> && git rev-parse HEAD
cd <main-repo> && git merge <commit-hash> --no-edit
```

dist/ 冲突：`git checkout --ours compiler/dist/` → rebuild 覆盖
源码冲突（可解决）：手动 Edit 解决
源码冲突（语义冲突）：停下来问用户

**Merge 后立即执行（全部 amend 进 merge commit）**：

```bash
# 1. Rebuild dist
node compiler/dist/main.js build compiler/main.ring --out-dir=compiler/dist
git add compiler/dist/

# 2. 更新 tracking（删除已完成 item）
# Edit audit-report.md / backlog.md 删除对应条目

# 3. 更新 CLAUDE.md（如功能变更影响了描述）

# 4. Amend 全部进 merge commit
git add docs/audit-report.md docs/backlog.md CLAUDE.md
git commit --amend --no-edit
```

**测试**：
```bash
cd compiler && npm test
```

测试全绿 → 继续下一个 merge 或下一个 wave
测试失败 → 二分定位，报告用户

#### 3g. 清理 Worktree

```bash
git worktree list    # 检查残留
git worktree remove -f -f <path>  # 清理每个完成的 worktree
```

### Step 4: Wave 间推进

测试全绿 → **直接启动下一个 Wave**（不等用户确认）
测试失败 → 定位问题，报告用户，等待决策

### Step 5: 最终报告

```markdown
## 执行完成

| Wave | Items | 状态 | 测试 |
|------|-------|------|------|
| A | B-019, #70 | ✅ | 355/355 |
| B | B-020 | ✅ | 358/358 |

**Backlog 清理**: B-019, B-020 已删除
**Audit 清理**: #70 已删除
**测试**: 起始 353 → 最终 358 (+5)
```

## 发现新问题时

Worker 在实现过程中可能发现新 bug、设计偏差或需要讨论的决策。按类型分流：

**技术 bug（明确的代码缺陷）**：
- 追加到 `docs/audit-report.md` 作为新 `open` item
- 不自行修复超出 spec 范围的问题

**设计问题 / 待决策项（需要用户判断）**：
- 追加到 `docs/worker_feedback.md`，标记 `[决策]`，按 backlog item 分组
- 每条包含：**现状**（发现了什么）、**原因**（为什么会这样）、**待决策**（列出选项）
- **更新 backlog item**：把已完成的部分写入 spec（进度不丢失），状态改为 `waiting-feedback`
- Worker 扫描时**跳过 `waiting-feedback` 状态的 item**——等 Discussion agent 处理完重新排队

**值得用户了解的信息（不阻塞工作）**：
- 追加到 `docs/worker_feedback.md`，标记 `[通知]`
- 不改变 item 状态，worker 照常完成工作
- 典型场景：实现中的取舍说明、跳过 plan 某步骤的原因、发现的潜在改进点、影响范围比预期大/小的情况
- **原则**：worker session 很长，用户无法回看全部过程。凡是值得用户知道但不紧急决策的信息都应推送，由 Discussion agent 在下次对话时呈现

**积极写 feedback——宁多勿少。** 以下情况都应该写 `[通知]`：
- 实现过程中做了任何取舍或判断（即使你觉得是"显然的"——用户不在场，不知道你做了什么）
- Spec 的某个步骤被跳过或调整了执行顺序
- 发现了 spec 没提到但相关的代码问题（即使不确定是否是 bug）
- 实际影响范围与 spec 预估不同（更大或更小）
- 测试中发现的边界情况（即使最终通过了）
- 任何"差点出错"的情况

**不写 feedback 是错误——用户看不到你的 session 过程，feedback 是唯一的信息通道。** 如果一个 wave 执行完 feedback 为空，大概率是你漏写了而不是真的什么都没发生。每个已完成的 item 至少应该有一条 `[通知]` 总结实现中的关键判断。

**worker_feedback.md 格式**：
```markdown
## B-xxx <标题>

### <序号>. <问题简述> [决策]

**现状**：...
**原因**：...
**待决策**：
- (A) 选项一
- (B) 选项二

### <序号>. <信息简述> [通知]

<简要说明>
```

- 在最终报告中列出所有新发现的 items 和 feedback

## 特殊情况处理

| 情况 | 处理 |
|------|------|
| Spec 与仓库不符 | STOP，标回 queued/open，报告用户 |
| Agent base commit 错误 | ❌ 标记失败，正确 base 上重新派发 |
| Merge 冲突（dist/ only） | checkout --ours，rebuild 覆盖 |
| Merge 冲突（源码，可解决） | 手动 Edit 解决 |
| Merge 冲突（语义冲突） | 停下来问用户 |
| 测试回归 | 二分定位，revert 问题 merge，报告用户 |

## 关键规则

- **不要串行派发**——同一 Wave 的 agent 必须在同一条消息中并行发出
- **Orchestrator 不实现任务**——你调度和合并，不自己写代码
- **Spec 是法律**——严格按两个表的 spec 执行，不自由发挥
- **做完即删**——完成的 item 从表中删除，保持列表精简
- **状态及时更新**——queued → planning → doing → 删除（正常流）；doing → waiting-feedback（遇设计问题），每步都 commit
- **不碰 waiting-feedback 的 item**——这些在等 Discussion agent 决策，Worker 跳过
- **Base commit 验证是必须的**——每个 agent prompt 第一件事
- **每次 Wave 后清理 worktree**——`git worktree remove -f -f`
