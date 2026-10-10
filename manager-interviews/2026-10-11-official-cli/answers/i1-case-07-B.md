<!-- 50017 ms -->
**Current goal:**
在继续 M2 第二部分（运行时接入 Claude）之前，先插入一个紧急任务：让本地「检查」（Rust 编译、测试、clippy、前端测试）变快、变精简，并压缩磁盘占用。用户明确给出的切入点：debug symbols 不要 `full`，改为 line-tables-only；二进制体积要看；`target` 已近 40GB 要处理。其余优化点由助手自行排查。

**Likely current state:**
- 用户已在自己机器上感到检查变慢（主观判断是「有点慢」，不是不能用）；可能刚看了磁盘才发现 target 近 40GB。
- 代码仓库刚推送 `b579052`，CI 在跑；M2 第一部分已完成，第二部分未开始或刚开始，没有未提交的半成品（基于助手上一条「接下来继续」）。
- 过去几天连续多次 Rust 构建（Claude 适配器、解析器、CI 修复）累积了大量增量产物；三个 profile（dev、test、可能 release）和多 feature 组合都在 target 下。
- 这是一个工作日下午（JST 约 23:00+，实际是深夜），用户在收尾前提了这件事。

**Evidence:**
- 用户原话「在此之前有个紧急任务」：明确要求先于 M2 第二部分处理；「紧急」是用户的定级。
- 用户原话给出两条具体技术指令（debug symbol 改 line table；看二进制体积）和一个事实（target 快 40GB）。
- 「别的你检查一下」：明确授权助手自行扫描其他优化点，但没有说改动范围的上限。
- 从历史高置信推断：Rust workspace 四个 crate + Electron 前端，检查慢的主要来源是 Rust 编译和测试链接；此前有「Windows 上的慢速滚动测试」偶发失败，说明测试本身也有慢项。
- 仍不确定：用户的「检查」是指 CI 流程还是本地脚本，还是两者；40GB 是单一 target 目录还是多个 worktree/项目合计。

**Alternative interpretation:**
- 用户可能只是想要一次性的清理 + profile 配置调整，十几分钟搞定，而不是一次深度的编译性能治理（sccache、依赖裁剪、拆 crate、并行测试调度）。「有点慢」「优化精简一下」是轻量措辞。
- 「二进制体积也要看一下」可能是关心发布产物（Electron 打包 + lobotomyd 可执行文件）大小，而非 target 中间产物；两者优化方向不同（release profile 的 strip/LTO/opt-level vs. dev profile 的 debug 设置）。
- 「紧急」可能是因为磁盘快满了影响工作，而不是检查速度本身；这样优先级应是先释放空间，再调 profile。

**What would be dangerous to assume:**
- 不要假设可以直接 `cargo clean` 删 40GB：这是不可逆操作且会导致下一次全量编译耗时很长，用户现在就想「快」。应先分析 target 构成（哪个 profile、哪些旧 hash 产物）再决定清理粒度，或至少先告知再删。
- 不要假设把 debug 改成 line-tables 对所有 profile 都合适：release 用于真实验证和性能基线（M2 第三部分计划内），test profile 需要可读 backtrace，改 debug 级别可能影响崩溃排查。用户只说了方向，没说具体哪个 profile。
- 不要假设「别的你检查一下」授权了大改：引入 sccache/mold/lld、改 CI 矩阵、拆依赖等都会改变构建环境，Windows 上的链接器切换尤其有风险。应当分「低风险立即做」和「需要用户确认」两层。
- 不要假设前端部分不在范围：用户的「检查」历来包含前端测试，node_modules / Vite 缓存也可能占大量空间。
- 不要把这件事做成长期工程而丢掉 M2 的主线：用户说「在此之前」，意味做完要回到 M2 第二部分。

**Next interaction strategy:**
- 立即接手，不追问。先快速测量再动手：target 各子目录体积、Cargo.toml 当前 profile 设置、各 crate 的 dev/test 编译时间（`cargo build --timings`）、最终二进制体积。有数据后再改。
- 分两层给结果：第一层是直接做掉的低风险项（dev/test profile 的 `debug = "line-tables-only"`、`strip`、dev 下依赖 opt-level 调整、清理旧 hash 产物或 `cargo clean -p` 局部清理、前端缓存），每项附前后对比数字；第二层是需要用户点头的（换链接器、sccache、改 CI、release profile 的 LTO/codegen-units）。
- 清理 target 前给出构成和将释放的量，若要全量清理要明说下一次全量编译的代价，让用户决定；如果能在不全量清理的情况下回收大部分空间，优先走这条路。
- 把「检查慢」的瓶颈定位到具体环节（编译、链接、某几个慢测试、前端），而不是泛泛调参；如果是那几个慢速滚动测试在拖，单独指出。
- 完成后把 profile 决策和构建约定写进 notes（和 CI 的 ubuntu-24.04 固定一并记录），然后明确告知「回到 M2 第二部分」。整个任务控制在一次集中处理的范围内，不展开成长期优化计划。
