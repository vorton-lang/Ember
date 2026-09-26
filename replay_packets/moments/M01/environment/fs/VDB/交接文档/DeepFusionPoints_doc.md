# 实时点云生成算法DeepFusion设计文档

## 一、前言

### 1.1 文档变更日志

|时间|版本号|变更人|主要变更内容|
|--|--|--|--|
|2023.8.14|1.0.0|应宇峰|创建及编写|
|2023.8.25|1.0.1|应宇峰|细化HashPool结构描述|

### 1.2 背景及目的

- 该实时点云生成算法用于替换软件现有的八叉树实现，使用GPU加速获得较好的性能，可以支持现有设备在0.5mm分辨率下满帧运行
- 本文档前半部分为概要描述，面向软件开发及测试人员，描述了算法主要逻辑及接口，用于快速了解算法功能与使用；后半部分为核心数据结构具体描述，面向算法开发人员，用于后续优化与开发。

## 二、工程结构

本项目为DeepFusion的点云子模块，工程文件夹中另有网格子模块内容，注意区分
```
├─build             <-- 存放构建产物
│  └─bin
│     └─Release
│         └─data    <-- 测试工程时将data.sf置于此处
├─DeepFusion
│  ├─DeepFusionMesh
│  └─DeepFusionPoints <-- 本项目源码
│ 
├─install           <-- 构建后导出的dll、lib及头文件
└─Test              <-- 工程测试代码，可以离线处理data.sf文件生成点云
   ├─common
   ├─TestMesh
   └─TestPoints     <-- 本项目测试代码
```
使用git进行版本管理，使用cmake构建，构建时platform选择x64，同时需要修改根目录中的CUDA路径和版本为本机对应值。

## 三、算法流程

- 单帧处理流程
    - 算法输入：单帧激光点云数据，见接口数据结构。
    - 算法输出：渲染事件RenderEvent，当帧需要增加、修改、删除的点数据，通过回调函数通知软件。
    - 处理流程：
      
        对于每个激光点
        1. 找到激光点对应的体素位置，在其$3 * 3$的邻域中记录该点数据（认为激光点数据存在噪声，其真实位置可能在邻域中波动）
        2. 将激光点数据散列到单帧哈希池FrameHashPool中，如果发生哈希冲突则仅记录一份数据，同时在VisibleVoxel中建立压缩索引，后续步骤遍历该索引。
        
        对于索引中每个点数据：
        
        3. 使用TSDF算法更新其所在体素的场值、法向

        对于3中更新的每个体素：

        4. 沿法向寻找相邻体素，在满足当前体素场值为负，相邻体素场值为正且两体素法向量同向（即隶属于同一表面，薄壁件情况可能会获得对侧场数据）的条件下，使用线性插值生成渲染点，渲染点编号记录于场值为负的体素中，后续可以更新。

        5. 将渲染点变更（RenderEvent）合并到点云池（m_ver_pool）中，调用软件提供的回调函数更新显示。

## 四、接口设计

接口类为`DeepFusionPoints`

- 初始化/反初始化

|函数名|功能描述|接口原型|参数|返回值|其他|
|--|--|--|--|--|--|
|init|初始化|int init()||int：错误码|
|isInit|是否初始化完成|bool isInit()||bool：是否初始化|
|deInit|反初始化|int deInit()||int：错误码|
|reset|重置内存及参数|int reset()||int：错误码|
|setResolution|设置分辨率|int setResolution(const float& resolution)|resolution：分辨率|int：错误码|
|getResolution|获取分辨率|float getResolution()||float ：分辨率|
|setQualityJudge|是否显示质量判断|int setQualityJudge(const bool& quality_judge)|quality_judge ：是否显示|int：错误码|
|setProcessFinishedCallBack|设置单帧计算结束回调函数|void setProcessFinishedCallBack( PROCESS_FINISHED_FUNC call_back)|call_back ： 回调函数||

- 数据处理

