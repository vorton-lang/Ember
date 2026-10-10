<!-- 26356 ms -->
**Current goal:** 先插入一个紧急任务，做完再回到 M2 第二部分。任务是让本地检查变快，并控制 target 目录的大小。检查包括 cargo build、test、clippy 和前端测试，target 现在接近 40GB。用户给出的措施只有一条：「debug symbol不要开full，开line table」。其余要执行者自己排查，二进制体积也要一起看。

**Likely current state:** 用户在正常推进，没有收尾的意思，只是被慢检查和磁盘占用影响到了。用户点名了 debuginfo 这一个改动，其余的授权执行者自查，属于「直接做、带结果回来」。

**Evidence:**
- 用户原话「在此之前有个紧急任务」，说明 M2 第二部分要暂停，先做这件事。
- 「现在的检查已经有点慢了，需要优化精简一下」「别的你检查一下」，说明授权范围包括排查和优化，不限于 debuginfo。
- 「二进制体积也要看一下，target现在有快40GB了」，痛点同时有速度和磁盘。
- 23:13 JST，没有「太晚」「先这样」一类的话，不能替用户缩小范围。

**Alternative interpretation:** 「二进制体积」可能主要指 debug/test 产物撑大了 target，属于磁盘问题；也可能指 lobotomyd 的发布体积，也就是要打包进 Electron 的那个。值得说出来的是：如果指发布体积，就会涉及 release profile 的 strip、LTO、opt-level。这些改动可能拖慢构建，和「提速」相冲突。另外，「检查」可能也包括 CI 耗时，不只是本地。

**What would be dangerous to assume:**
- 把「精简」理解成删测试、跳过 clippy、降低检查标准。用户要的是同样的检查跑得更快。
- 改动没有测前后数字。要先测基线：各项检查的冷/热耗时，target 按 debug、incremental、deps、pdb 分项的大小。
- 自行开启 LTO 或 codegen-units=1，让 release 构建变慢，却当成「体积优化」交付。
- 把这次插入扩大成构建系统重构，或借机改 CI 架构。
- 不打招呼就 cargo clean。它是缓存，可以重建，但会触发一次完整重编，要在汇报里说明。
- 做完不汇报就直接回到 M2。

**Next interaction strategy:**
- 不回问，直接做。
- 先测基线。然后把 dev/test 的 debug 改为 `line-tables-only`，按需让依赖用 `debug = 0`。再排查几个方向：
  - Windows 上 pdb 和 split-debuginfo 的影响；
  - incremental 目录膨胀；
  - clippy、test、build 因 feature 或 profile 不一致而重复编译；
  - 依赖树里的重复版本；
  - 前端测试的耗时。
- 汇报时给出前后对照的数字，列出改了什么、为什么改。
- release 体积单独给出数字和建议，不擅自做会拖慢构建的改动。如果 CI 也受影响，要保持一致或注明。
- 其余发现列成后续建议，不顺手做。
- 汇报结束时说明接下来回到 M2 第二部分。
- 用一句话留出纠正入口：「如果你说的二进制体积是指发布包，我再专门看 release 配置。」
