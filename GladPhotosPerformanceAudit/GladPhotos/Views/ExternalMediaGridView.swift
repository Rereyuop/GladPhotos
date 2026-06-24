import SwiftUI

private struct ExternalMediaDaySection: Identifiable {
    let date: Date
    let items: [ExternalMediaItem]

    var id: Date { date }

    static func make(from items: [ExternalMediaItem]) -> [ExternalMediaDaySection] {
        let calendar = Calendar.current
        let datedItems = items.filter { $0.displayDate != nil }
        let groupedItems = Dictionary(grouping: datedItems) { item in
            calendar.startOfDay(for: item.displayDate ?? .distantPast)
        }

        return groupedItems.map { date, items in
            ExternalMediaDaySection(
                date: date,
                items: items.sorted {
                    ($0.displayDate ?? .distantPast) < ($1.displayDate ?? .distantPast)
                }
            )
        }
        .sorted { $0.date < $1.date }
    }
}

private struct PhotographyCounts {
    var all = 0
    var photography = 0
    var nonPhotography = 0
    var unknown = 0

    func count(for filter: PhotographyFilter) -> Int {
        switch filter {
        case .all: all
        case .photography: photography
        case .nonPhotography: nonPhotography
        case .unknown: unknown
        }
    }
}

struct ExternalMediaGridView: View {
    let folder: ExternalFolderItem
    let scanner: ExternalMediaScanner
    let thumbnailService: ExternalThumbnailService
    let recognitionStateStore: ExternalFolderRecognitionStateStore
    let initialItems: [ExternalMediaItem]
    let monthDate: Date?
    @Binding var activeDay: Date?
    @Binding var pendingScrollTarget: Date?
    let scrollRequestID: UUID
    let onItemsChanged: ([ExternalMediaItem]) -> Void
    let reauthorize: () -> Void
    let removeFolder: () -> Void

    @State private var items: [ExternalMediaItem] = []
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var refreshID: UUID?
    @State private var navigationPath: [ExternalMediaItem] = []
    @State private var detailImageItem: ExternalMediaItem?
    @State private var displayMode: PhotoGridDisplayMode = .originalRatio
    @State private var thumbnailWidth: CGFloat = 128
    @State private var showsMediaInfo = false
    @State private var folderWatcher = ExternalFolderWatcher()
    @State private var changeRefreshTask: Task<Void, Never>?
    @State private var itemsByMonth: [MediaMonth: [ExternalMediaItem]] = [:]
    @State private var daySections: [ExternalMediaDaySection] = []
    @State private var undatedItems: [ExternalMediaItem] = []
    @State private var hasPerformedInitialScroll = false
    @State private var photographyRecords: [String: PhotographyAnalysisRecord] = [:]
    @State private var didLoadPhotographyRecords = false
    @State private var photographyFilter: PhotographyFilter = .all
    @State private var analysisProgress: PhotographyClassificationService.Progress?
    @State private var analysisSummary: String?
    @State private var isSelecting = false
    @State private var selectedURLs = Set<URL>()
    @State private var photographyCounts = PhotographyCounts()
    @State private var tagStore: PhotographyTagStore
    @State private var classificationService: PhotographyClassificationService

