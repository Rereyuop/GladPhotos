import Photos
import SwiftUI

struct PhotoDaySection: Identifiable {
    let date: Date
    let assets: [PhotoAssetItem]

    var id: Date { date }

    @MainActor
    static func make(from assets: [PhotoAssetItem]) -> [PhotoDaySection] {
        let calendar = Calendar.current
        let datedAssets = assets.filter { $0.asset.creationDate != nil }
        let groupedAssets = Dictionary(grouping: datedAssets) { item in
            calendar.startOfDay(for: item.asset.creationDate ?? .distantPast)
        }

        let sections = groupedAssets.map { date, items in
            PhotoDaySection(
                date: date,
                assets: items.sorted {
                    ($0.asset.creationDate ?? .distantPast)
                        < ($1.asset.creationDate ?? .distantPast)
                }
            )
        }
        .sorted { $0.date < $1.date }

        return sections
    }
}

struct PhotoGridView: View {
    let assets: [PhotoAssetItem]
    let imageService: PhotoImageService
    let daySections: [PhotoDaySection]
    let undatedAssets: [PhotoAssetItem]
    let daySectionIDs: [Date]
    let daySectionIndexByID: [Date: Int]
    let title: String
    let emptyTitle: String
    let monthDate: Date?
    @Binding var activeDay: Date?
    @Binding var pendingScrollTarget: Date?
    let scrollRequestID: UUID
    let deleteAssets: ([PhotoAssetItem]) async throws -> Void
    let compressAsset: (PHAsset) async throws -> CreatedCompressedPhoto

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var displayMode: PhotoGridDisplayMode = .originalRatio
    @State private var thumbnailWidth: CGFloat = 128
    @State private var isSelecting = false
    @State private var selectedIdentifiers = Set<String>()
    @State private var deletionError: String?
    @State private var detailItem: PhotoAssetItem?
    @State private var lastViewedIdentifier: String?
    @State private var showsPhotoInfo = false
    @State private var locationError: String?
    @State private var hasPerformedInitialScroll = false
    @State private var scrollCandidateDay: Date?
    @State private var activeDaySyncTask: Task<Void, Never>?
    @State private var latestSectionOffsets: [Date: CGFloat] = [:]
    @State private var activeDayThrottleTask: Task<Void, Never>?
    @State private var activeDayOffsetGeneration = 0
    @State private var preheatCoordinator = PhotoGridPreheatCoordinator()

