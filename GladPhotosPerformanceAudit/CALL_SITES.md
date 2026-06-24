# 调用点索引

范围：`GladPhotos/**/*.swift` 与 `Scripts/**/*.swift`；行号对应本次复制时源码。每条均附用途说明。

## `ExternalThumbnailService`

- `GladPhotos/ContentView.swift:15` — 创建、保存或注入该服务/类型。 `@State private var externalThumbnailService = ExternalThumbnailService()`
- `GladPhotos/Services/ExternalThumbnailService.swift:14` — 定义该类型/协议。 `final class ExternalThumbnailService {`
- `GladPhotos/Views/ExternalImageDetailView.swift:7` — 创建、保存或注入该服务/类型。 `let thumbnailService: ExternalThumbnailService`
- `GladPhotos/Views/ExternalImageDetailView.swift:32` — 调用或引用该服务/符号。 `thumbnailService: ExternalThumbnailService,`
- `GladPhotos/Views/ExternalMediaGridCell.swift:5` — 创建、保存或注入该服务/类型。 `let thumbnailService: ExternalThumbnailService`
- `GladPhotos/Views/ExternalMediaGridView.swift:47` — 创建、保存或注入该服务/类型。 `let thumbnailService: ExternalThumbnailService`
- `GladPhotos/Views/ExternalMediaGridView.swift:87` — 调用或引用该服务/符号。 `thumbnailService: ExternalThumbnailService,`
- `GladPhotos/Views/ExternalMediaThumbnailView.swift:6` — 创建、保存或注入该服务/类型。 `let thumbnailService: ExternalThumbnailService`
- `Scripts/benchmark_external_media.swift:78` — 创建、保存或注入该服务/类型。 `let service = ExternalThumbnailService()`

## `ExternalMediaScanner`

- `GladPhotos/ContentView.swift:14` — 创建、保存或注入该服务/类型。 `@State private var externalScanner = ExternalMediaScanner()`
- `GladPhotos/Services/ExternalMediaScanner.swift:4` — 定义该类型/协议。 `actor ExternalMediaScanner {`
- `GladPhotos/Views/ExternalMediaGridView.swift:46` — 创建、保存或注入该服务/类型。 `let scanner: ExternalMediaScanner`
- `GladPhotos/Views/ExternalMediaGridView.swift:86` — 调用或引用该服务/符号。 `scanner: ExternalMediaScanner,`
- `Scripts/benchmark_external_media.swift:38` — 创建、保存或注入该服务/类型。 `let scanner = ExternalMediaScanner()`

## `PhotographyClassificationService`

- `GladPhotos/Services/PhotographyClassificationService.swift:4` — 定义该类型/协议。 `final class PhotographyClassificationService {`
- `GladPhotos/Views/ExternalMediaGridView.swift:76` — 创建、保存或注入该服务/类型。 `@State private var analysisProgress: PhotographyClassificationService.Progress?`
- `GladPhotos/Views/ExternalMediaGridView.swift:82` — 创建、保存或注入该服务/类型。 `@State private var classificationService: PhotographyClassificationService`
- `GladPhotos/Views/ExternalMediaGridView.swift:113` — 调用或引用该服务/符号。 `initialValue: PhotographyClassificationService(store: store)`

## `PhotographyClassifier`

- `GladPhotos/Services/PhotographyClassificationService.swift:11` — 创建、保存或注入该服务/类型。 `private let classifier: any PhotographyClassifier`
- `GladPhotos/Services/PhotographyClassificationService.swift:17` — 调用或引用该服务/符号。 `classifier: any PhotographyClassifier = DefaultPhotographyClassifier()`
- `GladPhotos/Services/PhotographyClassifier.swift:13` — 定义该类型/协议。 `nonisolated protocol PhotographyClassifier: Sendable {`
- `GladPhotos/Services/PhotographyClassifier.swift:98` — 定义该类型/协议。 `nonisolated struct CoreMLPhotographyClassifier: Sendable {`
- `GladPhotos/Services/PhotographyClassifier.swift:107` — 定义该类型/协议。 `nonisolated struct DefaultPhotographyClassifier: PhotographyClassifier {`
- `GladPhotos/Services/PhotographyClassifier.swift:110` — 创建、保存或注入该服务/类型。 `private let model = CoreMLPhotographyClassifier()`