    init(
        folder: ExternalFolderItem,
        scanner: ExternalMediaScanner,
        thumbnailService: ExternalThumbnailService,
        recognitionStateStore: ExternalFolderRecognitionStateStore,
        initialItems: [ExternalMediaItem],
        monthDate: Date?,
        activeDay: Binding<Date?>,
        pendingScrollTarget: Binding<Date?>,
        scrollRequestID: UUID,
        onItemsChanged: @escaping ([ExternalMediaItem]) -> Void,
        reauthorize: @escaping () -> Void,
        removeFolder: @escaping () -> Void
    ) {
        self.folder = folder
        self.scanner = scanner
        self.thumbnailService = thumbnailService
        self.recognitionStateStore = recognitionStateStore
        self.initialItems = initialItems
        self.monthDate = monthDate
        _activeDay = activeDay
        _pendingScrollTarget = pendingScrollTarget
        self.scrollRequestID = scrollRequestID
        self.onItemsChanged = onItemsChanged
        self.reauthorize = reauthorize
        self.removeFolder = removeFolder
        let store = PhotographyTagStore(folderID: folder.id)
        _tagStore = State(initialValue: store)
        _classificationService = State(
            initialValue: PhotographyClassificationService(store: store)
        )
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: thumbnailWidth, maximum: thumbnailWidth * 1.5),
                spacing: 2
            )
        ]
    }

    private var recognitionState: ExternalFolderRecognitionState {
        recognitionStateStore.state(for: folder.id)
    }

    private var unfilteredDisplayedItems: [ExternalMediaItem] {
        monthDate.map { itemsByMonth[MediaMonth($0)] ?? [] } ?? items
    }

    private var displayedItems: [ExternalMediaItem] {
        guard photographyFilter != .all else { return unfilteredDisplayedItems }
        return unfilteredDisplayedItems.filter { item in
            guard item.mediaType != .video else { return false }
            return photographyFilter.includes(record(for: item)?.effectiveTag ?? .unknown)
        }
    }

    private var bottomItemID: URL? {
        undatedItems.last?.id ?? daySections.last?.items.last?.id
    }

    private var imageItems: [ExternalMediaItem] {
        daySections.flatMap(\.items).filter { $0.mediaType != .video }
            + undatedItems.filter { $0.mediaType != .video }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if !folder.accessState.isAvailable {
                    unavailableContent
                } else if isScanning && items.isEmpty {
                    ProgressView("正在扫描文件夹…")
                } else if let scanError, items.isEmpty {
                    ContentUnavailableView {
                        Label("无法读取文件夹", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(scanError)
                    } actions: {
                        Button("重试") { refresh() }
                            .pointingHandCursor()
                    }
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "没有支持的媒体",
                        systemImage: "photo.on.rectangle",
                        description: Text("支持 HEIC、HEIF、JPG、JPEG、PNG、MOV、MP4 和 M4V。")
                    )
                } else if displayedItems.isEmpty {
                    ContentUnavailableView("当月没有媒体", systemImage: "calendar")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            gridContent
                        }
                        .onScrollPhaseChange { _, newPhase in
                            classificationService.setPaused(newPhase.isScrolling)
                        }
                        .onChange(of: pendingScrollTarget) {
                            scrollToSelectedDate(proxy: proxy)
                        }
                        .onChange(of: bottomItemID) {
                            guard !hasPerformedInitialScroll else { return }
                            scrollToLatest(proxy: proxy)
                        }
                        .task(id: scrollRequestID) {
                            guard initialItems.isEmpty else { return }
                            await Task.yield()
                            scrollToLatest(proxy: proxy)
                        }
                    }
                }
            }
            .navigationTitle(folder.displayName)
            .overlay {
                if let item = detailImageItem {
                    ExternalImageDetailView(
                        item: item,
                        items: imageItems,
                        thumbnailService: thumbnailService,
                        deleteItem: deleteItem,
                        onClose: { detailImageItem = nil }
                    )
                    .ignoresSafeArea()
                    .zIndex(100)
                }
            }
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .principal) {
                        Text("已选择 \(selectedURLs.count) 项")
                            .monospacedDigit()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if isScanning && !items.isEmpty {
                        ProgressView().controlSize(.small)
                    }

                    Button(analysisButtonTitle) {
                        startAnalysis()
                    }
                    .buttonStyle(.bordered)
                    .disabled(analysisProgress != nil || imageItemsForAnalysis.isEmpty)
                    .help(analysisSummary ?? "识别当前外部文件夹中新增、修改或未识别的图片")
                    .pointingHandCursor()

                    if let analysisSummary, analysisProgress == nil {
                        Text(analysisSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if recognitionState.hasRecognitionResults {
                        Button(recognitionState.showsRecognitionInfo ? "隐藏识别" : "显示识别") {
                            toggleRecognitionInfo()
                        }
                        .pointingHandCursor()
                    }

                    if recognitionState.showsRecognitionInfo {
                        Menu {
                            ForEach(PhotographyFilter.allCases) { filter in
                                Button(filterTitle(filter)) { photographyFilter = filter }
                            }
                        } label: {
                            Label(filterTitle(photographyFilter), systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .help("按摄影标签筛选，不会触发识别")
                        .pointingHandCursor()
                    }

                    selectionControls

                    Button(showsMediaInfo ? "隐藏信息" : "显示信息") {
                        showsMediaInfo.toggle()
                    }
                    .help("显示或隐藏媒体时间和文件大小")
                    .pointingHandCursor()

                    Button("刷新", systemImage: "arrow.clockwise") {
                        refresh()
                    }
                    .disabled(isScanning || !folder.accessState.isAvailable)
                    .pointingHandCursor()

                    Button(displayMode.title) {
                        displayMode = displayMode == .square ? .originalRatio : .square
                    }
                    .help("切换照片显示比例")
                    .pointingHandCursor()
                }
            }
            .focusedSceneValue(\.photoGridThumbnailWidth, $thumbnailWidth)
            .task(id: refreshID) {
                guard refreshID != nil else { return }
                await scan()
            }
            .task(id: folder.url) {
                await restoreCacheAndWatch()
            }
            .task(id: folder.id) {
                if recognitionState.hasRecognitionResults,
                   recognitionState.showsRecognitionInfo {
                    await loadPhotographyRecords()
                }
            }
            .onChange(of: monthDate) {
                rebuildDisplayedSections()
            }
            .onChange(of: photographyFilter) {
                if photographyFilter == .all {
                    rebuildDisplayedSections()
                } else {
                    Task { await loadPhotographyRecords() }
                }
            }
            .onDisappear {
                changeRefreshTask?.cancel()
                classificationService.cancel()
                folderWatcher.stop()
                if let folderURL = folder.url {
                    thumbnailService.cancelRequests(in: folderURL)
                }
            }
            .onExitCommand {
                if isSelecting { cancelSelection() }
            }
            .navigationDestination(for: ExternalMediaItem.self) { item in
                switch item.mediaType {
                case .image, .livePhoto:
                    ExternalImageDetailView(
                        item: item,
                        items: imageItems,
                        thumbnailService: thumbnailService,
                        deleteItem: deleteItem
                    )
                case .video:
                    ExternalVideoDetailView(item: item)
                }
            }
        }
    }

    private var gridContent: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(daySections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(sectionTitle(for: section.date))
                        .font(.system(size: 18, weight: .semibold))
                        .id(section.id)

                    mediaGrid(section.items)
                }
            }

            if !undatedItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("未知日期")
                        .font(.system(size: 18, weight: .semibold))

                    mediaGrid(undatedItems)
                }
            }
        }
        .padding(2)
    }

    private func mediaGrid(_ mediaItems: [ExternalMediaItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(mediaItems) { item in
                ExternalMediaGridCell(
                    item: item,
                    thumbnailService: thumbnailService,
                    displayMode: displayMode,
                    thumbnailWidth: thumbnailWidth,
                    showsMediaInfo: showsMediaInfo,
                    showsRecognitionInfo: recognitionState.showsRecognitionInfo,
                    record: recognitionState.showsRecognitionInfo ? record(for: item) : nil,
                    isSelecting: isSelecting,
                    isSelected: selectedURLs.contains(item.url),
                    open: {
                        if item.mediaType == .video {
                            navigationPath.append(item)
                        } else {
                            detailImageItem = item
                        }
                    },
                    toggleSelection: { toggleSelection(item) },
                    setManualTag: { setManualTag($0, for: [item]) }
                )
                .equatable()
            }
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if isSelecting {
            if recognitionState.showsRecognitionInfo {
                Menu("批量标签") {
                    Button("设为摄影") { setManualTag(.photography, for: selectedImageItems) }
                    Button("设为非摄影") { setManualTag(.nonPhotography, for: selectedImageItems) }
                    Divider()
                    Button("清除手动标签") { setManualTag(nil, for: selectedImageItems) }
                }
                .disabled(selectedImageItems.isEmpty)
            }

            Button("取消") { cancelSelection() }
        } else {
            Button("选择") { isSelecting = true }
        }
    }

    private var unavailableContent: some View {
        ContentUnavailableView {
            Label("文件夹不可访问", systemImage: "folder.badge.questionmark")
        } description: {
            if case .unavailable(let message) = folder.accessState {
                Text(message)
            }
        } actions: {
            Button("重新授权", action: reauthorize)
                .pointingHandCursor()
            Button("移除", role: .destructive, action: removeFolder)
                .pointingHandCursor()
        }
    }

    private func sectionTitle(for date: Date) -> String {
        date.formatted(
            .dateTime.month(.wide).day().locale(.gladPhotosChinese)
        )
    }

    private func refresh() {
        refreshID = UUID()
    }

    private func restoreCacheAndWatch() async {
        guard folder.accessState.isAvailable, let url = folder.url else { return }
        if !initialItems.isEmpty {
            restoreItems(initialItems)
        } else if let cached = await scanner.cachedItems(for: url) {
            setItems(cached)
        } else {
            await scan()
        }
        folderWatcher.start(folderURL: url) {
            scheduleChangeRefresh()
        }
    }

    private func scheduleChangeRefresh() {
        changeRefreshTask?.cancel()
        changeRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func deleteItem(_ item: ExternalMediaItem) async throws {
        do {
            try await ExternalMediaDeletionService.moveToTrash(item)
            let sourceURLs = Set(item.sourceURLs)
            setItems(items.filter { !sourceURLs.contains($0.url) })
            if let folderURL = folder.url {
                await scanner.removeCachedItems(at: sourceURLs, from: folderURL)
            }
        } catch {
            refresh()
            throw error
        }
    }

    private func scan() async {
        guard folder.accessState.isAvailable, let url = folder.url else { return }

        if items.isEmpty, let cached = await scanner.cachedItems(for: url) {
            setItems(cached)
        }
        isScanning = true
        scanError = nil
        do {
            setItems(try await scanner.scan(folderURL: url))
            let currentURLs = Set(items.map(\.url))
            navigationPath.removeAll { !currentURLs.contains($0.url) }
        } catch is CancellationError {
            isScanning = false
            return
        } catch {
            scanError = error.localizedDescription
        }
        isScanning = false
    }

    private func setItems(_ newItems: [ExternalMediaItem]) {
        let groupingStart = ContinuousClock.now
        items = newItems.sorted { lhs, rhs in
            switch (lhs.displayDate, rhs.displayDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.url.path < rhs.url.path
            }
        }
        rebuildMonthCache()
        rebuildDisplayedSections()
        onItemsChanged(items)
        PerformanceLogger.log(
            "grouping",
            duration: groupingStart.duration(to: .now),
            details: "setItems count=\(items.count)"
        )
    }

    private func restoreItems(_ cachedItems: [ExternalMediaItem]) {
        // A returning folder already has normalized data in ContentView. Avoid a
        // second sort/index publication and, crucially, suppress the automatic
        // jump to the last cell that forces layout of a very large nested grid.
        hasPerformedInitialScroll = true
        items = cachedItems
        rebuildMonthCache()
        rebuildDisplayedSections()
    }

    private func rebuildMonthCache() {
        var cache: [MediaMonth: [ExternalMediaItem]] = [:]
        for item in items {
            guard let date = item.displayDate else { continue }
            cache[MediaMonth(date), default: []].append(item)
        }
        itemsByMonth = cache
    }

    private func rebuildDisplayedSections() {
        let groupingStart = ContinuousClock.now
        let visibleItems = displayedItems
        daySections = ExternalMediaDaySection.make(from: visibleItems)
        undatedItems = visibleItems.filter { $0.displayDate == nil }
        PerformanceLogger.log(
            "grouping",
            duration: groupingStart.duration(to: .now),
            details: "visible=\(visibleItems.count) sections=\(daySections.count)"
        )
    }

    private var imageItemsForAnalysis: [ExternalMediaItem] {
        items.filter { $0.mediaType != .video }
    }

    private var selectedImageItems: [ExternalMediaItem] {
        items.filter { selectedURLs.contains($0.url) && $0.mediaType != .video }
    }

    private func record(for item: ExternalMediaItem) -> PhotographyAnalysisRecord? {
        photographyRecords[item.url.standardizedFileURL.path]
    }

    private var analysisButtonTitle: String {
        if let progress = analysisProgress {
            return "识别中 \(progress.completed)/\(progress.total)"
        }
        return "识别"
    }

    private func filterTitle(_ filter: PhotographyFilter) -> String {
        "\(filter.title) \(photographyCounts.count(for: filter))"
    }

    private func loadPhotographyRecords() async {
        photographyRecords = await tagStore.records(for: imageItemsForAnalysis)
        didLoadPhotographyRecords = true
        refreshPhotographyDerivedState()
    }

    private func startAnalysis() {
        analysisSummary = nil
        analysisProgress = .init(completed: 0, total: imageItemsForAnalysis.count)
        Task {
            if !didLoadPhotographyRecords { await loadPhotographyRecords() }
            beginAnalysis()
        }
    }

    private func beginAnalysis() {
        classificationService.analyze(
            items: imageItemsForAnalysis,
            records: photographyRecords
        ) { progress, records in
            analysisProgress = progress
            if !records.isEmpty {
                recognitionStateStore.recordResults(for: folder.id)
            }
            applyPhotographyRecords(records)
        } onCompletion: {
            analysisProgress = nil
            analysisSummary = "摄影 \(photographyCounts.photography)，非摄影 \(photographyCounts.nonPhotography)，未识别 \(photographyCounts.unknown)"
        }
    }

    private func toggleRecognitionInfo() {
        let shows = !recognitionState.showsRecognitionInfo
        recognitionStateStore.setShowsRecognitionInfo(shows, for: folder.id)
        if shows, !didLoadPhotographyRecords {
            Task { await loadPhotographyRecords() }
        }
    }

    private func setManualTag(_ tag: PhotographyTag?, for targetItems: [ExternalMediaItem]) {
        Task {
            let updates = await tagStore.setManualTag(tag, for: targetItems)
            applyPhotographyRecords(Array(updates.values))
        }
    }

    private func applyPhotographyRecords(_ records: [PhotographyAnalysisRecord]) {
        guard !records.isEmpty else { return }

        var updatedRecords = photographyRecords
        var updatedCounts = photographyCounts
        var needsSectionRebuild = false

        for record in records {
            let oldTag = updatedRecords[record.filePath]?.effectiveTag ?? .unknown
            let newTag = record.effectiveTag
            updatedRecords[record.filePath] = record

            guard oldTag != newTag else { continue }
            adjustCount(for: oldTag, by: -1, counts: &updatedCounts)
            adjustCount(for: newTag, by: 1, counts: &updatedCounts)

            if photographyFilter != .all,
               photographyFilter.includes(oldTag) != photographyFilter.includes(newTag) {
                needsSectionRebuild = true
            }
        }

        // Publish once per batch. In the common "all" mode the item collection is
        // unchanged, so rebuilding every day section would only invalidate layout.
        photographyRecords = updatedRecords
        photographyCounts = updatedCounts
        if needsSectionRebuild { rebuildDisplayedSections() }
    }

    private func adjustCount(
        for tag: PhotographyTag,
        by delta: Int,
        counts: inout PhotographyCounts
    ) {
        switch tag {
        case .photography: counts.photography += delta
        case .nonPhotography: counts.nonPhotography += delta
        case .unknown: counts.unknown += delta
        }
    }

    private func refreshPhotographyDerivedState() {
        var counts = PhotographyCounts()
        for item in imageItemsForAnalysis {
            counts.all += 1
            switch record(for: item)?.effectiveTag ?? .unknown {
            case .photography: counts.photography += 1
            case .nonPhotography: counts.nonPhotography += 1
            case .unknown: counts.unknown += 1
            }
        }
        photographyCounts = counts
        if photographyFilter != .all { rebuildDisplayedSections() }
    }

    private func toggleSelection(_ item: ExternalMediaItem) {
        isSelecting = true
        if selectedURLs.contains(item.url) {
            selectedURLs.remove(item.url)
        } else {
            selectedURLs.insert(item.url)
        }
    }

    private func cancelSelection() {
        isSelecting = false
        selectedURLs.removeAll()
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard let bottomItemID else { return }
        proxy.scrollTo(bottomItemID, anchor: .bottom)
        hasPerformedInitialScroll = true
    }

    private func scrollToSelectedDate(proxy: ScrollViewProxy) {
        guard let pendingScrollTarget else { return }
        let target = Calendar.current.startOfDay(for: pendingScrollTarget)
        guard let itemID = daySections.first(where: { $0.id == target })?.items.last?.id else {
            return
        }
        proxy.scrollTo(itemID, anchor: .bottom)
        activeDay = target
        self.pendingScrollTarget = nil
    }
}