| 函数名                          | 功能描述                             | 接口原型                                                     | 参数                                                         | 返回值                 | 其他 |
| ------------------------------- | ------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ | ---------------------- | ---- |
| process                         | 执行单帧融合处理                     | int process(const PointData* point_data, const int& point_num, const std::vector\<std::vector<int>>& laser_line_size_segment_points, double* camera_pose, bool read_file = false) | point_data : 单帧扫描数据指针<br>point_num : 单帧扫描数据总数<br>laser_line_size_segment_points: 当前数据按激光线分布<br>camera_pose : 当前相机位姿 `double[16]`<br>read_file : false为实时扫描，true为读取数据 | int : 错误码           |      |
| getRequiredMemoryForExtractData | 获取当前导出当前数据所需内存         | int getRequiredMemoryForExtractData(size_t& bytes)           | bytes[out] : 所需内存字节数                                  | int : 错误码           |      |
| getLastErrorMessage             | 获取最后一次错误信息                 | std::string getLastErrorMessage()                            |                                                              | std::string : 错误信息 |      |
| setProtectedArea                | 设置保护区域                         | int setProtectedArea(const PointData* point_data, const int& point_num, bool is_cancel = false) | point_data: 要保护的点数据<br>point_num: 要保护的点个数<br>is_cancel: 是否取消保护 | int: 错误码            |      |
| deleteSelectedArea              | 删除选中区域                         | int deleteSelectedArea(const PointData* point_data, const int& point_num) | point_data: 要删除的点数据<br>point_num: 要删除的点个数      | int: 错误码            |      |
| setFineScanArea                 | 设置精扫区域                         | int setFineScanArea(const PointData* point_data, const int& point_num) | point_data: 要精扫的点数据<br>point_num: 要精扫的点个数      | int: 错误码            |      |
| getVertexNum                    | 获取当前生成点总数（包含已回收部分） | int getVertexNum(int& vertex_num)                            | vertex_num[out]: 网格总数                                    | int: 错误码            |      |
| getUpdateVertices               | 获取当前帧更新的顶点                 | int getUpdateVertices(std::vector<Vertices>& update_vertices) | update_vertices[out]: 更新的顶点数据                         | int: 错误码            |      |

- 导入/导出

|函数名|功能描述|接口原型|参数|返回值|其他|
|--|--|--|--|--|--|
|extractLivePoints|导出实时扫描的模型的原始数据|int extractLivePoints(PointRawData & raw_data)|raw_data[out] : 原始数据|int : 错误码|
|extractFinalPoints|导出扫描校正后的模型的原始数据|int extractFinalPoints(PointRawData & raw_data)|raw_data[out] : 原始数据|int : 错误码|
|saveRealTimeBytesData|将体素数据导出保存|int saveRealTimeBytesData (std::shared_ptr<RealTimeByteStream>& realtime_stream)|realtime_stream[out] : 导出的体素|int : 错误码|
|loadRealTimeBytesData_points|将体素数据导入|int loadRealTimeBytesData_points (const std::shared_ptr<RealTimeByteStream>& tsdf_stream, PointRawData & raw_data)|tsdf_stream : 导入的体素<br>raw_data[out] : 导出的原始数据|int : 错误码|

## 五、数据结构设计