    // The calendar follows section titles crossing this line. Keeping the line
    // below the top edge makes short adjacent sections behave naturally.
    private let activeDayReferenceY: CGFloat = 80
    private let activeDayHysteresis: CGFloat = 12
    private let activeDayOffsetThrottleDelay: Duration = .milliseconds(120)

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: thumbnailWidth,
                    maximum: thumbnailWidth * 1.5
                ),
                spacing: 2
            )
        ]
    }
    private let topAnchorID = "photo-grid-top"

    private var bottomItemID: String? {
        undatedAssets.last?.localIdentifier
            ?? daySections.last?.assets.last?.localIdentifier
    }

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "photo"
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            gridContent
                        }
                        .coordinateSpace(name: "photo-grid-scroll")
                        .onChange(of: pendingScrollTarget) {
                            scrollToSelectedDate(proxy: proxy)
                        }
                        .onChange(of: bottomItemID) {
                            guard !hasPerformedInitialScroll else { return }
                            scrollToLatest(proxy: proxy)
                        }
                        .task(id: scrollRequestID) {
                            await Task.yield()
                            scrollToLatest(proxy: proxy)
                        }
                        .onPreferenceChange(SectionHeaderOffsetKey.self) { offsets in
                            #if DEBUG
                            ScrollPerformanceDiagnostics.recordSectionOffsetPreference(
                                valueCount: offsets.count
                            )
                            ScrollPerformanceDiagnostics.recordSectionOffsetUpdateReceived()
                            #endif
                            consumeSectionOffsets(offsets)
                        }
                        .onScrollPhaseChange { _, phase in
                            guard phase == .idle else { return }
                            flushLatestSectionOffsetsFromIdle()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .principal) {
                        selectionTitleBarContent
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button(showsPhotoInfo ? "隐藏信息" : "显示信息") {
                        showsPhotoInfo.toggle()
                    }
                    .help("显示或隐藏照片时间和资源大小")
                    .pointingHandCursor()

                    selectionControls

                    Button(displayMode.title) {
                        displayMode = displayMode == .square
                            ? .originalRatio
                            : .square
                    }
                    .help("切换照片显示比例")
                    .pointingHandCursor()
                }
            }
            .focusedSceneValue(\.photoGridThumbnailWidth, $thumbnailWidth)
            .onExitCommand {
                guard isSelecting else {
                    return
                }

                cancelSelection()
            }
            .overlay {
                if let item = detailItem {
                PhotoDetailView(
                    item: item,
                    assets: assets,
                    imageService: imageService,
                    deleteAssets: deleteAssets,
                    compressAsset: compressAsset,
                    onCurrentItemChanged: { item in
                        lastViewedIdentifier = item.localIdentifier
                    },
                    onClose: { detailItem = nil }
                )
                .ignoresSafeArea()
                .zIndex(100)
                }
            }
            .alert("删除失败", isPresented: deletionErrorBinding) {
                Button("好", role: .cancel) {
                    deletionError = nil
                }
                .pointingHandCursor()
            } message: {
                Text(deletionError ?? "")
            }
            .alert(ApplePhotosLocator.failureMessage, isPresented: locationErrorBinding) {
                Button("好", role: .cancel) {
                    locationError = nil
                }
                .pointingHandCursor()
            }
            .onAppear {
                preheatCoordinator.configure(
                    imageService: imageService,
                    assets: assets,
                    displayMode: displayMode,
                    thumbnailWidth: thumbnailWidth
                )
            }
            .onChange(of: assets) {
                let currentIdentifiers = Set(assets.map(\.localIdentifier))
                selectedIdentifiers.formIntersection(currentIdentifiers)
                preheatCoordinator.replaceAssets(assets)

                if assets.isEmpty {
                    isSelecting = false
                    selectedIdentifiers.removeAll()
                }
            }
            .onChange(of: daySectionIDs) {
                resetActiveDayOffsetTracking()
                preheatCoordinator.resetPreheating(resetDiagnostics: true)
            }
            .onChange(of: displayMode) {
                preheatCoordinator.updateRenderingConfiguration(
                    displayMode: displayMode,
                    thumbnailWidth: thumbnailWidth
                )
            }
            .onChange(of: thumbnailWidth) {
                preheatCoordinator.updateRenderingConfiguration(
                    displayMode: displayMode,
                    thumbnailWidth: thumbnailWidth
                )
            }
            .onDisappear {
                activeDaySyncTask?.cancel()
                activeDaySyncTask = nil
                resetActiveDayOffsetTracking()
                preheatCoordinator.resetPreheating(resetDiagnostics: true)
            }
        }
    }

    private var selectionTitleBarContent: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.headline)

            Button(action: {}) {
                Text("已选择 \(selectedIdentifiers.count) 项")
                    .monospacedDigit()
                    .contentTransition(
                        .numericText(value: Double(selectedIdentifiers.count))
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.2),
                value: selectedIdentifiers.count
            )
            .accessibilityLabel("已选择 \(selectedIdentifiers.count) 项")
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if isSelecting {
            Button("删除", role: .destructive) {
                Task {
                    await deleteSelectedAssets()
                }
            }
            .disabled(selectedIdentifiers.isEmpty)
            .pointingHandCursor()

            Button("取消") {
                cancelSelection()
            }
            .pointingHandCursor()
        } else {
            Button(isSelecting ? "取消" : "选择") {
                isSelecting = true
            }
            .pointingHandCursor()
        }
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { isPresented in
                if !isPresented {
                    deletionError = nil
                }
            }
        )
    }

    private var locationErrorBinding: Binding<Bool> {
        Binding(
            get: { locationError != nil },
            set: { isPresented in
                if !isPresented {
                    locationError = nil
                }
            }
        )
    }

    private func photoButton(for item: PhotoAssetItem) -> some View {
        PhotoGridCellView(
            item: item,
            imageService: imageService,
            displayMode: displayMode,
            thumbnailWidth: thumbnailWidth,
            preheatCoordinator: preheatCoordinator,
            isSelected: selectedIdentifiers.contains(item.localIdentifier),
            showsPhotoInfo: showsPhotoInfo,
            openDetail: {
                lastViewedIdentifier = item.localIdentifier
                detailItem = item
            },
            toggleSelection: {
                toggleSelection(for: item)
            },
            locateInApplePhotos: {
                locateInApplePhotos(item)
            }
        )
    }

    private var gridContent: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Color.clear
                .frame(height: 0)
                .id(topAnchorID)

            ForEach(daySections) { section in
                daySectionView(section)
            }

            if !undatedAssets.isEmpty {
                undatedSectionView
            }
        }
        .padding(2)
    }

    @ViewBuilder
    private func daySectionView(_ section: PhotoDaySection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            selectionSectionHeader(
                title: sectionTitle(for: section.date),
                items: section.assets
            )
                .id(section.id)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SectionHeaderOffsetKey.self,
                            value: [
                                section.id: proxy.frame(
                                    in: .named("photo-grid-scroll")
                                ).minY
                            ]
                        )
                    }
                }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(section.assets, id: \.localIdentifier) { item in
                    photoButton(for: item)
                }
            }
        }
    }

    private var undatedSectionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            selectionSectionHeader(title: "未知日期", items: undatedAssets)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(undatedAssets, id: \.localIdentifier) { item in
                    photoButton(for: item)
                }
            }
        }
    }

    private func sectionTitle(for date: Date) -> String {
        date.formatted(
            .dateTime.month(.wide).day().locale(.gladPhotosChinese)
        )
    }

    private func selectionSectionHeader(
        title: String,
        items: [PhotoAssetItem]
    ) -> some View {
        PhotoSectionSelectionHeader(
            title: title,
            selectAll: { selectAll(items) },
            invertSelection: { invertSelection(in: items) }
        )
    }

    private func scrollToSelectedDate(proxy: ScrollViewProxy) {
        guard let pendingScrollTarget else {
            return
        }

        let target = Calendar.current.startOfDay(for: pendingScrollTarget)

        guard daySectionIndexByID[target] != nil else {
            return
        }

        resetActiveDayOffsetTracking()
        scrollCandidateDay = target
        activeDaySyncTask?.cancel()
        if activeDay != target {
            activeDay = target
            #if DEBUG
            ScrollPerformanceDiagnostics.recordVisibleDatePublished()
            #endif
        }

        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .top)
        }

        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(300))
            }

            guard
                let currentPendingTarget = self.pendingScrollTarget,
                Calendar.current.startOfDay(for: currentPendingTarget) == target
            else {
                return
            }

            self.pendingScrollTarget = nil
        }
    }

    private func consumeSectionOffsets(_ offsets: [Date: CGFloat]) {
        latestSectionOffsets = offsets

        guard pendingScrollTarget == nil else {
            return
        }

        guard activeDayThrottleTask == nil else {
            #if DEBUG
            ScrollPerformanceDiagnostics.recordSectionOffsetUpdateCoalesced()
            #endif
            return
        }

        let generation = activeDayOffsetGeneration
        activeDayThrottleTask = Task { @MainActor in
            try? await Task.sleep(for: activeDayOffsetThrottleDelay)
            guard !Task.isCancelled, generation == activeDayOffsetGeneration else {
                return
            }

            processLatestSectionOffsets(generation: generation)
        }
    }

    private func processLatestSectionOffsets(generation: Int) {
        guard generation == activeDayOffsetGeneration else {
            return
        }

        activeDayThrottleTask = nil
        guard !latestSectionOffsets.isEmpty else {
            return
        }

        #if DEBUG
        ScrollPerformanceDiagnostics.recordSectionOffsetUpdateProcessed()
        #endif
        updateActiveDay(from: latestSectionOffsets)
    }

    private func flushLatestSectionOffsetsFromIdle() {
        activeDayThrottleTask?.cancel()
        activeDayThrottleTask = nil

        guard pendingScrollTarget == nil, !latestSectionOffsets.isEmpty else {
            return
        }

        #if DEBUG
        ScrollPerformanceDiagnostics.recordSectionOffsetIdleFlush()
        ScrollPerformanceDiagnostics.recordSectionOffsetUpdateProcessed()
        #endif
        updateActiveDay(from: latestSectionOffsets)
    }

    private func resetActiveDayOffsetTracking() {
        activeDayOffsetGeneration += 1
        activeDayThrottleTask?.cancel()
        activeDayThrottleTask = nil
        latestSectionOffsets = [:]
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard let bottomItemID else { return }
        withAnimation(hasPerformedInitialScroll && !reduceMotion
            ? .snappy(duration: 0.25)
            : nil) {
            proxy.scrollTo(bottomItemID, anchor: .bottom)
        }
        hasPerformedInitialScroll = true
    }

    private func updateActiveDay(from offsets: [Date: CGFloat]) {
        // A programmatic jump owns the selection until its animation completes.
        // The task in scrollToSelectedDate synchronizes the highlight afterwards.
        guard pendingScrollTarget == nil else {
            return
        }

        let halfHysteresis = activeDayHysteresis / 2
        let candidates = activeDayCandidates(
            from: offsets,
            thresholds: (
                center: activeDayReferenceY,
                downward: activeDayReferenceY - halfHysteresis,
                upward: activeDayReferenceY + halfHysteresis
            )
        )

        let newCandidate: Date?
        if let activeDay,
           let activeIndex = daySectionIndexByID[activeDay] {
            if let downwardCandidate = candidates.downward,
               let candidateIndex = daySectionIndexByID[downwardCandidate],
               candidateIndex > activeIndex {
                newCandidate = downwardCandidate
            } else if let upwardCandidate = candidates.upward,
                      let candidateIndex = daySectionIndexByID[upwardCandidate],
                      candidateIndex < activeIndex {
                newCandidate = upwardCandidate
            } else {
                newCandidate = nil
            }
        } else {
            newCandidate = candidates.center
        }

        guard let newCandidate else {
            return
        }

        updateScrollCandidate(newCandidate)
    }

    private func updateScrollCandidate(_ candidate: Date) {
        guard scrollCandidateDay != candidate else {
            return
        }

        scrollCandidateDay = candidate
        guard activeDay != candidate else {
            return
        }

        #if DEBUG
        ScrollPerformanceDiagnostics.recordVisibleDateCandidate()
        #endif

        activeDaySyncTask?.cancel()
        activeDaySyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard
                !Task.isCancelled,
                pendingScrollTarget == nil,
                scrollCandidateDay == candidate,
                activeDay != candidate
            else {
                return
            }

            activeDay = candidate
            #if DEBUG
            ScrollPerformanceDiagnostics.recordVisibleDatePublished()
            #endif
        }
    }

    /// Returns the last section title that crossed the supplied line. If the
    /// first title has not crossed yet, it is the natural initial selection.
    private func activeDayCandidates(
        from offsets: [Date: CGFloat],
        thresholds: (center: CGFloat, downward: CGFloat, upward: CGFloat)
    ) -> (center: Date?, downward: Date?, upward: Date?) {
        var center = ActiveDayCandidateTracker(threshold: thresholds.center)
        var downward = ActiveDayCandidateTracker(threshold: thresholds.downward)
        var upward = ActiveDayCandidateTracker(threshold: thresholds.upward)

        for (date, offset) in offsets {
            center.observe(date: date, offset: offset)
            downward.observe(date: date, offset: offset)
            upward.observe(date: date, offset: offset)
        }

        return (
            center: center.candidate,
            downward: downward.candidate,
            upward: upward.candidate
        )
    }

    private func toggleSelection(for item: PhotoAssetItem) {
        if selectedIdentifiers.contains(item.localIdentifier) {
            selectedIdentifiers.remove(item.localIdentifier)
        } else {
            isSelecting = true
            selectedIdentifiers.insert(item.localIdentifier)
        }
    }

    private func selectAll(_ items: [PhotoAssetItem]) {
        isSelecting = true
        selectedIdentifiers.formUnion(items.map(\.localIdentifier))
    }

    private func invertSelection(in items: [PhotoAssetItem]) {
        isSelecting = true

        for identifier in items.map(\.localIdentifier) {
            if selectedIdentifiers.contains(identifier) {
                selectedIdentifiers.remove(identifier)
            } else {
                selectedIdentifiers.insert(identifier)
            }
        }
    }

    private func cancelSelection() {
        isSelecting = false
        selectedIdentifiers.removeAll()
    }

    private func locateInApplePhotos(_ item: PhotoAssetItem) {
        guard ApplePhotosLocator.open(item.asset) else {
            locationError = ApplePhotosLocator.failureMessage
            return
        }
    }

    private func deleteSelectedAssets() async {
        let itemsToDelete = assets.filter {
            selectedIdentifiers.contains($0.localIdentifier)
        }
        let selectedIdentifiersSnapshot = selectedIdentifiers

        guard !itemsToDelete.isEmpty else {
            return
        }

        do {
            try await deleteAssets(itemsToDelete)
            selectedIdentifiers.removeAll()
            isSelecting = false
        } catch {
            selectedIdentifiers = selectedIdentifiersSnapshot
            if !error.isPhotoLibraryUserCancellation {
                deletionError = error.localizedDescription
            }
        }
    }

}

