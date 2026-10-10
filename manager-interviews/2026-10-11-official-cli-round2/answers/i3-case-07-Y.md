<!-- 39846 ms -->
**Brief for Tech Lead:**

此时不派任务。理由如下：

- 用户的原话是"紧急任务""需要优化精简一下"，并已给出第一条具体做法。这是范围窄、能直接量的工程活，先让执行者测量再改，比先做一轮探索更快。
- 现在是用户本地 23:13，我推测用户想尽快看到检查变快，不想再展开讨论。

等执行者交回前后数据和改动后，如果有影响较大的取舍需要判断，再请技术负责人看。可能的取舍：改 release profile、换链接器、引入 nextest 之类的新工具、改 CI 的缓存策略。

---

**Brief for Worker:**

**背景**
- 你当前在做 M2 第二部分（让运行时能启动 Claude）。用户说"在此之前有个紧急任务"，先暂停 M2。
- 未提交的 M2 改动保留，不丢弃，也不混进这次提交。是 stash 还是先单独提交为 WIP，由你选，回报时说明。

**用户明确说过的（原话）**
- "现在的检查已经有点慢了，需要优化精简一下"
- "debug symbol不要开full，开line table"
- "别的你检查一下"
- "二进制体积也要看一下"
- "target现在有快40GB了"

"检查"沿用项目里的含义：本地的 Rust 编译、测试、clippy 和前端测试。

**我的推断（可以不照做，但偏离时要说明）**
- 用户关心三件事：检查的耗时、`target` 占的磁盘、二进制体积。"二进制体积"我理解为主要指 debug 和测试产物把 `target` 撑大；release 发布包的体积，是顺带看一下。
  - 另一种读法：用户指的是发布出去的 `lobotomyd` 和 Electron 包的体积。如果是这样，重点会转到 release profile（strip、lto、codegen-units）。这次先测出 release 的数字，写进回报，方便用户纠正。

**要做的事**

1. **先测基线，再改。**
   - `target` 的总大小，按 profile 和子目录拆开看：debug、release、incremental、deps 下的大头。
   - 全量检查的耗时，分别测从零开始（cold）和改一个文件后（incremental），并拆到每一步：build、test、clippy、前端测试。
   - 主要二进制的体积，包括 debug 和 release。
2. **落实用户点名的这条**：dev 和 test profile 的 `debug` 改为 `"line-tables-only"`。
3. **自己排查其他原因。** 以下只是方向，以实测为准：
   - 依赖的 debuginfo 能否进一步降低（例如 `profile.dev.package."*"`）；
   - 各步骤的 feature 或参数不一致导致重复编译；
   - clippy 和 test 是否各自重复构建；
   - incremental 缓存、旧工具链和旧 profile 残留的体积；
   - 检查脚本里是否有可以并行或去重的步骤；
   - Windows 上链接耗时的占比。

**允许**
- 修改 workspace 的 `Cargo.toml` profile、`.cargo/config.toml`、检查脚本。
- 测完基线后可以 `cargo clean` 或清掉过时的产物。这只是构建缓存，我判断风险低。清之前记下大小。

**不允许**
- 不要靠少跑测试、放宽或关掉 clippy lint、跳过前端测试来提速。覆盖范围不能缩小。
- 本次不改 release profile。release 的优化只测量、写建议。
- 不引入需要另外安装的新工具（nextest、其他链接器、cargo-sweep 等）作为必需依赖。值得用的写进建议。
- 不碰那个 Windows 偶发的慢速滚动测试，除非它挡住了验证。

**完成条件**
- 改动已提交推送，CI 通过；CI 也会用到同一套 profile，要确认它没变慢或出错。
- 测试失败时的 backtrace 里仍有文件名和行号（这正是选 line-tables 而不是关掉 debuginfo 的原因），实际确认一次。
- 回报要简短，用户那边已是深夜：
  - 一张前后对比：`target` 大小、cold 和 incremental 的检查耗时、二进制体积；
  - 改了什么；
  - 没做、留到明天再定的建议，每条一句话，附上预计收益。
- 回报后回到 M2 第二部分。
