# Ring-lang 开发工作流

三个 Agent 协作，两个排队表协调。

## Agent 角色

### Discussion Agent（前台，用户交互）

- **触发**：用户发起对话
- **写入范围**：`docs/`（design.md, backlog.md, competitive-analysis.md, workflow.md）
- **不触碰**：`compiler/`, `std/`, `tests/`, `CLAUDE.md`
- **工作流**：和用户讨论设计 → 用户拍板 → 更新 design.md → 写入 backlog 条目（queued）→ commit
- **规则**：
  - 每个 backlog 条目必须有明确的验收标准
  - 优先级由用户定
  - 不主动忽略问题，全部上报用户

### Audit Agent（按需，用户手动触发）

- **触发**：用户执行 `/full-audit`
- **写入范围**：`docs/audit-report.md`
- **不触碰**：其他任何文件
- **工作流**：读全部代码 → 多维度审查 → 新发现追加到 audit-report（open）→ 已修复标记 fixed 并删除 → commit
- **Race condition 处理**：
  - 仓库中可能有 Worker 的 worktree 在并行工作
  - 发现问题如果在 backlog 的 `planning`/`doing` 条目范围内，标注"可能正在修复中"
  - 编译/测试失败可能是瞬态，重试一次再判断
  - 跳过 `tests/.tmp_*` 等临时目录
- **列表维护**：
  - 已修复的 item：标 `fixed` 后从表中删除（只在 commit message 里留记录）
  - 与现有 open item 重复的：标 `duplicate` 后删除
  - 检查 backlog 中标 `done` 但仍有残留问题的 item：新开 audit item

### Worker Agent（后台，用户手动触发）

- **触发**：用户指令（"执行下一个 wave"）
- **写入范围**：`compiler/`, `std/`, `tests/`, `CLAUDE.md`, 两个表的状态字段
- **不触碰**：`design.md`
- **工作流**：
  1. 扫描两个表，收集 `queued` / `open` items
  2. 按优先级排序：P0 > Critical open > P1 > Important open > P2 > Minor open > P3
  3. 分析依赖，组成 wave（独立 items 并行，有依赖串行）
  4. 每个 wave：
     a. 将 items 标为 `planning`
     b. **S 复杂度快速通道**（见下方规则）：跳过 c-e，直接在 main 上执行
     c. M/L/XL：用 superpowers:writing-plans 生成实现 plan
     d. **验证 plan 与仓库现状一致**——如果 spec 描述的代码/API/结构与仓库不符，STOP + 告警，不继续
     e. Plan 通过后将 items 标为 `doing`，dispatch subagent 到 worktree 执行
     f. 验证：编译通过 + `npm test` 全过
     g. Merge 回 main
     h. 将 items 标为 `done`，然后从表中删除
     i. 更新 CLAUDE.md 受影响的描述
  5. 发现新 bug → 追加到 audit-report（open），不自行修复
  6. 发现设计问题 → 追加到 worker_feedback.md（`[决策]`，阻塞）；值得用户了解的信息 → 追加（`[通知]`，不阻塞）
  7. 完成后汇报

## 两个排队表

### Backlog（`docs/backlog.md`）

**活的工作看板，不是历史档案。** 做完的条目从表中删除，只在 git commit message 留记录。

**条目格式：**

```markdown
### B-xxx <标题> [类型] [优先级] [复杂度] [状态]

<spec 正文：设计决策、涉及修改、验收标准>
```

字段说明：
- **ID**：`B-` + 三位数字，递增分配
- **类型**：`feature` / `design-align` / `refactor` / `bugfix`
- **优先级**：`P0`（下个 wave 必须）/ `P1`（近期）/ `P2`（排队）/ `P3`（低优先）
- **复杂度**：`S`（< 1h）/ `M`（半天）/ `L`（1-2 天）/ `XL`（多天）
- **状态**：`queued` → `planning` → `doing` → 删除

### Audit Report（`docs/audit-report.md`）

**活的 bug 看板。** 修复后从表中删除。

**条目格式：**

```markdown
### #xxx <标题> [严重度] [状态]

**文件**：涉及的文件路径
**描述**：问题描述
**建议修复**：修复方向
```

字段说明：
- **ID**：`#` + 数字，递增分配
- **严重度**：`Critical` / `Important` / `Minor` / `Style`
- **状态**：`open` → `doing` → 删除

### 列表维护规则

1. **做完即删**：item 完成后从表中删除，不留 `done` 标记占空间
2. **状态及时更新**：Worker 捡起工作立即标 `planning`，开始执行标 `doing`，完成后删除
3. **Audit 参照状态**：审计时看到 `planning`/`doing` 状态的 item 不重复报告
4. **Discussion 参照状态**：讨论时看到 `doing` 的 item 不再修改其 spec
5. **ID 不复用**：删除的 ID 不再分配给新 item（避免 commit message 引用混乱）
6. **长期未动的 `queued` item**：超过 2 周无人认领的 item 由 Discussion agent 在下次对话时提醒用户评估是否降级或取消

## 仓库隔离规则

写入范围隔离，三个 agent 的文件路径不交叉：

| Agent | 写入范围 | 不触碰 |
|-------|---------|--------|
| Discussion | `docs/` | `compiler/`, `std/`, `tests/`, `CLAUDE.md` |
| Audit | `docs/audit-report.md` | 其他所有文件 |
| Worker | `compiler/`, `std/`, `tests/`, `CLAUDE.md`, 两个表的状态字段 | `design.md` |

唯一的写入交叉点：**两个表的状态字段**。Discussion 写新条目，Worker 改状态/删除。由于是不同行的修改，git merge 不会冲突。

Worker 在 worktree 中工作，每个 wave 开始前 rebase 到最新 main（拿到最新的 backlog/audit 状态）。

### S 复杂度快速通道

复杂度标为 `S`（< 1h）的 item 走快速路径，省掉 plan 生成和 worktree 隔离：

1. 跳过 `superpowers:writing-plans`——直接从 backlog spec 执行
2. 不开 worktree——直接在 main 分支上修改
3. 状态直接从 `queued` → `doing` → 删除（跳过 `planning`）
4. 其余规则不变：编译通过 + `npm test` 全过 + rebuild dist/ + 更新 CLAUDE.md

**适用条件**：仅限 `S` 复杂度。如果执行中发现实际复杂度超出 S，停止快速通道，回退到标准流程（开 worktree + 写 plan）。

### Worktree 环境准备

- **LLVM N-API addon 不入 git**：`compiler/llvm-addon/` 是 `.gitignore` 的本地构建产物，新建 worktree 里没有 `.node`。要跑 `npm run test:llvm` 的 worktree agent 必须先 `cd compiler/llvm-addon && node-gyp rebuild`（或 orchestrator 预构建），否则 LLVM 后端差分测试无法运行。dispatch 涉及 LLVM codegen / RC 的任务时在 prompt 里提前提示先 build addon。

### Merge 后 dist rebuild 验 fixpoint

worktree merge 回 main 后重编 `dist/` 时**必须验证 fixpoint**：连续编译两次，第二次产出与第一次 0 diff（double-bootstrap 收敛）才算 rebuild 完成。**不限于数据结构级重构**——Wave 3 曾在非重构 wave 后留下未收敛的 `dist/codegen_llvm*.js`，与下一 wave 改动撞成 merge 冲突。任何 merge 后 rebuild 都要连编两次确认第二次 0 diff，再 amend 进 merge commit。