## `PhotographyTagStore`

- `GladPhotos/ContentView.swift:197` — 调用或引用该服务/符号。 `PhotographyTagStore.removePersistedRecords(for: folder.id)`
- `GladPhotos/Services/PhotographyClassificationService.swift:10` — 创建、保存或注入该服务/类型。 `private let store: PhotographyTagStore`
- `GladPhotos/Services/PhotographyClassificationService.swift:16` — 调用或引用该服务/符号。 `store: PhotographyTagStore,`
- `GladPhotos/Services/PhotographyTagStore.swift:3` — 定义该类型/协议。 `actor PhotographyTagStore {`
- `GladPhotos/Views/ExternalMediaGridView.swift:81` — 创建、保存或注入该服务/类型。 `@State private var tagStore: PhotographyTagStore`
- `GladPhotos/Views/ExternalMediaGridView.swift:110` — 创建、保存或注入该服务/类型。 `let store = PhotographyTagStore(folderID: folder.id)`

## `ExternalFolderWatcher`

- `GladPhotos/Services/ExternalFolderWatcher.swift:5` — 定义该类型/协议。 `final class ExternalFolderWatcher {`
- `GladPhotos/Views/ExternalMediaGridView.swift:67` — 创建、保存或注入该服务/类型。 `@State private var folderWatcher = ExternalFolderWatcher()`

## `PerformanceLogger`

- `GladPhotos/Services/ExternalMediaScanner.swift:89` — 记录性能阶段耗时。 `PerformanceLogger.log(`
- `GladPhotos/Services/ExternalThumbnailService.swift:60` — 记录性能阶段耗时。 `PerformanceLogger.log(`
- `GladPhotos/Services/PerformanceLogger.swift:4` — 定义该类型/协议。 `nonisolated enum PerformanceLogger {`
- `GladPhotos/Services/PhotographyClassificationService.swift:101` — 记录性能阶段耗时。 `PerformanceLogger.log(`
- `GladPhotos/Services/PhotographyTagStore.swift:160` — 记录性能阶段耗时。 `PerformanceLogger.log(`
- `GladPhotos/Views/ExternalMediaGridView.swift:500` — 记录性能阶段耗时。 `PerformanceLogger.log(`
- `GladPhotos/Views/ExternalMediaGridView.swift:531` — 记录性能阶段耗时。 `PerformanceLogger.log(`

## `CGImageSourceCreateThumbnailAtIndex`

- `GladPhotos/Services/ExternalThumbnailService.swift:213` — ImageIO 图片解码/缩略图生成。 `if let candidate = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),`
- `GladPhotos/Services/ExternalThumbnailService.swift:221` — ImageIO 图片解码/缩略图生成。 `guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),`
- `GladPhotos/Services/PhotographyClassifier.swift:137` — ImageIO 图片解码/缩略图生成。 `let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),`

## `CGImageSourceCreateImageAtIndex`

- 未找到。

## `NSImage(contentsOf:`

- 未找到。

## `tiffRepresentation`

- 未找到。

## `.task`