private struct PhotoSectionSelectionHeader: View {
    let title: String
    let selectAll: () -> Void
    let invertSelection: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))

            HStack(spacing: 7) {
                Button(action: selectAll) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("选择这个日期的全部照片")
                .pointingHandCursor()

                Button(action: invertSelection) {
                    Label("反选", systemImage: "circle.lefthalf.filled")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .help("反选这个日期的照片")
                .pointingHandCursor()
            }
            .opacity(isHovering ? 1 : 0)
            .scaleEffect(isHovering ? 1 : 0.92, anchor: .leading)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)

            Spacer(minLength: 0)
        }
        .frame(height: 27, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                isHovering = hovering
            }
        }
    }
}

private struct ActiveDayCandidateTracker {
    let threshold: CGFloat
    private var crossed: (date: Date, offset: CGFloat)?
    private var upcoming: (date: Date, offset: CGFloat)?

    var candidate: Date? {
        crossed?.date ?? upcoming?.date
    }

    mutating func observe(date: Date, offset: CGFloat) {
        if offset <= threshold {
            if crossed == nil || offset > (crossed?.offset ?? -.infinity) {
                crossed = (date, offset)
            }
        } else if upcoming == nil || offset < (upcoming?.offset ?? .infinity) {
            upcoming = (date, offset)
        }
    }
}

private struct SectionHeaderOffsetKey: PreferenceKey {
    static var defaultValue: [Date: CGFloat] = [:]

    static func reduce(
        value: inout [Date: CGFloat],
        nextValue: () -> [Date: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
