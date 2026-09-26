# DeepFusionPoints 系统回顾与改进备忘录

author: 应宇峰

date: 2026/05/12

## 一、系统概述

GPU 加速的实时 TSDF 点云融合系统，替代原有八叉树实现。核心设计为**索引-数据分离架构**：VDB 树索引驻留显存，场数据（ArenaEntry）驻留锁页主机内存，显存中维护数据缓存（Cache）加速访问。

目标硬件：笔记本 GPU（开发机 1660 Ti，出货机 3050 级别），Windows 平台，不可用 Linux。

压测规模：0.1mm 精度扫描 1m 级物体（车），活跃格点约 10^10 量级。

关键特性：程序为 IO 瓶颈（随机访存），非计算瓶颈。30 系笔记本显存位宽不升反降，roofline profile 证实瓶颈在显存带宽。

## 二、原始设计中的合理决策

以下决策经实测验证为合理，无需改动：

### 2.1 VDB Tree 作为索引结构

在 10^10 活跃体素的规模下，flat GPU hash table 的索引本身需要约 36GB 显存（12.5 亿 block × 20B/条 / 0.7 装载因子），远超笔记本显卡容量。VDB 的层次压缩按需创建节点，实际索引开销控制在 1GB 以内。hash table 不可行。

### 2.2 不做两遍法修 data race

insertPointsKernel 中存在 block 间哈希冲突导致的结果随机波动。与+1讨论后确认：TSDF 融合本身有传感器噪声，竞争导致的误差远小于噪声，且无重放需求。两遍法（计数 → prefix sum → scatter）的额外开销在性能刚好够用的情况下会阻塞交付。

### 2.3 不做异步流水线（帧间）

所有 kernel 均为计算密集，GPU SM 已占满。多 stream 帧间重叠无法获得实际收益，只是排队等待。

### 2.4 不做运动向量预取

在最高精度（0.1mm）下，点间距已大于网格间距，激活的 block 天然不连续。按运动方向预取的命中率极低，反而因无效 cache 加载拖累性能。

### 2.5 24 位浮点压缩存储

+1 测试过 16 位精度不满足需求，24 位为精度下限。解码使用按字节拷贝，虽然不如直接 uint32 cast 优雅，但 uint32 cast 在 GPU 上因 3 字节不对齐会导致访存越界/段错误。byte copy 是正确做法，性能差异相对 IO 瓶颈可忽略。

### 2.6 最小化点查询 API

实习末期为隔离 bug、保证交付，接口锁定在最小粒度的点查询。在当时的时间约束下是正确的风险控制。

## 三、改进建议

### P0：Warp 协作批量查询 API

**问题**：当前所有数据访问通过逐点的 `getObjectVal` 接口，每次走完整的 3 级 VDB 树遍历。Phase 2 的 Marching Cubes 需要 2×2×2 邻域查询，被迫拆成 8 次独立调用。

**方案**：在不暴露 VDB 内部结构的前提下，增加批量语义接口：

```cpp
// 批量点查询：实现内部可做 warp 协作遍历
__host__ int batchGetObjectVal(
    const GlobalPosition* positions, int count,
    VoxelEntry* results);

// 邻域查询：实现内部先定位 LeafNode 再局部索引
__device__ void getNeighborhood2x2x2(
    GlobalPosition base, VoxelEntry out[8]);
```

**warp 协作遍历原理**：同一 warp 的 32 个线程的查询可合并——只要目标落在同一棵子树（RootNode 级别），由代表线程做一次树遍历找到 InternalNode，再通过 `__shfl_sync` 广播，各线程在 LeafNode 级分叉。不依赖空间局部性，降低的是每次查找的代价而非命中率。

**预期收益**：Phase 1 和 Phase 2 同时受益。MC 的邻域查询从 8 次独立遍历降到 1-2 次。

### P1：Kahan Summation 替代 FP64

**问题**：部分代码（Eigen 库移植）使用双精度浮点。开发机（1650 Ti）上 FP64 利用率已达 80%。消费级 GPU 的 FP64:FP32 比率持续恶化（Turing 1:32 → Ampere 1:64 → Ada 1:64），新硬件上这部分会成为瓶颈。

**方案**：

- 累加操作使用 Kahan summation（FP32 精度做累加，误差补偿接近 FP64，只加几行代码）：

```cuda
float sum = 0.0f, compensation = 0.0f;
for (...) {
    float y = value - compensation;
    float t = sum + y;
    compensation = (t - sum) - y;
    sum = t;
}
```

- 矩阵运算（位姿变换等）大概率 FP32 直接够用（4×4 刚体变换条件数小），做精度对比测试确认。

- 如有部分操作确实需要接近 FP64 精度，使用 Double-Single (DS) 算术：用两个 FP32 表示一个约 48 位精度的值（Knuth two-sum 算法）。每个 DS 操作约 6-10 条 FP32 指令，但 FP32 吞吐 32-64 倍于 FP64，净加速 3-10x。

