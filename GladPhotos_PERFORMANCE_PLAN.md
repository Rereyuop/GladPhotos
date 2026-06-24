# GladPhotos 对标 macOS「照片」性能与网格重构计划

> 目标：在不破坏现有照片库、外部文件夹、选择、删除、日期导航、识别标签和详情页功能的前提下，将 GladPhotos 从“Cell 出现后即时加载的图片网格”升级为“有索引、有预热、有分级缓存、有稳定布局快照的 macOS 图库管线”。

## 1. 审计结论

当前代码已具备懒加载、有限并发、ImageIO 缩略图、PhotoKit 缓存管理器等基础，但尚未形成专业图库需要的完整数据与渲染管线。

核心差距不是单一 API，而是以下链路尚未闭环：

`文件变化 → 增量索引 → 布局快照 → 可视范围/预热范围 → 分级缩略图 → 内存与磁盘缓存 → Cell 稳定复用 → 详情页共享资源`

现状更接近：

`全量扫描 → 主线程分组 → 多层 LazyVGrid → Cell onAppear → 精确像素解码 → Cell onDisappear 取消`

---

## 2. 新发现的问题清单

### P0：正确性与数据语义

- [ ] **外部照片日期并非真实拍摄日期**  
  `ExternalMediaItem.displayDate` 使用文件系统 `creationDate ?? modificationDate`，没有优先读取 EXIF/QuickTime creation date。微信保存、拷贝、恢复备份后，照片会被分到错误日期。

- [ ] **扫描排序和页面排序方向互相抵消**  
  `ExternalMediaScanner` 先按修改日期倒序，`ExternalMediaGridView.setItems` 又按显示日期正序重排。重复排序增加成本，也让“最新照片位置”语义难以维护。

- [ ] **Live Photo 配对规则容易误配**  
  当前仅按“同目录 + 同 basename + MOV”配对。不同来源但重名的 HEIC/MOV 可能误配；部分真实 Live Photo 文件名不完全一致时会漏配。长期应读取 Apple asset identifier 元数据完成确认。

- [ ] **文件 URL 被当作永久身份**  
  `ExternalMediaItem.id == URL`。重命名或移动后，同一照片会被视为删除后新增，选中状态、标签、详情位置和缓存身份全部丢失。应优先使用 file resource identifier，必要时辅以内容指纹。

- [ ] **删除后缩略图与标签没有立即统一失效**  
  删除只修改扫描缓存和页面数组；内存缩略图、识别记录、详情页引用可能保留到自然淘汰。

- [ ] **最终高清加载失败会被低清图掩盖**  
  preview 成功后 final 失败，`didFinishLoading = image != nil`，Cell 会永久显示低清且不暴露失败状态。

- [ ] **视频 0 秒首帧可能是黑场**  
  `AVAssetImageGenerator.image(at: .zero)` 对带片头、关键帧延迟或黑场的视频可能得到黑图。应设置容差并尝试 0、0.1s、视频短百分位等候选时间。

### P1：滚动与布局

- [ ] **“原比例”不是瀑布流**  
  多个 `LazyVGrid` 仍按行排布，高竖图会影响整行，无法让下一张补到较短列。

- [ ] **每个日期创建一个独立 LazyVGrid**  
  日期越多，布局上下文越多。网格尺寸变化、信息显示、标签变化会触发多个 Section 重新测量。

- [ ] **Cell Geometry 驱动加载，形成布局—请求反馈循环**  
  宽度每变化 1pt 即取消并重新请求；窗口缩放、侧边栏变化和 adaptive 列宽都会放大抖动。

- [ ] **请求尺寸没有档位量化**  
  622px、625px、631px 会成为三个缓存 key，造成重复解码和缓存碎片。

- [ ] **布局使用 `.adaptive(minimum:maximum:)`，列宽不稳定**  
  允许宽度在 1–1.5 倍范围浮动，使同一缩放级别仍产生大量实际 Cell 宽度。

- [ ] **媒体信息和识别标签改变 Cell 高度**  
  打开信息后整个网格纵向重排。专业图库应固定 Cell 外框，信息覆盖显示或使用固定高度元数据区。

- [ ] **自动滚到最底部可能强迫大网格提前布局**  
  首次加载通过最后一个 Cell ID 定位。大型嵌套网格中，这可能造成明显首屏阻塞。