|名称|功能描述|驻留内存区域|管理内存区域|
|--|--|--|--|
|GlobalPostion|空间体素全局坐标，包含三维坐标（整数），精扫等级，薄壁件数据区分位|||
|FieldData|TSDF场数据及相关辅助数据，采用了24位浮点数压缩存储，需要通过getter/setter读写|||
|VoxelEntry|场数据在项目内部的标准交换格式，除计算相关逻辑外均不需要访问内部FieldData|||
|ArenaEntry|场数据在内存池中的存储格式，包含$2*2*2$立方体内的八个体素的数据|主机内存||
|HashFunc|辅助类，提供基于Fnv_1a的哈希实现|||
|HashPool|TSDF场数据池，提供用GlobalPosition查询体素的抽象，实际实现为VDB Tree|统一内存|
|VDB Tree|提供单一分辨率的体素池实现|统一内存|设备内存|
|VDB Node （RootNode, InternalNode, LeafNode）|VDB Tree各层节点|设备内存|
|HostAllocator|锁页内存内存池，用于分配ArenaEntry，提供场数据的点查询和遍历，实现了锁页内存不足时交换到非锁页内存的功能|统一内存|主机内存|
|UMAllocator|显存内存池，分配VDB Node所需显存|统一内存|设备内存|
|Cache|驻留在显存中的场数据缓存|统一内存|设备内存|
|FrameHashPool|单帧场数据哈希存储及其压缩索引|主机内存|设备内存|
|DeviceParams|GPU流程IO相关，包含PointData拷贝到显存时存储空间，渲染事件（RenderEvent）存储空间和渲染点编号（RenderId）池，均位于显存|主机内存|设备内存|
|ObjectPool\<Vertices>|渲染点数据池，位于主机内存|主机内存|主机内存|
|GPUFusionImpl|接口实现类|主机内存

## 六、内部接口设计

|名称|函数类型|功能描述|是否与实现耦合|备注|
|--|--|--|--|--|
|getObjectVal|device|使用GlobalPosition索引获取VoxelEntry|否|
|setObjectVal|device|向GlobalPosition所指位置写入FieldData|否|
|allocBlock|device|为GlobalPostion所指位置所在$2*2*2$块分配内存|否|
|preAlloc|host|预分配内存供HashPool在设备侧使用|否|
|batchSetSubLevel|host|对所给点集设置精扫层级|否|
|batchSetProtected|host|对所给点集设置保护|否|
|batchDelete|host|删除所给点集|否|
|insertFieldData|host|批量插入场数据|否|
|pinned_mem_exausted|host|锁页内存是否耗尽|是|
|max_block_id|host|当前内存池分配的最大块号|是|用于遍历内存池|
|getEntry|host|返回块号对应的ArenaEntry|是|用于遍历内存池|
|getVoxelId|host|返回GlobalPosition对应体素所在的ArenaEntry|是|用于遍历内存池|
|flushCache|host|将缓存内容全部刷回内存|是|

## 七、算法实现
- 单帧处理流程
    - 点插入
      
        将PointData数组拷贝至显存，调用insertPointsKernel将其散列至FrameHashEntry，同时在VisibleVoxel中建立压缩索引，后续遍历VisibleVoxel即可。Kernel同时检查精扫层级和薄壁件，设置GlobalPostion中的sublevel和another，为对应体素分配内存。

        insertPointsKernel启动参数：
        - grid_size：处理所需batch数，每个batch处理INSERT_POINT_BATCH_SIZE个点
        - thread_size：dim3(n,n,n)，n为需要扩展的邻域边长（一般为3）
    
    - 计算场值

        遍历VisibleVoxel，将FrameHashEntry中的数据累加到对应体素，更新场值并计入VisibleVoxel中。
        如果锁页内存已满，需要预先空调用一遍getObjectVal，然后调用swap将不在锁页内存中的块换入。
    
    - 计算渲染事件

        遍历VisibleVoxel，对于场值为负的体素，沿其法向量寻找最近邻居，若邻居场值为正，则可线性插值得到一个渲染点，将所有的渲染点新增/更新/删除汇总到DeviceParams中的render_event_dev。
    
    - 提交渲染事件

        将render_event_dev拷贝回主机内存传递给异步线程，后者将更改同步到总渲染点池（ObjectPool）中，将单帧render event vector提交到m_render_events队列中给软件调用。

- 启动、停止流程
  
    启动只需递归调用各结构的init()方法，init()后可以调用loadFieldData()从磁盘加载已有的场数据。

    停止时通过host_process()进行数据校正，saveFieldData()用于将当前所有场值导出到磁盘。

- 设置精扫、保护、删除区域

    调用对应的batch方法即可。

## 八、HashPool结构

![1.drawio](assets/1.drawio.svg)

HashPool对外表现为`HashMap<GlobalPosition, T>`，拥有八个不同分辨率的无限大网格空间，基础结构为VDBTree，对应单分辨率无限大网格空间。为了提供虚拟内存抽象，API设计为读写分离，无法获取内部指针。HashPool对于内部数据的读写不做并发保护，由外部自行控制。