**关于 Tensor Core**：不可行。(1) FP16 对的 DS 算术只有约 22 位精度，低于 24 位下限；(2) TSDF 融合是 scatter/per-element 操作，不是 dense GEMM；(3) 开发机 1660 Ti (GTX) 没有 Tensor Core。

### P2：CUDA Virtual Memory API 评估

**动机**：可能简化当前 Cache + HostAllocator swap 机制，减少一级间接访存。

**核心 API**（CUDA 10.2+，driver API）：

```
cuMemAddressReserve()  → 预留虚拟地址（不消耗物理内存）
cuMemCreate()          → 创建物理内存句柄
cuMemMap()             → 虚拟地址 → 物理内存映射
cuMemUnmap()           → 解除映射，虚拟地址保留
```

**Windows 兼容性**：基本的 map/unmap 在 Windows (WDDM) 上可用。不支持的是 GPU 侧自动 page fault（仅 Linux + Hopper+），但当前系统本来就在 host 侧主动管理（preAlloc + swap），这不影响。

**注意事项**：

- 分配粒度为 `cuMemGetAllocationGranularity()` 返回值（通常 2MB），ArenaEntry 远小于此，需要在物理页内做 sub-allocation。
- 这些是 driver API（`cu*`），非 runtime API（`cuda*`），需要正确管理 context。
- 建议在 CUDA 12.x 上做原型验证，稳定性更好。

### P3：辅助优化

**CUDA Graphs**：将单帧处理的 kernel 序列录制为 Graph，后续帧 `cudaGraphLaunch` 回放，消除逐次 kernel launch 的 CPU 侧开销（~5-10μs/次 → ~1μs 总计）。对固定拓扑的处理流程适用。

**Kernel Fusion**：如果 computeFieldDataKernel 和 computeRenderEventKernel 遍历的体素集合高度重叠（均基于 VisibleVoxel），合并成单 kernel 可避免中间结果落地到 global memory。代价是寄存器压力增大，需实测。

**帧内分 Chunk 处理**：单帧数据分 N 个 chunk 串行处理（不是帧间并行），目的是缩小每个 kernel 的工作集使其适配 L2 cache，提升有效带宽。与 CPU 上的 cache blocking 同理。

**内存池支持释放**：当前 bump allocator 不支持释放。可用 atomic lock-free free list 支持回收，`alloc()` 优先从 free list 取，减少长时间扫描的内存浪费。

**序列化压缩**：delta encoding（相邻体素 TSDF 值高度相关）+ 进一步量化 + Zstandard 通用压缩。

## 四、Phase 2 (Marching Cubes) 相关

### 4.1 数据结构适配问题

当前 VDB 数据结构为 scatter（写入离散位置）优化，MC 的 gather 模式（读取 2×2×2 邻域）需要跨 LeafNode 边界时做多次独立树遍历。P0 的批量查询 API 是最直接的改善路径。

### 4.2 Brick 预加载

MC kernel 前对每个活跃 LeafNode 加载其数据 + 6 个面邻居的边界数据到 shared memory 构成 "Brick"，MC 在 Brick 上运行，邻域访问全部本地化。将 N 次随机树查找换为 1 次批量加载 + N 次本地读取。

### 4.3 寄存器溢出

MC 的 256-entry LUT + 复杂分支容易导致寄存器超限。建议：

1. LUT 放 `__constant__` memory（256 条，L1 cache 命中率高，不占寄存器）
2. `__launch_bounds__` 显式控制每线程寄存器数
3. 拆 kernel：先分类（哪些 cube 有表面），再生成几何

### 4.4 Flying Edges 替代方案

Flying Edges (Schroeder et al., 2015) 是 MC 的现代替代，分三个高度并行的 pass（边分类 → 前缀求和 → 生成几何），对寄存器更友好，可能同时解决性能和编译问题。

## 五、关于 Voxel Hashing

**Nießner et al., "Real-time 3D Reconstruction at Scale using Voxel Hashing", SIGGRAPH Asia 2013**

与本系统解决同一问题（GPU 实时 TSDF 融合），使用 GPU hash table 替代树结构。+1 的原型即基于此方案，性能达标但扫描范围不足（无数据卸载到主机内存的机制）。

本系统的核心贡献是**索引-数据分离的分层架构**——索引放显存、数据放主机内存。VDB tree 是索引层的实现选择。理论上 hash table 也可以做索引层（value 存 block_id 而非体素数据本身），但在 10^10 体素规模下 hash table 索引本身约需 36GB，不可行。VDB 的层次压缩在此规模下不可替代。

## 六、CUDA 12.x 新特性（相对项目原 CUDA 11.0）

### 6.1 cudaMallocAsync / Stream-Ordered Memory Pool（11.2+，12.x 成熟）

CUDA 运行时内置流式内存池，分配/释放是 stream 操作，不触发同步。

```cpp
cudaMallocAsync(&ptr, size, stream);  // 不同步、不阻塞
cudaFreeAsync(ptr, stream);           // stream 内释放
```

