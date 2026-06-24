# GladPhotos 外部图库滚动性能审计材料

本目录是代码静态审计材料快照，只复制与说明；未修改、重构、格式化或自动修复原项目源码。

## 已复制文件（23 个 Swift 源码文件）

- `GladPhotos/Services/ExternalMediaScanner.swift`
- `GladPhotos/Services/ExternalFolderStore.swift`
- `GladPhotos/Services/ExternalFolderWatcher.swift`
- `GladPhotos/Services/ExternalFolderRecognitionStateStore.swift`
- `GladPhotos/Services/ExternalThumbnailService.swift`
- `GladPhotos/Views/ExternalMediaThumbnailView.swift`
- `GladPhotos/Views/ExternalMediaGridCell.swift`
- `GladPhotos/Views/ExternalMediaGridView.swift`
- `GladPhotos/Services/PhotographyClassificationService.swift`
- `GladPhotos/Services/PhotographyClassifier.swift`
- `GladPhotos/Services/PhotographyTagStore.swift`
- `GladPhotos/Views/PhotographyTagMenu.swift`
- `GladPhotos/Services/PerformanceLogger.swift`
- `GladPhotos/Services/PhotoImageService.swift`
- `GladPhotos/Views/PhotoGridView.swift`
- `GladPhotos/Views/PhotoThumbnailView.swift`
- `GladPhotos/Models/ExternalMediaItem.swift`
- `GladPhotos/Models/ExternalFolderItem.swift`
- `GladPhotos/Models/MediaDateIndex.swift`
- `GladPhotos/Models/PhotoAssetItem.swift`
- `GladPhotos/Models/PhotographyAnalysisRecord.swift`
- `GladPhotos/ContentView.swift`
- `Scripts/benchmark_external_media.swift`
- `GladPhotos.xcodeproj/project.pbxproj`

## 未找到的文件或类型

- MediaItem（未定义）
- ExternalMediaSection（未定义；实际为 private ExternalMediaDaySection）
- 独立 waterfall Layout / LayoutItem（未定义）
- 独立缓存 Key 类型（key 为 String 方法）
- 独立任务 Token 类型（仅 private ThumbnailRequestIdentity 与 Request）
- Info.plist（无独立文件）
- Package.swift / Package.resolved（均不存在）
- NSCollectionView 实现（不存在）

## 当前初步判断

1. 首次/跨启动再次打开的主要静态瓶颈证据是无磁盘媒体索引、无磁盘缩略图缓存，以及首次扫描逐图读取 ImageIO 尺寸；同进程再次打开已有两级内存清单缓存。
2. 快滚成本由嵌套 SwiftUI grids、每 Cell 几何/生命周期任务、两阶段解码、精确尺寸 key、高频日志和识别状态发布叠加。尚无测量证据证明 NSCollectionView 是必要迁移。
3. HEIC 已有内嵌预览判黑与主图回退，但主图回退自身未判黑，黑图仍可能被显示（不会被缓存）。
4. 大 PNG 长期模糊有直接代码路径：最终尺寸失败后保留 320 px preview 并进入完成态。
5. 识别并发 2 且滚动时暂停新任务，但与缩略图不共享 gate/缓存；结果批量发布整个记录字典，显示标签会改变 Cell 高度。
6. 识别标签独立存储，不在 `ExternalMediaItem`；媒体 ID 使用 URL，刷新稳定且不使用 index/随机 UUID。

## 最值得优先阅读的 10 个文件

1. `GladPhotos/Views/ExternalMediaGridView.swift`
2. `GladPhotos/Services/ExternalThumbnailService.swift`
3. `GladPhotos/Views/ExternalMediaThumbnailView.swift`
4. `GladPhotos/Services/ExternalMediaScanner.swift`
5. `GladPhotos/Services/PhotographyClassificationService.swift`
6. `GladPhotos/Services/PhotographyClassifier.swift`
7. `GladPhotos/Services/PhotographyTagStore.swift`
8. `GladPhotos/Views/ExternalMediaGridCell.swift`
9. `GladPhotos/ContentView.swift`
10. `GladPhotos/Views/PhotoGridView.swift`

## 文档索引

- `CALL_SITES.md`：指定符号的全量调用/引用位置与用途
- `ARCHITECTURE.md`：真实扫描、缩略图、识别调用链与线程/缓存/ID 说明
- `RISKS.md`：P0/P1/P2 风险清单
- `DEAD_CODE.md`：删除、合并、保留观察候选
- `PERFORMANCE_BASELINE.md`：测试未运行原因与可测能力

## 包信息

- ZIP 文件名：`GladPhotosPerformanceAudit.zip`
- 源码文件计数：23
- 原项目源码：确认未修改；所有新增内容仅位于 `GladPhotosPerformanceAudit/` 及最终 ZIP。