- [ ] **日期联动依赖 PreferenceKey 汇总所有可见 Section offset**  
  快速滚动时会频繁构造和合并 `[Date: CGFloat]` 字典，并触发顶层状态更新。

- [ ] **选择状态位于父级 Set，单次切换可能扩散到整片网格**  
  即使 Cell 使用 `.equatable()`，父级仍需重新构建所有可见 Cell 参数；批量选择时更明显。

- [ ] **Hover 产生额外状态和动画更新**  
  每个 Cell 都有独立 `isHovering`，快速移动鼠标时产生连续 SwiftUI diff。应确保 Hover 不触发图片子树或布局变化。

### P1：缩略图与缓存

- [ ] **没有真正的预热窗口**  
  外部图库仅在 `onAppear` 请求；PhotoKit 虽提供 start/stop caching 方法，但需确认是否按可视区域前后批量更新，而非逐 Cell 被动调用。

- [ ] **两阶段加载无条件发生**  
  每个 Cell 可能先解码 320px，再解码最终尺寸；快速滚动时大量 final 工作没有可见收益。

- [ ] **共享请求没有订阅计数**  
  相同 key 虽能共享 Task，但任一 Cell `onDisappear` 会直接取消底层任务，可能误伤详情页或另一个消费者。

- [ ] **文件夹 View 消失会取消整个文件夹全部请求**  
  若详情覆盖层、导航动画或其他视图仍使用相同服务，可能出现竞态取消。

- [ ] **内存缓存只有精确 key 查询，不能复用较大缩略图**  
  已缓存 640px 时，请求 480px 仍可能重新解码。

- [ ] **旧版本缓存依靠淘汰，不主动清理**  
  修改时间进入 key 能避免读到旧图，但旧 key 仍占内存，直到 NSCache 自行淘汰。

- [ ] **缓存成本估算可能不准确**  
  通过 NSImage representations 的像素估算，未必代表实际解压驻留内存；多 representation 图片可能低估或重复估算。

- [ ] **没有磁盘缩略图缓存**  
  每次冷启动都重新解码 HEIC、PNG 和视频首帧。

- [ ] **视频缩略图与静态图共享同一个并发闸门**  
  视频生成通常更慢，4 个视频请求可能占满全部 permit，阻塞当前可视静态图片。

- [ ] **ThumbnailDecodeGate 无优先级和可视距离排序**  
  等待者存于字典，不能保证“当前屏幕中心 > 屏幕边缘 > 预热区”的顺序。

- [ ] **每张缩略图输出 PerformanceLogger**  
  Debug/Xcode 环境中会产生可观测的日志开销和控制台噪音。

### P1：系统照片库

- [ ] **照片文件大小通过读取完整资源数据累计字节数**  
  `PHAssetResourceManager.requestData` 会把资源内容逐块读完，仅为了获得大小。显示大量照片信息时会造成极重 I/O，iCloud 资源还存在不可用或网络语义问题。

- [ ] **PhotoKit 缩略图目标尺寸以 `NSScreen.main` 计算**  
  多显示器或窗口跨屏时，主屏 backing scale 不一定等于当前窗口 displayScale。

- [ ] **PhotoKit 请求使用 `isNetworkAccessAllowed = false`**  
  iCloud-only 照片会保持空白/失败，但界面目前缺少明确“需要下载”状态。

- [ ] **opportunistic 回调未显式处理 degraded/cancel/error 状态**  
  缩略图可能多次回调；当前主要依靠 identifier 防串图，但没有完整的加载状态机。

- [ ] **资源大小缓存没有容量和跨启动持久化策略**  
  当前进程内字典会持续增长，退出后又全部丢失。

### P1：扫描、文件监听与索引

- [ ] **FSEvents 事件细节被全部丢弃**  
  回调忽略 paths、flags 和 IDs，只触发 500ms 后全量扫描，无法做增删改的增量处理。

- [ ] **FSEventStream 在主队列交付**  
  回调很轻，但大量文件变化仍会给主线程制造事件压力；更适合专用串行队列归并后再提交 UI 更新。

- [ ] **没有处理事件丢失、RootChanged 等状态**  
  需要根据 flags 判断何时增量更新、何时必须全量校验或重新授权。

- [ ] **每次进程重启都重新扫描和读取像素尺寸**  
  内存扫描缓存无法跨启动。

- [ ] **扫描只按扩展名识别媒体**  
  扩展名错误或无扩展名文件会遗漏；更可靠的是结合 UTType/content type。