- 内部自带内存池管理，复用已释放块，减少碎片
- 可设池最大大小，超限时自动回收
- **可简化甚至替代 UMAllocator**——当时手写 preAlloc + bump alloc 就是为了规避 cudaMalloc 的隐式同步，现在 CUDA 自己解决了
- HostAllocator 的锁页内存部分仍需自己管理

### 6.2 Programmatic Dependent Launch（12.3+）

Kernel 可在执行过程中通知依赖方提前启动，无需回 CPU 同步：

```cuda
// Kernel A 中，数据准备完毕后
cudaTriggerProgrammaticLaunchCompletion();
// Kernel A 继续执行剩余工作，同时 Kernel B 已可启动
```

应用场景：insertPointsKernel 写完 VisibleVoxel 后立即触发 computeFieldDataKernel，不等整个 insert kernel 结束。这是帧内 kernel 间的细粒度重叠，不同于帧间异步流水线（已验证无收益）。

### 6.3 CUDA Graphs 条件节点（12.3+）

Graph 中支持设备侧条件分支：

```cpp
cudaGraphConditionalHandle handle;
cudaGraphConditionalHandleCreate(&handle, graph, ...);
// 设备侧代码设置条件值，决定子图是否执行
```

当前流程中的部分分支（锁页内存是否耗尽、是否需要 swap）以前必须回 CPU 判断再 launch，现在可以全部录进 Graph 由设备侧判断。

### 6.4 libcu++（CUDA C++ 标准库）

提供正规的设备侧同步原语，替代手写 atomicCAS 自旋锁 + __threadfence：

```cpp
#include <cuda/atomic>
#include <cuda/barrier>

// 替代手写自旋锁
cuda::atomic<int, cuda::thread_scope_device> lock{0};

// 替代 __syncthreads() + 手动 flag 的同步模式
cuda::barrier<cuda::thread_scope_block> bar;
```

编译器可根据 scope 做更好的优化，且语义更清晰。

### 6.5 Cooperative Groups（持续增强）

Warp 级操作有了更好的抽象，直接支持协作遍历设计：

```cuda
#include <cooperative_groups.h>
namespace cg = cooperative_groups;

auto warp = cg::tiled_partition<32>(cg::this_thread_block());
int result = cg::reduce(warp, value, cg::plus<int>());
// 不再需要手写 __shfl_sync mask
```

### 6.6 CUDA C++ 工程化改善

**Thrust / CUB 替换手写原语**：parallel reduce、prefix sum、compact 等操作有 NV 针对每代架构调优的实现，比手写通常快 10-30%，且无 edge case 风险。

```cpp
cub::DeviceScan::ExclusiveSum(d_temp, temp_bytes, d_in, d_out, n);
thrust::copy_if(d_begin, d_end, d_out, predicate);
```

**RAII 封装 CUDA 资源**：用 unique_ptr + custom deleter 管理显存，RAII 类管理 stream/event，渐进式迁移，新代码用封装，老代码逐步替换。

**Pool Index 替代原始指针**：树节点内部子节点引用全部改用池内 32 位索引（而非 64 位指针），读写通过池的边界检查方法。好处：(1) 索引空间省一半；(2) 跨地址空间传递不失效；(3) debug 模式下越界立即 assert。

**Debug 模式安全机制**：
- Generation tag：每个池分配节点头部加 magic number + generation counter + node_type，读取时验证，定位野指针和 use-after-free
- Canary / Red Zone：每个分配单元前后加 4 字节哨兵值，定期从 CPU 侧扫描锁页内存中的 canary 完整性，定位越界写入

### 6.7 替代语言评估

评估了 Triton、TileLang、CUDA Oxide (Rust) 作为 CUDA C++ 替代方案。结论：**均不可行**。

- **Triton / TileLang**：tile-based 编程模型，面向规则密集计算（matmul/attention），无法表达指针追逐的树遍历、自定义内存管理、warp 级操作，且为 Python 生态难以集成 C++/Qt
- **CUDA Oxide (Rust)**：理论上所有权模型可提供内存安全，但 GPU 编程的核心操作（内存池、原子锁、裸指针）全部需要 unsafe 块，实际安全收益有限；调试工具链缺失（Nsight 不支持 Rust）；PTX/SASS 级优化不可控；Windows 支持为二等公民；团队学习成本巨大

本项目的需求（稀疏树结构、多地址空间内存管理、24 位自定义格式、SASS 级调优）处于 GPU 编程的最底层控制端，所有替代语言都在往高级抽象方向发展，不覆盖此领域。在可预见的未来仍需使用 CUDA C++，通过工程化手段（RAII、pool index、debug canary、Thrust/CUB/libcu++）改善开发体验。

## 七、检索路径备忘

实习时的调研从"OpenVDB GPU 加速"出发，沿 VDB 家族线（NanoVDB → GVDB → fVDB）找到相关工作。Voxel Hashing 出自 SLAM/三维重建社区，关键词为 `real-time 3D reconstruction`、`volumetric fusion GPU`、`TSDF integration`。两个社区解决类似问题但引用网络几乎不交叉。后续调研应同时覆盖两条检索路径。
