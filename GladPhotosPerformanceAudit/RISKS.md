# 风险清单

## P0：直接造成黑图、模糊或错误

- **HEIC 主图回退仍可能显示黑图** — `ExternalThumbnailService.swift:219-224,67-75`。内嵌图判黑后回退，但回退图未判黑即返回；上层仅拒绝缓存，当前 Cell 仍显示它。
- **最终尺寸失败时 320 px 预览被当成完成态** — `ExternalMediaThumbnailView.swift:83-117`。大 PNG/大图第二阶段失败时保留 preview，`didFinishLoading = image != nil`，不会自动重试，符合“长期模糊”现象。
- **识别占位模型把未知默认保存为非摄影** — `PhotographyClassifier.swift:96-105,126-128,159-165`。注释称应诚实返回 unknown，但 `modelUnavailableFallback()` 实际返回 `.nonPhotography`，会生成错误标签。

## P1：明显增加滚动或更新成本

- **主线程同步文件/偏好 I/O** — `ExternalFolderStore.swift:15-18,146-210,251-263` 在 `@MainActor` 初始化时同步恢复书签、检查文件系统并读写 UserDefaults；`ExternalFolderRecognitionStateStore.swift:16-26,54-57` 也在主 actor 同步 JSON 编解码与 UserDefaults 写入。文件夹很多或状态数据增长时会阻塞 UI。
- **外部清单与缩略图都无跨启动磁盘缓存** — `ExternalMediaScanner.swift:5,88-102`; `ExternalThumbnailService.swift:21-29`。再次启动必重新枚举/读取图片尺寸，缩略图也重解码。
- **首次扫描逐张打开图片容器读取尺寸** — `ExternalMediaScanner.swift:39-78,231-242`。不完整解码，但大目录仍有 O(n) ImageIO 文件访问；scanner actor 串行执行。
- **文件监听只会触发全量刷新** — `ExternalFolderWatcher.swift:29-53`; `ExternalMediaGridView.swift:425-445,463-473`。FSEvent 不传入增量路径，500ms 后重新扫描整个树。
- **主 actor 做全数组排序、月份索引、过滤、分组与多次值复制** — `ExternalMediaGridView.swift:44,58-82,463-505,514-529`。扫描完成一次替换整个 `[ExternalMediaItem]`，然后建月缓存和日 Sections；值类型数组/字典存在 O(n) 复制和发布成本。
- **body/父 View 计算中仍有过滤和扁平化** — `ExternalMediaGridView.swift:130-149,173`; `ContentView.swift:27-29`; `PhotoGridView.swift:79-81`。状态变化可能重复执行过滤、flatMap 或 Apple 日分组。
- **Cell body 路径重复格式化日期/大小/标签文字** — `ExternalMediaThumbnailView.swift:210-228`; `ExternalMediaGridView.swift:408-418,539-552`。单次成本不高，但大批 Cell 更新时会叠加字符串与 Formatter 工作。
- **识别批次替换整个记录字典并使父网格重新求值** — `PhotographyClassificationService.swift:68-81`; `ExternalMediaGridView.swift:606-644`。虽已按 16 条/100ms 合并且 Cell Equatable，父 View 仍读取大字典并重新构造 Cell 参数。
- **识别显示状态在首批结果就持久化并改变整网格 Cell 结构** — `ExternalMediaGridView.swift:574-583`; `ExternalFolderRecognitionStateStore.swift:33-38`; `ExternalMediaGridCell.swift:58-61`。菜单出现改变高度，触发大范围布局。
- **识别不复用缩略图管线与并发 gate** — `PhotographyClassificationService.swift:44-89`; `PhotographyClassifier.swift:112-138`。当前虽主要读元数据，未来模型解码会和可见缩略图竞争 I/O/CPU；滚动只阻挡下一批，不中止已在途任务。
- **每个可见 Cell 由 geometry/onAppear 反复重启两阶段请求** — `ExternalMediaThumbnailView.swift:32-52,64-83`。宽度变化或离屏再出现会取消/重启；无磁盘缓存时 cache miss 反复解码。
- **精确像素 key 造成同图多尺寸缓存与解码** — `ExternalThumbnailService.swift:30-40,137-140`; `ExternalMediaThumbnailView.swift:83-110`。320 preview 与最终尺寸天然是两个对象，几何抖动还可产生相邻尺寸 key。
- **取消共享请求没有订阅者引用计数** — `ExternalThumbnailService.swift:40,95-106`; `ExternalMediaThumbnailView.swift:129-141`。同一 key 的一个消费者离屏可取消其他消费者正在等待的去重任务。
- **每张缩略图均写 OSLog** — `ExternalThumbnailService.swift:58-63`; `PerformanceLogger.swift:10-15`。快速滚动时高频字符串插值和日志输出会放大开销。
- **嵌套多个 LazyVGrid** — `ExternalMediaGridView.swift:329-379`。每个日期 Section 一个网格，Section/Cell 高度变化会扩大布局工作；是否足以迁移 NSCollectionView 仍需 Instruments 证据。