- [ ] **支持格式有限且错误提示写死**  
  TIFF、GIF、RAW 等系统可读格式未纳入；后续应由能力探测生成支持列表，而不是 UI 文案硬编码。

- [ ] **EXIF、方向、拍摄日期被分散读取**  
  扫描阶段只读像素尺寸，后续识别/详情可能再次打开同一文件。应一次解析轻量元数据并入索引。

- [ ] **月缓存、日分组、图片列表存在多份大数组**  
  `items`、`itemsByMonth`、`daySections`、`undatedItems`、`imageItems`、筛选数组会重复持有引用和反复分配。

### P2：架构与维护

- [ ] **ExternalMediaGridView 职责过多**  
  同时负责扫描、监听、缓存恢复、过滤、分组、滚动、删除、识别、选择、导航和详情展示。

- [ ] **外部图库和系统图库有两套相似但不一致的缩略图生命周期**  
  后续修复容易只改一边，导致行为分叉。

- [ ] **使用标题字符串参与显示模式身份比较**  
  `displayMode.title` 被用于 Equatable 和 requestID。标题属于 UI 文案，不应承担稳定业务身份。

- [ ] **URL/Date 直接作为滚动 ID，时区或文件变化后稳定性不足**。

- [ ] **当前 benchmark 无法证明真实滚动帧率**  
  需要 Instruments 的 SwiftUI、Time Profiler、Core Animation、Allocations、File Activity 数据，而不是只测扫描函数耗时。

---

## 3. 目标架构

### 数据层

- `MediaIdentity`：稳定 file ID / PhotoKit localIdentifier。
- `MediaRecord`：路径、类型、拍摄日期、修改日期、尺寸、方向、时长、Live Photo 关系。
- `MediaIndexStore`：SQLite 或 Core Data，负责跨启动索引和增量更新。
- `MediaChangeSet`：added / removed / modified / moved。

### 布局层

- `MediaGridSnapshot`：后台生成不可变 Section 和 Item 快照。
- `GridLayoutMode`：square / justified / masonry（明确区分，不混称）。
- `ThumbnailTier`：160 / 240 / 320 / 480 / 640 / 960 / 1280。

### 图片层

- `ThumbnailRequestBroker`：请求合并、订阅 token、优先级、取消引用计数。
- `MemoryThumbnailCache`：可复用大于目标的邻近档位。
- `DiskThumbnailCache`：跨启动缓存、版本化 key、LRU 清理。
- `ViewportPreheater`：可视区 + 前后预热区，滚动速度决定预热距离。

### UI 层

- SwiftUI 保留工具栏、侧栏、空状态、详情覆盖层。
- 核心网格先尝试单一 SwiftUI Layout；达到门槛后再评估 `NSCollectionView + DiffableDataSource`。

---

## 4. 分阶段实施

## Phase 0：建立性能基线（必须先做）

### 工作

- [ ] 新建 `PerformanceScenario`：1k、10k、50k 媒体。
- [ ] 数据集包含 JPG、HEIC、超大 PNG、MOV、Live Photo、损坏文件、iCloud-only 系统照片。
- [ ] 用 Instruments 记录：首次首屏、快速连续滚动、窗口缩放、切换月份、显示信息、打开/关闭详情、批量删除。
- [ ] 记录冷启动和热启动两组。

### 基线指标

- 首个可交互 UI 时间。
- 首屏缩略图 P50/P95。
- 快速滚动期间平均 FPS、最长 hitch。
- 主线程单次阻塞峰值。
- 缩略图重复解码次数。
- 峰值内存和滚动回落后的稳定内存。
- 冷启动磁盘读取量。

### 验收

- [ ] 输出 `PERFORMANCE_BASELINE_V2.md`。
- [ ] 每个优化 PR 都与同一数据集对比。

---

## Phase 1：止血修复（不改整体架构）

### 工作

- [ ] 请求尺寸改为固定 ThumbnailTier。
- [ ] Cell 宽度变化只有跨 tier 才重载。
- [ ] preview / final 使用独立状态。
- [ ] final 失败保留 preview，但标记可重试，不冒充高清完成。
- [ ] 视频首帧增加候选时间和黑图检测。
- [ ] 请求取消改为 token + 订阅计数。
- [ ] 静态图和视频使用独立并发队列。
- [ ] 滚动中只允许 preview；停止 150ms 后升级当前可见 final。
- [ ] 移除逐张普通日志，改为 signpost/聚合。
- [ ] `displayMode` 使用 enum raw value，不使用 title。

