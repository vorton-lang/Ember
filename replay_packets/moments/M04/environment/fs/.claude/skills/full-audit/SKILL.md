---
name: full-audit
description: Use when user requests a full codebase review, code audit, cross-validation review, or says "审查", "review", "自查". Runs Claude + DS parallel audit, triages findings, writes to audit-report.md. Audit-only — fixes go to Worker via backlog/audit-report.
---

# Audit Agent

全代码库审计。审查当前 main 上的代码，发现 bug 和问题，写入 `docs/audit-report.md`。只审查，不修复。

**工作流规范见 `docs/workflow.md`**

## Trigger

User says: "审查", "review", "自查", "全面检查", "交叉验证", or `/full-audit`.

## 写入范围

- **Bug / 问题** → `docs/audit-report.md`
- **观察 / 非 bug 现象** → `docs/worker_feedback.md`（`[观察]` 类型条目）

**不触碰**：编译器代码、测试、CLAUDE.md、design.md

## Race Condition 处理

仓库中**可能有 Worker agent 在 worktree 中并行工作**。注意：

- Worker 可能正在修改编译器代码并尚未 merge
- 编译或测试失败可能是瞬态（Worker 的 worktree merge 过程中）→ **重试一次再判断**
- 跳过 `tests/.tmp_*` 等临时目录
- 如果发现的问题与 backlog 中 `planning`/`doing` 状态的 item 重合，标注"可能正在修复中"
- 读 `docs/backlog.md` 了解当前 Worker 正在做什么，避免重复报告

## Workflow

### Phase 1: Parallel Audit

**必须派发两个独立 agent 并行审计——这是不可跳过的步骤。**

交叉验证是本审计流程的核心价值：不同模型的知识盲区不同，Claude 擅长类型系统和语义正确性，DS 擅长边界条件和模式匹配遗漏。单模型审计会有系统性盲点，双模型交叉才能覆盖。历史数据表明 DS 独立发现了约 30% 的 critical bug（如 #71、#75、#76）是 Claude 未发现的。

**禁止省略 DS agent。** 即使时间紧张、即使觉得"这次改动很小不需要"、即使 DS 上次没发现什么——都必须派发。审计的价值在于独立视角，不在于每次都有发现。

Dispatch two independent review agents simultaneously:

1. **Claude Agent** (subagent_type: general-purpose, model: opus):
   - Read all compiler source files
   - Check for bugs, type unsoundness, edge cases
   - Verify behavior matches CLAUDE.md and docs/design.md descriptions
   - Test least-surprise principle: would a user be confused by any behavior?
   - Write e2e test cases for suspicious code paths and run them

2. **DS Agent** (via deepseek-dispatch skill, **必须派发**):
   - Independent read-only audit
   - Focus on: missed error handling, unsafe patterns, design-implementation gaps
   - Compare implementation against design.md specification
   - DS 视角独特：更关注具体执行路径、边界条件、模式遗漏，与 Claude 的类型/语义视角互补
   - **必须加 `--disable subagents`**：审计是长任务，sub-agent 会把单长 session 碎片化成多个短 session，破坏 DeepSeek 前缀缓存积累（75-80% → 90%+）。派发示例：
     ```powershell
     deepseek exec --auto --json --disable subagents --model deepseek-v4-pro -p @'
     <audit prompt>
     '@ 2>&1 | Out-File -Encoding utf8 "ds-audit.json"
     ```

Both agents output structured findings (严重度只允许 `critical` / `medium` / `low`):
```
## [severity: critical|medium|low]
### Title
- **File**: path:line
- **Description**: what's wrong
- **Evidence**: code snippet or test that demonstrates
- **Fix**: proposed solution (if trivial) or "needs discussion"
```

### Phase 2: Triage & Merge

1. **Deduplicate**: same finding from multiple agents → one entry
2. **Verify critical findings**: for Critical severity, read code yourself to confirm
3. **Check backlog overlap**: if finding matches a `planning`/`doing` item → skip or note "in progress"
4. **Classify** (严重度 + dispatch):