- `GladPhotos/ContentView.swift:56` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task {`
- `GladPhotos/Services/ExternalThumbnailService.swift:40` — SwiftUI 生命周期、异步任务或视图身份控制。 `if let request = requests[cacheKey] { return await request.task.value }`
- `GladPhotos/Services/ExternalThumbnailService.swift:98` — SwiftUI 生命周期、异步任务或视图身份控制。 `requests.removeValue(forKey: cacheKey)?.task.cancel()`
- `GladPhotos/Services/ExternalThumbnailService.swift:104` — SwiftUI 生命周期、异步任务或视图身份控制。 `requests.removeValue(forKey: key)?.task.cancel()`
- `GladPhotos/Services/ExternalThumbnailService.swift:115` — SwiftUI 生命周期、异步任务或视图身份控制。 `requests.removeValue(forKey: key)?.task.cancel()`
- `GladPhotos/Services/ExternalThumbnailService.swift:120` — SwiftUI 生命周期、异步任务或视图身份控制。 `requests.values.forEach { $0.task.cancel() }`
- `GladPhotos/Views/ExternalImageDetailView.swift:57` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: currentItem.id) {`
- `GladPhotos/Views/ExternalImageDetailView.swift:126` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: currentItem.id) {`
- `GladPhotos/Views/ExternalMediaGridView.swift:190` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: scrollRequestID) {`
- `GladPhotos/Views/ExternalMediaGridView.swift:279` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: refreshID) {`
- `GladPhotos/Views/ExternalMediaGridView.swift:283` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: folder.url) {`
- `GladPhotos/Views/ExternalMediaGridView.swift:286` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: folder.id) {`
- `GladPhotos/Views/ExternalVideoDetailView.swift:77` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: item.id) {`
- `GladPhotos/Views/PhotoDetailView.swift:72` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: currentItem.localIdentifier) {`
- `GladPhotos/Views/PhotoDetailView.swift:174` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: currentItem.localIdentifier) {`
- `GladPhotos/Views/PhotoGridView.swift:104` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: scrollRequestID) {`
- `GladPhotos/Views/SourceInfoPanel.swift:30` — SwiftUI 生命周期、异步任务或视图身份控制。 `.task(id: fileURL) {`

## `.onAppear`

- `GladPhotos/Views/CalendarDemoView.swift:149` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onAppear {`
- `GladPhotos/Views/ExternalImageDetailView.swift:62` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onAppear { pageWidth = max(geometry.size.width, 1) }`
- `GladPhotos/Views/ExternalImageDetailView.swift:147` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onAppear {`
- `GladPhotos/Views/ExternalMediaThumbnailView.swift:42` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onAppear {`
- `GladPhotos/Views/PhotoDetailView.swift:77` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onAppear { pageWidth = max(geometry.size.width, 1) }`
- `GladPhotos/Views/PhotoDetailView.swift:195` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onAppear {`
- `GladPhotos/Views/PhotoThumbnailView.swift:44` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onAppear {`
- `GladPhotos/Views/ZoomablePhotoView.swift:180` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onAppear {`

## `.onDisappear`

- `GladPhotos/Views/ExternalImageDetailView.swift:150` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onDisappear {`
- `GladPhotos/Views/ExternalMediaGridView.swift:302` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onDisappear {`
- `GladPhotos/Views/ExternalMediaThumbnailView.swift:46` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onDisappear {`
- `GladPhotos/Views/ExternalVideoDetailView.swift:95` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onDisappear {`
- `GladPhotos/Views/PhotoDetailView.swift:198` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onDisappear {`
- `GladPhotos/Views/PhotoThumbnailView.swift:49` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onDisappear {`
- `GladPhotos/Views/PointingHandCursorModifier.swift:18` — SwiftUI 生命周期、异步任务或视图身份控制。 `.onDisappear {`

## `.id(`

- `GladPhotos/ContentView.swift:94` — SwiftUI 生命周期、异步任务或视图身份控制。 `.id(folder)`
- `GladPhotos/Views/CalendarDemoView.swift:144` — SwiftUI 生命周期、异步任务或视图身份控制。 `.id(year)`
- `GladPhotos/Views/ExternalImageDetailView.swift:186` — SwiftUI 生命周期、异步任务或视图身份控制。 `.id(currentItem.id)`
- `GladPhotos/Views/ExternalMediaGridView.swift:335` — SwiftUI 生命周期、异步任务或视图身份控制。 `.id(section.id)`
- `GladPhotos/Views/PhotoDetailView.swift:245` — SwiftUI 生命周期、异步任务或视图身份控制。 `.id(currentItem.localIdentifier)`
- `GladPhotos/Views/PhotoGridView.swift:305` — SwiftUI 生命周期、异步任务或视图身份控制。 `.id(topAnchorID)`
- `GladPhotos/Views/PhotoGridView.swift:325` — SwiftUI 生命周期、异步任务或视图身份控制。 `.id(section.id)`

## `ForEach`

- `GladPhotos/Views/CalendarDemoView.swift:120` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(availableMonths, id: \.self) { month in`
- `GladPhotos/Views/CalendarDemoView.swift:136` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(years, id: \.self) { year in`
- `GladPhotos/Views/CalendarDemoView.swift:164` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(weekdays) { weekday in`
- `GladPhotos/Views/CalendarDemoView.swift:171` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(calendarDates, id: \.self) { date in`
- `GladPhotos/Views/ExternalImageDetailView.swift:49` — SwiftUI 列表、布局或滚动几何更新。 `ForEach([-1, 0, 1], id: \.self) { relativeOffset in`
- `GladPhotos/Views/ExternalMediaGridView.swift:247` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(PhotographyFilter.allCases) { filter in`
- `GladPhotos/Views/ExternalMediaGridView.swift:331` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(daySections) { section in`
- `GladPhotos/Views/ExternalMediaGridView.swift:355` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(mediaItems) { item in`
- `GladPhotos/Views/PhotoDetailView.swift:64` — SwiftUI 列表、布局或滚动几何更新。 `ForEach([-1, 0, 1], id: \.self) { relativeOffset in`
- `GladPhotos/Views/PhotoGridView.swift:307` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(daySections) { section in`
- `GladPhotos/Views/PhotoGridView.swift:340` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(section.assets, id: \.localIdentifier) { item in`
- `GladPhotos/Views/PhotoGridView.swift:352` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(undatedAssets, id: \.localIdentifier) { item in`
- `GladPhotos/Views/SidebarView.swift:50` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(externalFolders) { folder in`
- `GladPhotos/Views/SourceInfoPanel.swift:128` — SwiftUI 列表、布局或滚动几何更新。 `ForEach(Array(metadata.audioTracks.enumerated()), id: \.element.id) { offset, track in`

## `LazyVGrid`

- `GladPhotos/Views/CalendarDemoView.swift:119` — SwiftUI 列表、布局或滚动几何更新。 `LazyVGrid(columns: monthColumns, spacing: 8) {`
- `GladPhotos/Views/CalendarDemoView.swift:163` — SwiftUI 列表、布局或滚动几何更新。 `LazyVGrid(columns: dayColumns, spacing: 4) {`
- `GladPhotos/Views/ExternalMediaGridView.swift:354` — SwiftUI 列表、布局或滚动几何更新。 `LazyVGrid(columns: columns, spacing: 2) {`
- `GladPhotos/Views/ExternalMediaThumbnailView.swift:40` — 注释说明相关机制。 `// @ d8a725c. SwiftUI adaptation: only visible LazyVGrid cells own work;`
- `GladPhotos/Views/PhotoGridView.swift:339` — SwiftUI 列表、布局或滚动几何更新。 `LazyVGrid(columns: columns, spacing: 2) {`
- `GladPhotos/Views/PhotoGridView.swift:351` — SwiftUI 列表、布局或滚动几何更新。 `LazyVGrid(columns: columns, spacing: 2) {`

## `LazyHGrid`

- 未找到。

## `GeometryReader`

- `GladPhotos/Views/ExternalImageDetailView.swift:47` — SwiftUI 列表、布局或滚动几何更新。 `GeometryReader { geometry in`
- `GladPhotos/Views/PhotoDetailView.swift:62` — SwiftUI 列表、布局或滚动几何更新。 `GeometryReader { geometry in`
- `GladPhotos/Views/PhotoGridView.swift:327` — SwiftUI 列表、布局或滚动几何更新。 `GeometryReader { proxy in`
- `GladPhotos/Views/VideoTrimTimelineView.swift:10` — SwiftUI 列表、布局或滚动几何更新。 `GeometryReader { geometry in`
- `GladPhotos/Views/ZoomablePhotoView.swift:131` — SwiftUI 列表、布局或滚动几何更新。 `GeometryReader { geometry in`

## `PreferenceKey`

- `GladPhotos/Views/PhotoGridView.swift:603` — 定义该类型/协议。 `private struct SectionHeaderOffsetKey: PreferenceKey {`

## `onPreferenceChange`

- `GladPhotos/Views/PhotoGridView.swift:108` — SwiftUI 列表、布局或滚动几何更新。 `.onPreferenceChange(SectionHeaderOffsetKey.self) { offsets in`

## `onScrollGeometryChange`

- 未找到。

## `DispatchQueue.main`

- `GladPhotos/Services/ExternalFolderWatcher.swift:52` — 并发调度、并行任务或主线程切换。 `FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)`
- `GladPhotos/Views/LivePhotoPlayerView.swift:85` — 并发调度、并行任务或主线程切换。 `DispatchQueue.main.async { [weak view] in`

## `MainActor.run`

- 未找到。

## `Task.detached`

- `GladPhotos/Services/ExternalMediaScanner.swift:28` — 并发调度、并行任务或主线程切换。 `let enumerationTask = Task.detached(priority: .userInitiated) {`
- `GladPhotos/Services/ExternalThumbnailService.swift:48` — 并发调度、并行任务或主线程切换。 `let result = await Task.detached(priority: .userInitiated) {`
- `GladPhotos/Services/FFprobeRunner.swift:27` — 并发调度、并行任务或主线程切换。 `return try await Task.detached(priority: .userInitiated) {`
- `GladPhotos/Services/PhotoCompressionService.swift:138` — 并发调度、并行任务或主线程切换。 `try await Task.detached(priority: .userInitiated) {`
- `GladPhotos/Services/PhotographyClassificationService.swift:52` — 并发调度、并行任务或主线程切换。 `let result = await Task.detached(priority: .background) {`
- `GladPhotos/Services/PhotographyClassificationService.swift:85` — 并发调度、并行任务或主线程切换。 `let result = await Task.detached(priority: .background) {`

## `withTaskGroup`

- `GladPhotos/Services/PhotographyClassificationService.swift:44` — 并发调度、并行任务或主线程切换。 `await withTaskGroup(`
- `GladPhotos/Views/ExternalImageDetailView.swift:369` — 并发调度、并行任务或主线程切换。 `await withTaskGroup(of: (URL, NSImage?).self) { group in`
- `Scripts/benchmark_external_media.swift:109` — 并发调度、并行任务或主线程切换。 `decoded += await withTaskGroup(of: Bool.self, returning: Int.self) { group in`

## `write`

- `GladPhotos/Services/ExternalFolderStore.swift:236` — 状态、标签或文件数据持久化。 `writeBookmarks(persisted)`
- `GladPhotos/Services/ExternalFolderStore.swift:243` — 状态、标签或文件数据持久化。 `writeBookmarks(persisted)`
- `GladPhotos/Services/ExternalFolderStore.swift:248` — 状态、标签或文件数据持久化。 `writeBookmarks(loadBookmarks().filter { retainedIDs.contains($0.id) })`
- `GladPhotos/Services/ExternalFolderStore.swift:258` — 状态、标签或文件数据持久化。 `private func writeBookmarks(_ folders: [PersistedFolder]) {`
- `GladPhotos/Services/PhotoCompressionService.swift:127` — 状态、标签或文件数据持久化。 `resourceManager.writeData(for: resource, toFile: url, options: options) { error in`
- `GladPhotos/Services/PhotographyTagStore.swift:133` — 状态、标签或文件数据持久化。 `let writeStart = ContinuousClock.now`
- `GladPhotos/Services/PhotographyTagStore.swift:152` — 状态、标签或文件数据持久化。 `try handle.write(contentsOf: payload)`
- `GladPhotos/Services/PhotographyTagStore.swift:158` — 注释说明相关机制。 `// A failed cache write must not interrupt browsing or discard in-memory labels.`
- `GladPhotos/Services/PhotographyTagStore.swift:161` — 状态、标签或文件数据持久化。 `"json-write",`
- `GladPhotos/Services/PhotographyTagStore.swift:162` — 状态、标签或文件数据持久化。 `duration: writeStart.duration(to: .now),`
- `GladPhotos/Views/ExternalMediaThumbnailView.swift:41` — 注释说明相关机制。 `// disappearance/reuse cancels it and a token blocks stale async writes.`

## `JSONEncoder`

- `GladPhotos/Services/ExternalFolderRecognitionStateStore.swift:55` — 状态、标签或文件数据持久化。 `guard let data = try? JSONEncoder().encode(states) else { return }`
- `GladPhotos/Services/ExternalFolderStore.swift:259` — 状态、标签或文件数据持久化。 `guard let data = try? JSONEncoder().encode(folders) else {`
- `GladPhotos/Services/PhotographyTagStore.swift:135` — 状态、标签或文件数据持久化。 `let encoder = JSONEncoder()`

## `removeAll`

- `GladPhotos/Services/ExternalFolderStore.swift:68` — 集合重建、排序、分组、清理或刷新。 `folders.removeAll { $0.id == folder.id }`
- `GladPhotos/Services/ExternalFolderStore.swift:241` — 集合重建、排序、分组、清理或刷新。 `persisted.removeAll { $0.id == folder.id }`
- `GladPhotos/Services/ExternalMediaScanner.swift:107` — 集合重建、排序、分组、清理或刷新。 `cache[key]?.removeAll { item in`
- `GladPhotos/Services/ExternalThumbnailService.swift:119` — 集合重建、排序、分组、清理或刷新。 `func removeAllCachedImages() {`
- `GladPhotos/Services/ExternalThumbnailService.swift:121` — 集合重建、排序、分组、清理或刷新。 `requests.removeAll()`
- `GladPhotos/Services/ExternalThumbnailService.swift:122` — 集合重建、排序、分组、清理或刷新。 `cache.removeAllObjects()`
- `GladPhotos/Services/PhotographyClassificationService.swift:79` — 集合重建、排序、分组、清理或刷新。 `pendingRecords.removeAll(keepingCapacity: true)`
- `GladPhotos/Views/ExternalMediaGridView.swift:473` — 集合重建、排序、分组、清理或刷新。 `navigationPath.removeAll { !currentURLs.contains($0.url) }`
- `GladPhotos/Views/ExternalMediaGridView.swift:673` — 集合重建、排序、分组、清理或刷新。 `selectedURLs.removeAll()`
- `GladPhotos/Views/PhotoDetailView.swift:201` — 集合重建、排序、分组、清理或刷新。 `previewRequestIDs.removeAll()`
- `GladPhotos/Views/PhotoDetailView.swift:202` — 集合重建、排序、分组、清理或刷新。 `previewRequestTokens.removeAll()`
- `GladPhotos/Views/PhotoDetailView.swift:207` — 集合重建、排序、分组、清理或刷新。 `cachedPreviewAssets.removeAll()`
- `GladPhotos/Views/PhotoGridView.swift:179` — 集合重建、排序、分组、清理或刷新。 `selectedIdentifiers.removeAll()`
- `GladPhotos/Views/PhotoGridView.swift:521` — 集合重建、排序、分组、清理或刷新。 `selectedIdentifiers.removeAll()`
- `GladPhotos/Views/PhotoGridView.swift:536` — 集合重建、排序、分组、清理或刷新。 `selectedIdentifiers.removeAll()`
- `GladPhotos/Views/ZoomablePhotoView.swift:582` — 集合重建、排序、分组、清理或刷新。 `lifecycleObservers.removeAll()`

## `sorted`

- `GladPhotos/Models/MediaDateIndex.swift:35` — 集合重建、排序、分组、清理或刷新。 `self.years = monthsByYear.keys.sorted(by: >)`
- `GladPhotos/Models/MediaDateIndex.swift:36` — 集合重建、排序、分组、清理或刷新。 `self.monthsByYear = monthsByYear.mapValues { $0.sorted() }`
- `GladPhotos/Services/ExternalMediaScanner.swift:80` — 集合重建、排序、分组、清理或刷新。 `let sortedItems = items.sorted {`
- `GladPhotos/Services/ExternalMediaScanner.swift:88` — 集合重建、排序、分组、清理或刷新。 `cache[folderKey] = sortedItems`
- `GladPhotos/Services/ExternalMediaScanner.swift:92` — 集合重建、排序、分组、清理或刷新。 `details: "items=\(sortedItems.count)"`
- `GladPhotos/Services/ExternalMediaScanner.swift:94` — 集合重建、排序、分组、清理或刷新。 `return sortedItems`
- `GladPhotos/Services/ExternalMediaScanner.swift:129` — 集合重建、排序、分组、清理或刷新。 `.sorted(by: { imagePreference($0.url) < imagePreference($1.url) })`
- `GladPhotos/Views/ExternalMediaGridView.swift:19` — 集合重建、排序、分组、清理或刷新。 `items: items.sorted {`
- `GladPhotos/Views/ExternalMediaGridView.swift:24` — 集合重建、排序、分组、清理或刷新。 `.sorted { $0.date < $1.date }`
- `GladPhotos/Views/ExternalMediaGridView.swift:485` — 集合重建、排序、分组、清理或刷新。 `items = newItems.sorted { lhs, rhs in`
- `GladPhotos/Views/PhotoGridView.swift:20` — 集合重建、排序、分组、清理或刷新。 `assets: items.sorted {`
- `GladPhotos/Views/PhotoGridView.swift:26` — 集合重建、排序、分组、清理或刷新。 `.sorted { $0.date < $1.date }`

## `grouping`

- `GladPhotos/Services/ExternalMediaScanner.swift:115` — 集合重建、排序、分组、清理或刷新。 `let groups = Dictionary(grouping: candidates) { candidate in`
- `GladPhotos/Views/ExternalMediaGridView.swift:12` — 集合重建、排序、分组、清理或刷新。 `let groupedItems = Dictionary(grouping: datedItems) { item in`
- `GladPhotos/Views/ExternalMediaGridView.swift:484` — 集合重建、排序、分组、清理或刷新。 `let groupingStart = ContinuousClock.now`
- `GladPhotos/Views/ExternalMediaGridView.swift:501` — 集合重建、排序、分组、清理或刷新。 `"grouping",`
- `GladPhotos/Views/ExternalMediaGridView.swift:502` — 集合重建、排序、分组、清理或刷新。 `duration: groupingStart.duration(to: .now),`
- `GladPhotos/Views/ExternalMediaGridView.swift:527` — 集合重建、排序、分组、清理或刷新。 `let groupingStart = ContinuousClock.now`
- `GladPhotos/Views/ExternalMediaGridView.swift:532` — 集合重建、排序、分组、清理或刷新。 `"grouping",`
- `GladPhotos/Views/ExternalMediaGridView.swift:533` — 集合重建、排序、分组、清理或刷新。 `duration: groupingStart.duration(to: .now),`
- `GladPhotos/Views/PhotoGridView.swift:13` — 集合重建、排序、分组、清理或刷新。 `let groupedAssets = Dictionary(grouping: datedAssets) { item in`

## `reload`

- 未找到。

## `refresh`

- `GladPhotos/ContentView.swift:131` — 集合重建、排序、分组、清理或刷新。 `let item = try photoLibrary.refreshAndFindAsset(`
- `GladPhotos/Services/PhotoLibraryService.swift:75` — 集合重建、排序、分组、清理或刷新。 `refreshAssets()`
- `GladPhotos/Services/PhotoLibraryService.swift:114` — 集合重建、排序、分组、清理或刷新。 `refreshAssets()`
- `GladPhotos/Services/PhotoLibraryService.swift:127` — 集合重建、排序、分组、清理或刷新。 `func refreshAndFindAsset(localIdentifier: String) throws -> PhotoAssetItem {`
- `GladPhotos/Services/PhotoLibraryService.swift:128` — 集合重建、排序、分组、清理或刷新。 `refreshAssets()`
- `GladPhotos/Services/PhotoLibraryService.swift:150` — 集合重建、排序、分组、清理或刷新。 `refreshAssets()`
- `GladPhotos/Services/PhotoLibraryService.swift:160` — 集合重建、排序、分组、清理或刷新。 `private func refreshAssets() {`
- `GladPhotos/Views/ExternalMediaGridView.swift:61` — 集合重建、排序、分组、清理或刷新。 `@State private var refreshID: UUID?`
- `GladPhotos/Views/ExternalMediaGridView.swift:164` — 集合重建、排序、分组、清理或刷新。 `Button("重试") { refresh() }`
- `GladPhotos/Views/ExternalMediaGridView.swift:266` — 集合重建、排序、分组、清理或刷新。 `refresh()`
- `GladPhotos/Views/ExternalMediaGridView.swift:279` — 集合重建、排序、分组、清理或刷新。 `.task(id: refreshID) {`
- `GladPhotos/Views/ExternalMediaGridView.swift:280` — 集合重建、排序、分组、清理或刷新。 `guard refreshID != nil else { return }`
- `GladPhotos/Views/ExternalMediaGridView.swift:421` — 集合重建、排序、分组、清理或刷新。 `private func refresh() {`
- `GladPhotos/Views/ExternalMediaGridView.swift:422` — 集合重建、排序、分组、清理或刷新。 `refreshID = UUID()`
- `GladPhotos/Views/ExternalMediaGridView.swift:444` — 集合重建、排序、分组、清理或刷新。 `refresh()`
- `GladPhotos/Views/ExternalMediaGridView.swift:457` — 集合重建、排序、分组、清理或刷新。 `refresh()`
- `GladPhotos/Views/ExternalMediaGridView.swift:564` — 集合重建、排序、分组、清理或刷新。 `refreshPhotographyDerivedState()`
- `GladPhotos/Views/ExternalMediaGridView.swift:648` — 集合重建、排序、分组、清理或刷新。 `private func refreshPhotographyDerivedState() {`