### 验收

- [ ] 窗口缓慢缩放时，同一 Cell 每个 tier 最多解码一次。
- [ ] 快速滚动后不再出现大量排队 final 请求。
- [ ] 一个 Cell 消失不会取消详情页同图请求。
- [ ] 视频黑首帧比例明显下降。
- [ ] 低清永久停留问题消失。

---

## Phase 2：稳定网格与瀑布流语义

### 决策

先定义产品要的究竟是哪一种：

1. `Square Grid`：官方图库常用的高密度统一裁切网格。
2. `Justified Rows`：每行等高、宽度按比例分配，接近照片浏览器专业布局。
3. `Masonry`：真正短列补位瀑布流。

不再把“LazyVGrid 原比例”称作瀑布流。

### 工作

- [ ] 先将多个日期 `LazyVGrid` 合并为单一布局数据源。
- [ ] Section 标题作为布局 supplementary item，而非每段嵌套 Grid。
- [ ] GridSnapshot 在后台构造。
- [ ] 信息和标签使用 overlay 或固定高度区域。
- [ ] 日期高亮只观察少量锚点，避免每帧汇总所有 Section 字典。
- [ ] 选择状态改为按 item 精确更新。
- [ ] 初始定位优先恢复 scroll anchor，而不是强制滚至最后一个 Cell。

### 验收

- [ ] 切换“显示信息”不引发整库大范围高度抖动。
- [ ] 10k 项切换月份主线程无明显长任务。
- [ ] 日期高亮滚动稳定，不在相邻日期间抖动。
- [ ] 窗口 resize 不频繁闪白或重新出现 ProgressView。

---

## Phase 3：可视范围预热与分级缓存

### 工作

- [ ] 建立可视 item 集和预热 item 集。
- [ ] 根据滚动方向提高前方预热距离，降低后方距离。
- [ ] 快速滚动只预热低 tier；减速后提升质量。
- [ ] PhotoKit 使用 `PHCachingImageManager` 批量 start/stop caching。
- [ ] 外部媒体通过 RequestBroker 批量提交优先级请求。
- [ ] 缓存允许 640px 服务 480px 请求。
- [ ] 详情页优先复用网格较大缓存，再升级到屏幕级预览。

### 验收

- [ ] 正常滚动时新进入屏幕的 Cell 大部分直接命中缓存。
- [ ] 快速反向滚动不会持续加载错误方向的大批图片。
- [ ] 重复来回滚动相同区域，解码次数接近零增长。

---

## Phase 4：持久化媒体索引

### 工作

- [ ] 建立 SQLite/Core Data schema。
- [ ] 保存稳定身份、路径、文件元数据、EXIF 拍摄日期、像素尺寸、方向、时长和配对关系。
- [ ] 启动先读取数据库快照，立即显示上次结果。
- [ ] 后台核验目录变化，再 diff 发布。
- [ ] 重命名/移动优先通过 file identifier 匹配。
- [ ] 标签记录绑定稳定 media ID，不绑定路径字符串。

### 验收

- [ ] 10k 图片热启动无需重新读取每张图片像素元数据。
- [ ] 文件重命名后标签和选中身份仍可延续。
- [ ] 仅新增一张图片时，不全量重建所有媒体记录。

---

## Phase 5：磁盘缩略图缓存

### 工作

- [ ] 缓存目录使用 `Library/Caches/GladPhotos/Thumbnails`。
- [ ] key 包含 media ID、修改版本、tier、渲染版本和色彩策略。
- [ ] 原子写入，损坏缓存可自动回退重建。
- [ ] 建立 LRU / 总容量 / 最老访问时间清理策略。
- [ ] 图片修改或删除时精确失效。
- [ ] 视频首帧和静态图使用统一缓存接口。

### 验收

- [ ] 第二次冷打开同一文件夹，首屏主要命中磁盘缓存。
- [ ] 应用升级渲染规则后，可通过版本号整体失效旧缓存。
- [ ] 删除源文件后不残留永久孤儿缓存。

---

## Phase 6：FSEvents 增量更新

### 工作

- [ ] 保留事件 paths、flags、event IDs。
- [ ] 在专用串行队列归并事件。
- [ ] 生成 added / removed / modified / renamed change set。
- [ ] 仅对变化媒体重读元数据和失效缩略图。
- [ ] 遇到 MustScanSubDirs、UserDropped、KernelDropped、RootChanged 时执行安全全量校验。