| Category | 严重度标记 | 写入位置 |
|----------|-----------|---------|
| **Critical** (confirmed bug, 运行时错误/类型不安全) | `[critical]` | audit-report.md |
| **Medium** (definite issue, 非致命但影响正确性/健壮性) | `[medium]` | audit-report.md |
| **Low** (low impact, 代码质量/可维护性/潜在问题) | `[low]` | audit-report.md |
| **Observation** (不算 bug 但值得注意的现象) | — | worker_feedback.md |
| **False positive** | — | 丢弃并说明原因 |

**严重度只允许三级**：`critical` / `medium` / `low`。不使用 Important/Minor/Style 等其他词汇。

5. **标注 dispatch**（每个写入 audit-report 的条目必须标注）：
   - `mechanical`：修复方向唯一确定，spec 能完整描述"改哪里、怎么改"。典型：补递归遍历、加 null check、提取重复代码、补 match 分支。
   - `judgment`：修复涉及设计选择、架构权衡、effect system 推理。典型：重构大文件结构、改变 dispatch 策略、修复 effect 传播。
   - 判断依据：如果给一个不了解项目全局的开发者只看修复描述就能正确实现 → `mechanical`；需要理解项目约定或在多种方案中选择 → `judgment`。

### Phase 3: Update audit-report.md

`docs/audit-report.md` 是**活的 bug 看板**——做完即删。

**格式规则（CRITICAL——Worker 依赖 `grep "\[open\]"` 扫描条目，格式不对 = Worker 看不见）**：

每个条目**必须**是 heading 格式：
```markdown
### #xxx <标题> [严重度] [dispatch] [open]

<问题描述，含文件路径、行号、影响、建议修复方向>

发现者：<agent 名>
```

- **`[open]` 标记不可省略**——没有 `[open]` 的条目 Worker 扫描不到
- **严重度只能是 `critical` / `medium` / `low`**
- **dispatch 只能是 `mechanical` / `judgment`**——Worker 据此决定执行者（DS 或 Claude）
  - `mechanical`：修复方向唯一确定，不需要设计判断（如补递归遍历、提取公共 pattern、加 validation check）
  - `judgment`：涉及设计选择、架构决策、effect system 推理、或多种可行方案需选择
- **禁止使用表格格式**——必须用 `###` heading

**追加规则**：
- 新发现追加到对应分类 section 末尾
- 编号从现有最大编号 +1 继续
- 每个发现标注发现者（如 `Opus`、`DS`、`Opus+DS`）

**清理规则**：
- 检查现有 `[open]` 状态的 item 是否已被修复（grep 代码确认）
- 已修复的：**直接删除整个 heading + body**（不是标删除线）
- 在 commit message 中记录删除了哪些已修复的 item

**格式验证（写入后自检）**：
```bash
# 写入完成后执行，确认所有新条目都能被 Worker 扫描到
grep -n "\[open\]" docs/audit-report.md
```
如果新写入的条目不在输出中，说明格式错误，必须立即修正。

### Phase 3.5: Write Observations to Feedback

不算 bug 但值得注意的现象写入 `docs/worker_feedback.md`：
- 代码异味（不违反规范但不符合直觉）
- 设计-实现微妙不一致（不影响正确性但可能误导读者）
- 潜在改进方向（不是当前阶段的优先事项但值得记录）
- 令人困惑的行为（用户可能被绊倒但编译器行为"技术上正确"）

格式：

```markdown
## Audit 观察报告（日期）

### N. [观察] 标题

**现状**：描述观察到的现象
**为什么值得注意**：为什么不是 bug 但值得关注
```

### Phase 4: Summary

```
## Audit Summary
- 新发现: N 项（X critical, Y medium, Z low）
- 观察: O 项（写入 worker_feedback.md）
- 清理已修复: M 项删除
- 当前 open 总数: K 项
- 需要关注的 critical: (列出)
- audit-report.md 已更新
- 格式验证: grep "\[open\]" 命中 K 项 ✓
```

## Rules

- **Never skip a finding silently.** Every item must be either recorded or explicitly marked as false positive.
- **Never fix in audit session.** Audit = observe + record.
- **Cross-validate critical findings.** For Critical items, verify code yourself before recording.
- **Respect Worker state.** Check backlog for `planning`/`doing` items; don't report issues that are being actively worked on.
- **Clean as you go.** Delete fixed items from the report. The report should only contain open issues.
