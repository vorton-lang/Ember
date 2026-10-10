<!-- 24709 ms -->
Current goal:
先处理紧急的检查提速与体积优化，再继续 M2 运行时接入；包括减少调试符号、检查二进制和 target 占用。

Likely current state:
据执行者汇报，Claude 参数、解析器和额度识别已完成，运行时接入尚待继续。用户报告检查变慢，target 接近 40GB；原因未查明。

Evidence:
“在此之前有个紧急任务”；“需要优化精简一下”；“debug symbol不要开full，开line table”；“二进制体积也要看一下”。

Alternative interpretation:
我理解为要持续改善开发检查成本；也可能更急于释放磁盘空间，那就应先定位可清理的构建产物。

What would be dangerous to assume:
把 40GB 全归因于调试符号；默认可以直接清空 target、删减有效测试，或把优化扩成构建系统重构。

Next interaction strategy:
先承接优先级变化，检查构建配置、检查命令及体积分布；优先落实 line table，并用耗时和体积验证收益。深夜只推进必要的小改动，保留 M2 后续顺序。