- HostAllocator

    负责主机侧内存分配，包括锁页内存和交换内存。主机侧存储数据为场值，存储单位为ArenaEntry。内存分配方式为bump alloc，`next_memory_id`指向下一块可用内存，采用原子操作保证该指针的一致性。HostAllocator仅可分配一种大小的内存，每次调用`alloc()`方法分配一块。调用`alloc()`后可获得分配的内存的id，可以通过`getEntryVal()`和`setEntryVal()`读写这块内存，注意读写的粒度是`VoxelEntry`，和分配的粒度不同。

    HostAllocator在设备侧分配内存依赖于`preAlloc()`方法在主机侧提前预留的内存，每次开始处理前需要调用`preAlloc()`来保证有足够的空闲内存可以用于分配。内部的内存被组织为一个二维数组，当检测到空闲内存行数量小于临界值时会进行分配。类静态常量中有关于HostAllocator的一系列参数可以控制预分配行为。

    当锁页内存耗尽时，HostAllocator的`pinned_memory_exhausted`标志将被置为`true`，此时调用`alloc()`获得的内存块将不再对应物理内存，读写这些块的请求可能失败（`ec == EC_PAGE_FAULT`），HostAllocator会记录这些失败的请求，在下次调用`swap()`时将对应的内存块交换进锁页内存。

- UMAllocator

    负责设备侧内存分配，同样使用`preAlloc()`在主机侧提前预留显存然后在设备侧分配，`alloc()`可以指定分配的字节数。因为分配的内存不定长，在每个预分配内存块的末尾可能存在碎片，目前每行碎片大小仅为10KB左右，不进行处理。

    目前只有`InternalNode`和`LeafNode`使用该分配器分配（`RootNode`内嵌在`VDBTree`中）。

- VDBTree

    对外提供的抽象为无限大固定分辨率网格。每个`RootNode`对应边长为`RootLength`大小的一个立方空间，当该块中任意节点被使用时创建，根据其基准坐标Hash到`RootNodeArray`中。`RootNode`指向一个`InternalNode`数组，其中的每个`InternalNode`对应`RootNode`管理的空间的一个子块，`LeafNode`再对`InternalNode`的空间进行细分。具体细分倍率由`VDBDef.h`中的参数控制。

    查找时逐层细化，最终进入LeafNode获得block_id，然后从内存池中取出对应块。

    HashPool里一共有8棵VDBTree，对应不同的精扫层数和薄壁件。

- Cache

    数据缓存，粒度为`VoxelEntry`，为了稳定性实现的接口比较简单，需要外部控制缓存行为。其实就是一个固定大小的带并发保护的哈希表。点模式实现里为了压缩大小对数据进行了部分重叠，网格模式`CacheEntry`的表示应当根据其数据大小确定。

停止处理时为了访问到所有数据（包括交换内存）提供了一组Host侧API，暴露了内部实现，需要手动查树获得block_id，然后从HostAllocator中取出对应的数据。

## 九、注意事项

- VDB_DEBUG宏开启后会打印调试信息，包括VDB Tree根节点填充率，缓存命中率、填充率，内存池填充率，占用内存、显存大小。发布时应关闭该宏。

- CUDA Unified Memory在多流下可能出现bug

- ~~当前单帧处理流程中的耗时热点为computeFieldDataKernel，后续优化可以从此处着手~~

- 对于设置精扫、保护、删除区域，理论上这些方法操作的体素都是已经分配过的，如果有未分配体素函数内部会为其分配内存，此时需要注意如果预分配内存不足会导致分配失败卡死在核函数里。

- 序列化数据结构：序列化数据可视为`vector<FieldDataBlock>`，每个block结构形如`(FieldDataBlockHeader, FieldData, FieldData, ...)`，一个Header后接1-8个FieldData，仅记录可以生成场值（`field_computed == true`）的体素，header中记录了后接FieldData数量。