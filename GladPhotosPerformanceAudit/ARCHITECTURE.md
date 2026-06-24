# 当前架构与真实调用链

## 打开外部文件夹

`ContentView` 选择 `LibrarySource.externalFolder(UUID)` → 创建 `ExternalMediaGridView`（`ContentView.swift:73-95`）→ `restoreCacheAndWatch()`（`ExternalMediaGridView.swift:283-285,425-437`）→ 优先使用传入的 `initialItems`，其次使用进程内 `ExternalMediaScanner.cache`，均不存在才 `scan()`。

1. 选择文件夹与 View/Store 状态发布在主 actor。`ExternalFolderStore` 是 `@MainActor`；安全书签恢复和可读性检查同步执行（`ExternalFolderStore.swift:146-210`）。
2. `ExternalMediaScanner.scan` 是 actor 方法。目录枚举通过 `Task.detached(.userInitiated)` 执行，读取 regular-file、大小、创建和修改日期（`ExternalMediaScanner.swift:28-36,157-208`）。
3. 枚举后回到 scanner actor，逐个建立模型；未命中旧缓存的图片用 ImageIO 读取像素尺寸与方向（`ExternalMediaScanner.swift:39-78,231-242`）。这会触碰每个图片文件容器/属性，但不做完整像素解码；不读取 EXIF 拍摄参数。视频时长延迟到 Cell/详情。
4. 扫描结果先在 scanner actor 按修改日期排序并写入仅进程内缓存（`ExternalMediaScanner.swift:80-94`）。
5. `scan()` 恢复到主 actor 后，`setItems` 再排序、重建月份索引、过滤/日期分组并一次发布完整数组（`ExternalMediaGridView.swift:463-505`）。不是逐张发布 UI。
6. 日期 Section 由 `ExternalMediaDaySection.make` 过滤、`Dictionary(grouping:)`、组内排序、Section 排序（`ExternalMediaGridView.swift:3-25`），再交给嵌套 `LazyVStack` + 每日一个 `LazyVGrid`（`ExternalMediaGridView.swift:329-379`）。
7. 首次进入无缓存时扫描；同一应用进程再次打开优先用 `ContentView.externalItemsByFolder` 或 scanner cache，不重扫。应用重启后没有媒体清单磁盘缓存，会重新扫描。文件监听事件 500ms 去抖后触发全量 scan（`ExternalMediaGridView.swift:438-445`）。

## 缩略图

`ExternalMediaGridCell` → `ExternalMediaThumbnailView.onAppear/onGeometryChange` → `startLoading()` → `ExternalThumbnailService.cachedImage/image` → 内存缓存/进行中任务表 → `ThumbnailDecodeGate(limit: 4)` → detached ImageIO 或 AVAsset 解码 → token、mediaID、可见性与取消检查后回写 UI。

- 内存缓存：有，`NSCache<NSString, NSImage>`，500 项、256 MiB（`ExternalThumbnailService.swift:21-29`）。
- 跨启动磁盘缓存：没有。
- Key：标准化路径 + 修改时间 + 请求像素，视频时长 key 不含像素（`ExternalThumbnailService.swift:137-144`）。
- 尺寸：不是固定尺寸；Cell 用实测宽高比、实际渲染宽度和 `displayScale` 请求，最大 1600 px（`ExternalMediaThumbnailView.swift:55-62`）。先请求至多 320 px 预览，再在需要时请求最终尺寸（`ExternalMediaThumbnailView.swift:83-117`）。
- HEIC/HEIF：先允许内嵌预览；若 8×8 抽样判黑则用 `CreateThumbnailFromImageAlways` 回退主图（`ExternalThumbnailService.swift:208-224,232-248`）。但回退结果未在 pipeline 返回前判黑；service 只是不缓存黑图，仍会把该结果返回给 Cell（`ExternalThumbnailService.swift:67-75`）。
- PNG：ImageIO 直接生成 CGImage，保留 alpha，不经过 JPEG（`ExternalThumbnailService.swift:219-224`）。
- 去重：相同精确 key 共用进行中 Task（`ExternalThumbnailService.swift:39-67`）。预览与最终尺寸 key 不同。
- 取消：Cell 离屏取消本地 Task，并按 item 取消 service 中请求（`ExternalMediaThumbnailView.swift:46-49,129-141`）。
- 防错写：随机 request UUID + 稳定 media URL + `isVisible` 三重检查（`ExternalMediaThumbnailView.swift:64-67,96-124`）。随机 UUID 仅是任务 token，不是 ForEach ID。
- 失败/占位/黑图不进缓存。取消路径在 gate、decode 前后检查；但共享请求由任一同 item Cell 的取消调用整体取消，没有引用计数。
- 大图模糊风险：最终大尺寸解码失败时仍保留 320 px 预览并标记完成（`ExternalMediaThumbnailView.swift:103-117`），可造成长期模糊。

