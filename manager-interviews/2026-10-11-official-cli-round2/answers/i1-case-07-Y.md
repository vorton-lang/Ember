<!-- 25446 ms -->
Current goal:
先插入一个紧急任务，M2 第二部分暂停。目标有三个：
- 让本地检查（编译、测试、clippy、前端测试）变快、精简；
- 把快 40GB 的 `target` 压下来；
- 顺带看一下二进制体积。

用户提了一个具体手段：debug symbol 从 full 改成 line table，其余让执行者自己检查。

Likely current state:
- 执行者刚宣布要开始 M2 第二部分（运行时启动 Claude），可能还没动手，也可能刚开了个头。
- `b579052` 的 CI 还在跑。
- 本地 `target` 接近 40GB，检查耗时让用户明显感到慢。
- 用户本地时间 23:13 左右，已是深夜。

Evidence:
- 用户原话：「在此之前有个紧急任务，现在的检查已经有点慢了，需要优化精简一下」「debug symbol不要开full，开line table」「二进制体积也要看一下，target现在有快40GB了」。
- 背景写明「检查」指本地的编译、测试、clippy 和前端测试。

Alternative interpretation:
- 「二进制体积」可能指随 Electron 发布的 `lobotomyd` release 产物，而不是 `target` 目录。按这个读法，就要动 release profile（strip、lto、codegen-units），不只是 dev/test profile。
- 「紧急」也可能主要是磁盘快满了，而不是速度问题。那样就该先清理、控制 `target` 的增长，再谈提速。
- 「检查」也可能把 CI 耗时算在内。

What would be dangerous to assume:
- 以为慢只是 debug info 造成的。还可能是链接器、clippy 和 test 之间因 feature 不一致而反复重编、重复依赖、前端测试本身慢。应该先测量（`cargo build --timings`、`target` 各子目录的大小），而不是只改一行配置就交差。
- 用跳过测试、减少 clippy 覆盖来换速度。精简不等于降低检查标准。
- 不经说明就改变运行时行为的设置，比如 `panic=abort`，或 release 下完全去掉调试信息，导致崩溃回溯不可读。line-tables-only 能保留回溯行号，这一点应当确认。
- 默认 `cargo clean` 不用提。它可以重建，但会带来一次全量重编的时间成本，应该说一句。
- 以为 M2 被取消了。它只是延后。
- 以为改了本地 profile 不会影响 CI：缓存键和 CI 的耗时也会变。

Next interaction strategy:
- 让执行者直接动手，不回问：
  - 先测一份基线（检查各步耗时、`target` 各部分大小、release 二进制大小）；
  - dev/test 改为 `debug = "line-tables-only"`，依赖可以考虑 `debug = 0`；
  - 再查链接器、重复编译、feature 统一和前端测试；
  - 检查 release profile 的体积选项。
- 回报时给出改动前后的数字，并对每项改动说明它会不会影响回溯或行为。
- 附一句另一种读法：如果「二进制体积」指发布产物，会一起处理 release profile。
- 考虑到是深夜：这个任务做完、提交、确认 CI 后就收尾，M2 第二部分明确留到明天，不开新话题，不追加问题。
