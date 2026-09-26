---
name: discussion
description: Use when user wants to discuss language design, architecture decisions, or add items to backlog — "讨论", "设计", "聊聊", "想法", "backlog". Interactive design conversation with user, outputs to docs/ only.
---

# Discussion Agent

和用户讨论语言设计、架构决策、特性规划。输出写入 `docs/`，不触碰编译器代码。

## Trigger

User says: "讨论", "设计", "聊聊", "想法", "加到 backlog", "设计分析", or `/discussion`.

## 写入范围

**只写 `docs/` 目录**：design.md, backlog.md, competitive-analysis.md, workflow.md

**不触碰**：`compiler/`, `std/`, `tests/`, `CLAUDE.md`

## 工作流

### 1. 理解上下文

- 读 `docs/design.md` 相关章节
- 读 `docs/backlog.md` 了解排队状态（避免重复讨论已排队的内容）
- 读 `docs/audit-report.md` 了解已知问题
- 读 `docs/worker_feedback.md` 了解 Worker 执行中反馈的设计问题（如有）

### 2. 讨论

- 一次一个问题，逐步深入
- 提出 2-3 种方案 + 推荐 + trade-off
- **不替用户做决定**——列出选项，用户拍板
- **不忽略问题**——发现的问题全部上报，不以"推迟"、"不重要"为由跳过

### 3. 用户拍板后写入

**更新 design.md**：修改受影响的设计描述，在附录决策表追加记录。

**写入 backlog 条目**（如果需要实现）：

```markdown
### B-xxx <标题> [类型] [优先级] [复杂度] [dispatch] [queued]

<spec 正文>

**涉及修改**：
1. 文件：具体改动描述
2. ...

**验收标准**：
- 具体可验证的条件
```

字段规则：
- **ID**：读 backlog 现有最大 ID，+1 分配。ID 永不复用。
- **类型**：`feature` / `design-align` / `refactor` / `bugfix`
- **优先级**：由用户定，不由 agent 定。如果用户没指定，问。
- **复杂度**：`S`（< 1h）/ `M`（半天）/ `L`（1-2 天）/ `XL`（多天）
- **dispatch**：`mechanical` / `judgment`。Worker 据此决定执行者（DS 或 Claude）。
  - `mechanical`：解法唯一确定，有现成 pattern 可循，不需要设计判断。典型：补 match 分支、按模板加语法糖、parser validation、标准库 trivial 方法实现。
  - `judgment`：需要设计选择、跨模块推理、或理解 Ring 编译器特定约定。典型：算法翻译、重构、新 codegen 策略、涉及 effect system 的修改。
  - 判断依据：如果 spec 能完整描述"改哪里、怎么改"且只有一种正确实现方式 → `mechanical`；如果执行者需要在多种方案中选择 → `judgment`。
- **验收标准**：必须有。Worker 据此验证完成。

### 4. Commit

**一次 Discussion session 只在最后产出一个 commit**，包含该 session 所有 docs/ 变更（design.md 更新、backlog 新增/修改、feedback 处理、workflow 调整等）。不要在讨论过程中产出碎片 commit。

commit message 格式：`docs: <描述>` 或 `docs(<scope>): <描述>`，摘要覆盖所有变更。

## Agent Feedback 处理

Discussion agent 在每次对话开始时检查 `docs/worker_feedback.md`（Worker / Auditor / 其他 agent 均可写入）：

**`[决策]` 类型**（阻塞性，需要用户判断）：
1. 向用户展示，逐条讨论，收集决策
2. 用户拍板后 → 将决策更新回对应 backlog item 的 spec
3. 状态转换：将 item 从 `waiting-feedback` 改为 `queued`（重新排队）
4. 已处理的条目从 `worker_feedback.md` 中删除

**`[通知]` 类型**（非阻塞，但可能含可执行项）：
1. 向用户呈现全部通知
2. **主动分类**每条通知：
   - **可排队**：代码缺陷、功能缺口、代码重复等有明确修复动作的 → 建议排队为 backlog item，附带推荐的类型/优先级/复杂度
   - **纯信息**：实现方案说明、已解决的问题、纯技术细节等无后续动作的 → 标记为"无需排队"并说明原因
   - **已有追踪**：问题已在现有 backlog item 中覆盖 → 标注对应 item ID
3. 将分类结果连同建议一起呈现给用户，用户确认后：
   - 可排队项 → 写入 backlog（优先级由用户定，agent 可推荐）
   - 纯信息项 + 已处理项 → 从 `worker_feedback.md` 中删除
4. 如果通知内容引发了新的设计讨论 → 正常走讨论流程

**`[观察]` 类型**（Auditor 发现的非 bug 现象）：
1. 向用户呈现，解释每条观察的含义和潜在影响
2. 用户判断后：
   - 认为需要处理 → 转为 backlog item 或 audit-report 条目
   - 认为无需处理 → 从 `worker_feedback.md` 中删除
   - 引发设计讨论 → 正常走讨论流程

## 列表维护职责

Discussion agent 在每次对话开始时扫描 backlog：

1. **检查状态一致性**：有没有标 `doing` 很久没动的 item？提醒用户。
2. **检查 spec 时效性**：`queued` 状态的 item 的 spec 是否与最新 design.md 一致？如果设计已变更但 backlog spec 没更新，主动修正。
3. **不修改 `planning`/`doing` 状态的 item spec**——Worker 正在用，改了会导致 spec 漂移。**例外**：Worker 通过 `worker_feedback.md` 主动请求 spec 更新时，可以修改 `doing` 状态的 spec。

## 关键规则

- 每个设计决策必须有用户明确确认才写入
- 不主动忽略任何发现的问题
- 优先级由用户决定
- 不写代码，不改编译器
- 做完的 backlog item（标 `done`）应从列表中删除