## 摄影/非摄影识别

点击“识别” → `startAnalysis/beginAnalysis` → `PhotographyClassificationService.analyze` → 每项 `DefaultPhotographyClassifier.classify` → `PhotographyTagStore.save` → 16 条或 100ms 批量回调 → `applyPhotographyRecords` 一次替换记录字典/计数 → 500ms 合并追加 JSONL，结束时 flush。

- 当前分类先通过 ImageIO 打开原文件并读取完整属性字典/EXIF，但模型占位实现不可用，因此不解码像素；未来模型可用时会从原文件生成最长边 384 px 的缩略图（`PhotographyClassifier.swift:112-147`）。它不复用浏览缩略图缓存。
- 并发固定为 2（`PhotographyClassificationService.swift:44-58`），使用自己的 task group/后台 detached，不共用缩略图的 decode gate。
- 滚动 phase 会暂停后续任务进入分类；已经过 pause gate 的两个任务继续运行（`ExternalMediaGridView.swift:180-182`; `PhotographyClassificationService.swift:50-55,83-88,121-132`）。
- 标签不存于主 `ExternalMediaItem`；独立存入 `[String: PhotographyAnalysisRecord]`，key 为标准化路径。每批仍会发布整个值类型字典，但不会改写整个 MediaItem 数组；非 `.all` 筛选且标签改变可见性时才重建 Sections（`ExternalMediaGridView.swift:606-644`）。
- 持久化不是逐条写：每条先进入 dirty 字典，500ms 合并后追加 JSONL，结束 flush（`PhotographyTagStore.swift:66-88,131-179`）。不过首次加载会同步读取 JSON/JSONL 于 store actor（`PhotographyTagStore.swift:114-129`）。
- 显示/隐藏识别菜单改变 Cell 子树及高度，会触发网格重新布局（`ExternalMediaGridCell.swift:58-61`）。

## ID 稳定性

- `ExternalMediaItem.id` 是原始 `url`（`ExternalMediaItem.swift:20`）；刷新后同一路径稳定，移动/重命名会变化。未使用数组 index，也未用随机 UUID 作为媒体 ID。
- `ExternalMediaDaySection.id` 与 `PhotoDaySection.id` 是当天 `Date`，同一天稳定（两份 Grid 文件开头）。
- Apple 图库 `PhotoAssetItem.id` 是 `PHAsset.localIdentifier`（`PhotoAssetItem.swift:6-8`），稳定且未用 index。
- `ExternalFolderItem.id` 是首次添加时随机 UUID，并持久化在安全书签记录中；同一持久化文件夹跨启动稳定，非持久化重新添加会得到新 UUID（`ExternalFolderItem.swift:15-29`; `ExternalFolderStore.swift:80-100,266-269`）。
- 缩略图 request、刷新和滚动请求使用随机 UUID 作为一次性 token，不参与媒体 ForEach 身份。

## SwiftUI 还是 NSCollectionView

当前代码没有 `NSCollectionView`、自定义 waterfall Layout 或 LayoutItem 实现。现有证据先指向扫描无磁盘索引、缩略图无磁盘缓存/两级尺寸失败、每 Cell 生命周期任务、嵌套每日 LazyVGrid、识别状态批量发布与高频日志。仅静态代码不足以证明必须迁移。建议先保留 SwiftUI 实现并用真实图库 Instruments/Signpost 分离“布局耗时”与“解码/状态发布耗时”；若关闭解码与识别后快速滚动仍由 SwiftUI layout/diff 主导且超出帧预算，再以同数据集原型对比 NSCollectionView。Apple 图库对照实现也仍是 `LazyVStack + LazyVGrid`，并非 NSCollectionView（`PhotoGridView.swift:301-355`）。

## 依赖与配置

项目未发现 `Package.swift`、`Package.resolved`、远程 Swift Package 引用或图片/缓存/瀑布流/Vision/SQLite 第三方依赖。相关实现使用系统框架 SwiftUI、AppKit、ImageIO、Photos、AVFoundation、CoreML、Vision、OSLog 和 CoreServices/FSEvents；pbxproj 另有嵌入 ffprobe 的脚本阶段。`Info.plist` 未作为独立文件存在，项目使用 Xcode 生成 Info.plist 的构建设置。