### 验收

- [ ] 新增/删除单张图片时，UI 增量更新且滚动位置保持。
- [ ] 大批拷贝期间不会每 500ms 重扫整个目录。
- [ ] 文件夹被移动或权限失效时给出正确状态。

---

## Phase 7：系统照片库专项

### 工作

- [ ] PhotoKit targetSize 改用当前环境 displayScale。
- [ ] 完整处理 degraded、cancelled、error、inCloud 状态。
- [ ] 为 iCloud-only 照片提供明确占位和用户触发下载策略。
- [ ] 停止为显示文件大小读取完整资源数据。
- [ ] 文件大小改为按需、低优先级、可取消；评估仅在详情页显示。
- [ ] 资源大小缓存设置容量和持久化规则。

### 验收

- [ ] 打开“显示信息”不会触发大量完整资源读取。
- [ ] 多显示器切换后缩略图清晰度正确。
- [ ] iCloud-only 资源状态可理解，不表现为永久加载失败。

---

## Phase 8：是否迁移 NSCollectionView 的决策门

只有满足以下条件才迁移：

- 已完成 tier、预热、索引、磁盘缓存和后台 snapshot。
- 关闭图片解码后，10k/50k 数据仍主要耗时于 SwiftUI layout、AttributeGraph 或 body diff。
- 快速滚动 hitch 仍达不到目标。

### 若迁移

- `NSCollectionViewDiffableDataSource`
- 自定义 `NSCollectionViewLayout`
- supplementary section header
- item reuse + represented identity 校验
- SwiftUI 通过 `NSViewRepresentable` 包装

### 不迁移的情况

如果 Instruments 表明主要瓶颈仍是解码、文件 I/O、视频首帧、资源大小或全量扫描，迁移 CollectionView 不会解决根因。

---

## 5. 建议 PR 拆分

1. `perf/thumbnail-tier-and-state`
2. `perf/request-broker-cancellation`
3. `perf/scroll-aware-quality`
4. `perf/grid-snapshot`
5. `perf/viewport-preheating`
6. `feat/media-index-store`
7. `feat/disk-thumbnail-cache`
8. `perf/fsevents-incremental`
9. `perf/photokit-resource-info`
10. `experiment/collection-view-grid`

每个 PR 必须：

- 保持功能等价。
- 附 Instruments 对比。
- 写明内存变化。
- 提供回滚点。
- 不把多项结构性改动混在一次提交。

---

## 6. 最终体验目标

- 冷启动先显示上次图库快照，不出现长时间空白扫描页。
- 热启动 10k 项接近即时恢复。
- 正常滚动时缩略图在进入屏幕前已经准备好。
- 快速甩动时优先保证跟手，不争抢高清解码。
- 停止滚动后当前屏幕迅速升级清晰度。
- 改名、移动、增删文件不会让整个图库闪动或跳回顶部。
- 切换显示信息、选择、标签不会让整片网格重新排版。
- 详情页和网格共享图片结果，不重复解码、不互相取消。
- “方格 / 等高行 / 真瀑布流”有明确且稳定的布局定义。

---

## 7. 第一轮 Codex 执行范围

第一轮只做 Phase 0 + Phase 1，不要直接上数据库、磁盘缓存或 NSCollectionView。

### Codex 指令摘要

```text
先建立真实 Instruments 基线，然后小步修复缩略图请求管线：

1. 请求尺寸量化为固定 tier；只有跨 tier 才重载。
2. preview/final 分离状态，final 失败不得冒充完成。
3. 请求共享改为订阅 token 和引用计数取消。
4. 静态图片与视频使用独立并发限制，并支持优先级。
5. 滚动中仅加载 preview，停止约 150ms 后升级可见项。
6. 视频首帧不能只取 0 秒，增加候选时间与黑图检测。
7. 移除逐张普通日志，改 signpost 或聚合。
8. displayMode 身份使用 enum，不使用本地化 title。
9. 保持现有 UI、选择、删除、日期、识别和详情行为不变。
10. 每项修改后构建，并提交 Instruments 前后对比。

暂时不要：
- 直接迁移 NSCollectionView；
- 引入第三方图片库；
- 大改视觉；
- 同时实现数据库和磁盘缓存。
```