## P2：架构债务与可维护性

- **缩略图 sizing 参数是名义 API** — `ExternalThumbnailService.swift:30-37,78-85,88-96` 中 `sizing _:` 被忽略；`ExternalMediaThumbnailView.swift:144-146` 的 `thumbnailSizing` 无引用。API 暗示三种策略但实际 key/行为相同。
- **两套图库缩略图/Cell 生命周期实现** — 外部使用 `ExternalThumbnailService` + ImageIO，Apple 使用 `PhotoImageService` + Photos（`PhotoImageService.swift:37-129`; `PhotoThumbnailView.swift:182-218`）。底层必须分开，但 token、取消、可见性、两阶段质量策略可抽取共同约定。
- **日期 Section 分组实现重复** — `ExternalMediaGridView.swift:3-25` 与 `PhotoGridView.swift:4-27` 结构几乎相同，可合并泛型/预计算层。
- **View 同时编排扫描、监听、删除、识别、持久化和布局** — `ExternalMediaGridView.swift:44-115,421-644`。它直接创建 TagStore/ClassificationService、持有 Watcher 并发布多套派生状态；虽未发现字面循环依赖，职责高度耦合，难以单独测量布局与数据管线。
- **文件夹识别显示状态与标签记录分成 UserDefaults + JSONL 两套存储** — `ExternalFolderRecognitionStateStore.swift:4-57`; `PhotographyTagStore.swift:3-190`。职责可以保留分层，但生命周期/删除/迁移策略分散。
- **JSONL 只追加、没有压缩回主 JSON** — `PhotographyTagStore.swift:114-129,131-159`。长期识别/手动修改会持续增长，启动回放越来越慢。
- **无直接 `CGImageSourceCreateImageAtIndex`、`NSImage(contentsOf:)` 或 `tiffRepresentation` 调用** — 这些常见全图解码路径不是当前滚动问题来源。
- **未发现主线程图片解码** — 外部 ImageIO/AVAsset 解码在 detached 工作中，Photos 回调再切主 actor；静态代码不支持“主线程解码”这一风险判断。
- **媒体与 Section ID 稳定** — 外部媒体用 URL、Apple 媒体用 localIdentifier、日期 Section 用 Date；未使用数组 index 或随机媒体 UUID。随机 UUID 仅用于文件夹持久身份、刷新和任务 token。
- **未发现每 Cell 创建 ObservableObject** — Cell 仅有局部 `@State`，服务从父层注入；这项风险当前不成立。
- **取消结果通常不会进入缓存** — pipeline 与 service 多处检查取消，失败/黑图也拒绝缓存；但“黑图可返回显示”和“共享取消”仍见 P0/P1。
- **刷新不会清空缩略图缓存或 scanner 全缓存** — 当前不存在“每次刷新 removeAll 缓存”的证据；刷新会替换媒体数组并重建派生 Sections。`removeAllCachedImages` 反而没有调用。
- **未发现完全无调用的核心服务** — Scanner、Watcher、Thumbnail、Classification、TagStore、PerformanceLogger 均有调用；无引用候选主要是 `thumbnailSizing` 属性和 `removeAllCachedImages` 方法，详见 `DEAD_CODE.md`。
