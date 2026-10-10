<!-- 17251 ms -->
Current goal:
先暂停 Claude 运行时接入，优先优化本地检查的耗时与产物体积。用户明确提出 debug symbols 从 full 改为 line tables，并要求检查其他可精简项及二进制大小。

Likely current state:
M2 适配器参数、解析及额度识别已完成；运行时接入尚未完成。用户观察到检查变慢、target 接近 40GB，但具体耗时和空间构成仍未知。

Evidence:
“在此之前有个紧急任务”明确调整优先级；“别的你检查一下”要求主动调查；“二进制体积也要看一下”说明目标同时包含检查效率与磁盘占用。

Alternative interpretation:
用户可能主要想减少开发构建的调试信息和重复产物，而非削减测试覆盖；也可能存在重复检查、构建配置或缓存累积的问题，尚不能确定。

What would be dangerous to assume:
不能把 target 的 40GB 等同于最终二进制大小，也不能认定 debug symbols 是唯一原因。不能擅自删除 target、停掉重要检查或牺牲必要的调试能力；原定 M2→M3 路线并未取消。

Next interaction strategy:
简短确认紧急任务已置顶，先调查各检查耗时、构建配置和 target 空间分布。将 line tables 作为明确方向，按证据提出并实施最小优化，用前后耗时与体积说明效果；需要清理产物或降低检查覆盖时单独明确范围。
