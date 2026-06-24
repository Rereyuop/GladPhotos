import AppKit
import Photos
import SwiftUI

struct NativePhotoGridStats: Equatable {
    var createdItems = 0
    var reusedItems = 0
    var maxVisibleItems = 0
    var reloadDataCount = 0
}

struct NativePhotoCollectionView: NSViewRepresentable {
    let daySections: [PhotoDaySection]
    let undatedAssets: [PhotoAssetItem]
    let allAssets: [PhotoAssetItem]
    let imageService: PhotoImageService
    let displayMode: PhotoGridDisplayMode
    let thumbnailWidth: CGFloat
    let showsPhotoInfo: Bool
    @Binding var isSelecting: Bool
    let reduceMotion: Bool
    let scrollRequestID: UUID
    @Binding var selectedIdentifiers: Set<String>
    @Binding var activeDay: Date?
    @Binding var pendingScrollTarget: Date?
    @Binding var stats: NativePhotoGridStats
    let openDetail: (PhotoAssetItem) -> Void
    let locateInApplePhotos: (PhotoAssetItem) -> Void
    let selectAll: ([PhotoAssetItem]) -> Void
    let invertSelection: ([PhotoAssetItem]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 0, left: 2, bottom: 16, right: 2)

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(
            NativePhotoCollectionViewItem.self,
            forItemWithIdentifier: NativePhotoCollectionViewItem.identifier
        )
        collectionView.register(
            NativePhotoSectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: NativePhotoSectionHeaderView.identifier
        )

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.collectionView = collectionView
        context.coordinator.scrollView = scrollView
        context.coordinator.reloadData(reason: "make")
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.stopAllPreheating()
        coordinator.cancelPendingTasks()
    }
}

extension NativePhotoCollectionView {
    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        private var parent: NativePhotoCollectionView
        weak var collectionView: NSCollectionView?
        weak var scrollView: NSScrollView?

        private var sections: [NativePhotoGridSection] = []
        private var allItems: [PhotoAssetItem] = []
        private var flatItems: [PhotoAssetItem] = []
        private var flatIndexByIdentifier: [String: Int] = [:]
        private var sectionIndexByDay: [Date: Int] = [:]
        private var signature = NativePhotoCollectionSignature.empty
        private var lastScrollRequestID: UUID
        private var isProgrammaticScroll = false
        private var programmaticScrollTask: Task<Void, Never>?
        private var activeDayTask: Task<Void, Never>?
        private var preheatedBuckets: [ThumbnailPreheatBucketKey: Set<String>] = [:]
        private var lastVisibleRange: ClosedRange<Int>?
        private var scrollDirection: PreheatScrollDirection = .forward
        private var latestStats = NativePhotoGridStats()

        init(_ parent: NativePhotoCollectionView) {
            self.parent = parent
            lastScrollRequestID = parent.scrollRequestID
            super.init()
            rebuildSections(from: parent)
        }

        func update(_ newParent: NativePhotoCollectionView) {
            let oldWidth = parent.thumbnailWidth
            let oldDisplayMode = parent.displayMode
            let oldShowsInfo = parent.showsPhotoInfo
            let oldSelection = parent.selectedIdentifiers
            let oldSelecting = parent.isSelecting
            parent = newParent

            let newSignature = NativePhotoCollectionSignature.make(
                daySections: newParent.daySections,
                undatedAssets: newParent.undatedAssets
            )
            if newSignature != signature {
                rebuildSections(from: newParent)
                reloadData(reason: "data")
                resetPreheating()
            } else if oldWidth != newParent.thumbnailWidth
                        || oldDisplayMode != newParent.displayMode
                        || oldShowsInfo != newParent.showsPhotoInfo {
                collectionView?.collectionViewLayout?.invalidateLayout()
                reconfigureVisibleItems(cancelImageRequests: oldWidth != newParent.thumbnailWidth || oldDisplayMode != newParent.displayMode)
                resetPreheating()
                updateVisibleState()
            } else if oldSelection != newParent.selectedIdentifiers || oldSelecting != newParent.isSelecting {
                reconfigureVisibleSelection()
            }

            if lastScrollRequestID != newParent.scrollRequestID {
                lastScrollRequestID = newParent.scrollRequestID
                scrollToLatest(animated: false)
            }

            if let target = newParent.pendingScrollTarget {
                scroll(to: Calendar.current.startOfDay(for: target), animated: !newParent.reduceMotion)
            }

            updateStatsIfNeeded()
        }

        func reloadData(reason _: String) {
            latestStats.reloadDataCount += 1
            collectionView?.reloadData()
            DispatchQueue.main.async { [weak self] in
                self?.scrollToLatestIfNeeded()
                self?.updateVisibleState()
                self?.updateStatsIfNeeded()
            }
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            sections.count
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            sections[section].items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: NativePhotoCollectionViewItem.identifier,
                for: indexPath
            )
            guard let cell = item as? NativePhotoCollectionViewItem else {
                return item
            }

            latestStats.createdItems = NativePhotoCollectionViewItem.createdCount
            latestStats.reusedItems = NativePhotoCollectionViewItem.reuseCount
            let assetItem = sections[indexPath.section].items[indexPath.item]
            cell.configure(
                item: assetItem,
                imageService: parent.imageService,
                displayMode: parent.displayMode,
                thumbnailWidth: parent.thumbnailWidth,
                isSelected: parent.selectedIdentifiers.contains(assetItem.localIdentifier),
                showsSelectionState: parent.isSelecting,
                showsPhotoInfo: parent.showsPhotoInfo,
                delegate: self
            )
            return cell
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let view = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: NativePhotoSectionHeaderView.identifier,
                for: indexPath
            )
            guard let header = view as? NativePhotoSectionHeaderView else {
                return view
            }
            let section = sections[indexPath.section]
            header.configure(title: section.title) { [weak self] action in
                guard let self else { return }
                switch action {
                case .selectAll:
                    parent.selectAll(section.items)
                case .invertSelection:
                    parent.invertSelection(section.items)
                }
            }
            return header
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            let width = max(64, parent.thumbnailWidth)
            let infoHeight: CGFloat = parent.showsPhotoInfo ? 28 : 0
            return NSSize(width: width, height: (width * 0.75).rounded(.up) + infoHeight)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> NSSize {
            NSSize(width: collectionView.bounds.width, height: 29)
        }

        @objc func boundsDidChange(_ notification: Notification) {
            updateVisibleState()
        }

        private func rebuildSections(from parent: NativePhotoCollectionView) {
            let dated = parent.daySections.map {
                NativePhotoGridSection(id: .day($0.date), title: sectionTitle(for: $0.date), items: $0.assets)
            }
            let undated = parent.undatedAssets.isEmpty
                ? []
                : [NativePhotoGridSection(id: .undated, title: "未知日期", items: parent.undatedAssets)]
            sections = dated + undated
            allItems = parent.allAssets
            flatItems = sections.flatMap(\.items)
            flatIndexByIdentifier = Dictionary(
                uniqueKeysWithValues: flatItems.enumerated().map { ($0.element.localIdentifier, $0.offset) }
            )
            sectionIndexByDay = Dictionary(
                uniqueKeysWithValues: sections.enumerated().compactMap { index, section in
                    guard case .day(let date) = section.id else { return nil }
                    return (date, index)
                }
            )
            signature = NativePhotoCollectionSignature.make(
                daySections: parent.daySections,
                undatedAssets: parent.undatedAssets
            )
        }

        private func sectionTitle(for date: Date) -> String {
            date.formatted(.dateTime.month(.wide).day().locale(.gladPhotosChinese))
        }

        private func scrollToLatestIfNeeded() {
            guard parent.activeDay == nil, parent.pendingScrollTarget == nil else { return }
            scrollToLatest(animated: false)
        }

        private func scrollToLatest(animated: Bool) {
            guard let lastSection = sections.indices.last,
                  let lastItem = sections[lastSection].items.indices.last,
                  let collectionView
            else { return }
            let indexPath = IndexPath(item: lastItem, section: lastSection)
            collectionView.scrollToItems(at: [indexPath], scrollPosition: .bottom)
            updateVisibleState()
        }

        private func scroll(to day: Date, animated: Bool) {
            guard let sectionIndex = sectionIndexByDay[day], let collectionView else {
                return
            }

            parent.activeDay = day
            #if DEBUG
            ScrollPerformanceDiagnostics.recordVisibleDatePublished()
            #endif
            isProgrammaticScroll = true
            programmaticScrollTask?.cancel()

            let indexPath = IndexPath(item: 0, section: sectionIndex)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    collectionView.animator().scrollToItems(at: [indexPath], scrollPosition: .top)
                }
            } else {
                collectionView.scrollToItems(at: [indexPath], scrollPosition: .top)
            }

            programmaticScrollTask = Task { @MainActor in
                if animated {
                    try? await Task.sleep(for: .milliseconds(320))
                }
                guard !Task.isCancelled else { return }
                isProgrammaticScroll = false
                if parent.pendingScrollTarget.map({ Calendar.current.startOfDay(for: $0) }) == day {
                    parent.pendingScrollTarget = nil
                }
                publishVisibleDay(immediate: true)
            }
        }

        private func updateVisibleState() {
            guard let collectionView else { return }
            let visibleIndexPaths = collectionView.indexPathsForVisibleItems()
            latestStats.maxVisibleItems = max(latestStats.maxVisibleItems, visibleIndexPaths.count)
            updatePreheating(visibleIndexPaths: visibleIndexPaths)
            if !isProgrammaticScroll {
                publishVisibleDay(immediate: false)
            }
            updateStatsIfNeeded()
        }

        private func publishVisibleDay(immediate: Bool) {
            guard let day = visibleDayCandidate(), parent.activeDay != day else { return }
            #if DEBUG
            ScrollPerformanceDiagnostics.recordVisibleDateCandidate()
            #endif
            activeDayTask?.cancel()
            let publish = { [weak self] in
                guard let self, parent.activeDay != day else { return }
                parent.activeDay = day
                #if DEBUG
                ScrollPerformanceDiagnostics.recordVisibleDatePublished()
                #endif
            }
            if immediate {
                publish()
            } else {
                activeDayTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, !isProgrammaticScroll else { return }
                    publish()
                }
            }
        }

        private func visibleDayCandidate() -> Date? {
            guard let collectionView else { return nil }
            let referenceY = collectionView.visibleRect.minY + 80
            let headerAttributes = sections.indices.compactMap { sectionIndex in
                collectionView.layoutAttributesForSupplementaryElement(
                    ofKind: NSCollectionView.elementKindSectionHeader,
                    at: IndexPath(item: 0, section: sectionIndex)
                )
            }
            let sorted = headerAttributes.sorted { $0.frame.minY < $1.frame.minY }
            let selected = sorted.last(where: { $0.frame.minY <= referenceY }) ?? sorted.first
            guard let section = selected?.indexPath?.section,
                  sections.indices.contains(section),
                  case .day(let date) = sections[section].id
            else {
                return nil
            }
            return date
        }

        private func updatePreheating(visibleIndexPaths: Set<IndexPath>) {
            let visibleFlatIndexes = visibleIndexPaths.compactMap { indexPath -> Int? in
                guard sections.indices.contains(indexPath.section),
                      sections[indexPath.section].items.indices.contains(indexPath.item)
                else { return nil }
                return flatIndexByIdentifier[sections[indexPath.section].items[indexPath.item].localIdentifier]
            }
            guard let start = visibleFlatIndexes.min(), let end = visibleFlatIndexes.max() else {
                stopAllPreheating()
                return
            }

            let visibleRange = start...end
            if visibleRange == lastVisibleRange { return }
            if let last = lastVisibleRange {
                let oldMid = (last.lowerBound + last.upperBound) / 2
                let newMid = (visibleRange.lowerBound + visibleRange.upperBound) / 2
                scrollDirection = newMid < oldMid ? .backward : .forward
            }
            lastVisibleRange = visibleRange

            let visibleCount = max(1, end - start + 1)
            let before = scrollDirection == .backward ? visibleCount * 2 : visibleCount
            let after = scrollDirection == .forward ? visibleCount * 2 : visibleCount
            let windowStart = max(0, start - min(before, 100))
            let windowEnd = min(flatItems.count - 1, end + min(after, 100))
            guard windowStart <= windowEnd else { return }

            let items = Array(flatItems[windowStart...windowEnd]).prefix(180)
            var newBuckets: [ThumbnailPreheatBucketKey: Set<String>] = [:]
            for item in items {
                let config = parent.imageService.thumbnailRequestConfiguration(
                    for: item.asset,
                    displayMode: parent.displayMode,
                    thumbnailWidth: parent.thumbnailWidth
                )
                newBuckets[ThumbnailPreheatBucketKey(configuration: config), default: []]
                    .insert(item.localIdentifier)
            }
            applyPreheatBuckets(newBuckets)
        }

        private func applyPreheatBuckets(_ newBuckets: [ThumbnailPreheatBucketKey: Set<String>]) {
            var addedCount = 0
            var removedCount = 0
            var startCalls = 0
            var stopCalls = 0
            for key in Set(preheatedBuckets.keys).union(newBuckets.keys) {
                let old = preheatedBuckets[key] ?? []
                let new = newBuckets[key] ?? []
                let added = assets(for: new.subtracting(old))
                if !added.isEmpty {
                    parent.imageService.startCachingThumbnails(
                        assets: added,
                        targetSize: key.targetSize,
                        contentMode: key.contentMode
                    )
                    addedCount += added.count
                    startCalls += 1
                }
                let removed = assets(for: old.subtracting(new))
                if !removed.isEmpty {
                    parent.imageService.stopCachingThumbnails(
                        assets: removed,
                        targetSize: key.targetSize,
                        contentMode: key.contentMode
                    )
                    removedCount += removed.count
                    stopCalls += 1
                }
            }
            preheatedBuckets = newBuckets
            #if DEBUG
            ScrollPerformanceDiagnostics.recordPreheatUpdate(
                addedAssets: addedCount,
                removedAssets: removedCount,
                activeAssets: Set(newBuckets.values.flatMap { $0 }).count,
                startCalls: startCalls,
                stopCalls: stopCalls
            )
            ScrollPerformanceDiagnostics.updatePreheatedCandidateIdentifiers(Set(newBuckets.values.flatMap { $0 }))
            #endif
        }

        func stopAllPreheating() {
            guard !preheatedBuckets.isEmpty else { return }
            parent.imageService.stopCachingAllThumbnails()
            preheatedBuckets = [:]
            lastVisibleRange = nil
            #if DEBUG
            ScrollPerformanceDiagnostics.recordPreheatWindowReset()
            ScrollPerformanceDiagnostics.updatePreheatedCandidateIdentifiers([])
            #endif
        }

        private func resetPreheating() {
            stopAllPreheating()
            lastVisibleRange = nil
            scrollDirection = .forward
        }

        private func assets(for identifiers: Set<String>) -> [PHAsset] {
            identifiers.compactMap { identifier in
                guard let index = flatIndexByIdentifier[identifier], flatItems.indices.contains(index) else {
                    return nil
                }
                return flatItems[index].asset
            }
        }

        private func reconfigureVisibleItems(cancelImageRequests: Bool) {
            collectionView?.visibleItems().forEach { item in
                guard let cell = item as? NativePhotoCollectionViewItem,
                      let photoItem = cell.item
                else { return }
                cell.configure(
                    item: photoItem,
                    imageService: parent.imageService,
                    displayMode: parent.displayMode,
                    thumbnailWidth: parent.thumbnailWidth,
                    isSelected: parent.selectedIdentifiers.contains(photoItem.localIdentifier),
                    showsSelectionState: parent.isSelecting,
                    showsPhotoInfo: parent.showsPhotoInfo,
                    delegate: self,
                    forceImageReload: cancelImageRequests
                )
            }
        }

        private func reconfigureVisibleSelection() {
            collectionView?.visibleItems().forEach { item in
                guard let cell = item as? NativePhotoCollectionViewItem,
                      let photoItem = cell.item
                else { return }
                cell.updateSelection(
                    isSelected: parent.selectedIdentifiers.contains(photoItem.localIdentifier),
                    showsSelectionState: parent.isSelecting
                )
            }
        }

        func cancelPendingTasks() {
            programmaticScrollTask?.cancel()
            activeDayTask?.cancel()
        }

        private func updateStatsIfNeeded() {
            latestStats.createdItems = NativePhotoCollectionViewItem.createdCount
            latestStats.reusedItems = NativePhotoCollectionViewItem.reuseCount
            #if DEBUG
            ScrollPerformanceDiagnostics.recordNativeCollectionStats(
                createdItems: latestStats.createdItems,
                reusedItems: latestStats.reusedItems,
                maxVisibleItems: latestStats.maxVisibleItems,
                reloadDataCount: latestStats.reloadDataCount
            )
            #endif
            if parent.stats != latestStats {
                parent.stats = latestStats
            }
        }
    }
}

extension NativePhotoCollectionView.Coordinator: NativePhotoCollectionViewItemDelegate {
    func nativePhotoItemDidOpen(_ item: PhotoAssetItem) {
        parent.openDetail(item)
    }

    func nativePhotoItemDidToggleSelection(_ item: PhotoAssetItem) {
        var selected = parent.selectedIdentifiers
        if selected.contains(item.localIdentifier) {
            selected.remove(item.localIdentifier)
        } else {
            parent.isSelecting = true
            selected.insert(item.localIdentifier)
        }
        parent.selectedIdentifiers = selected
    }

    func nativePhotoItemDidLocate(_ item: PhotoAssetItem) {
        parent.locateInApplePhotos(item)
    }
}

private struct NativePhotoGridSection {
    let id: NativePhotoGridSectionID
    let title: String
    let items: [PhotoAssetItem]
}

private enum NativePhotoGridSectionID: Hashable {
    case day(Date)
    case undated
}

private struct NativePhotoCollectionSignature: Equatable {
    static let empty = NativePhotoCollectionSignature(values: [])
    let values: [String]

    static func make(daySections: [PhotoDaySection], undatedAssets: [PhotoAssetItem]) -> Self {
        var values: [String] = []
        for section in daySections {
            values.append("d:\(section.date.timeIntervalSinceReferenceDate)")
            values.append(contentsOf: section.assets.map(\.localIdentifier))
        }
        if !undatedAssets.isEmpty {
            values.append("u")
            values.append(contentsOf: undatedAssets.map(\.localIdentifier))
        }
        return NativePhotoCollectionSignature(values: values)
    }
}

private enum PreheatScrollDirection {
    case forward
    case backward
}

private struct ThumbnailPreheatBucketKey: Hashable {
    let width: Int
    let height: Int
    let contentModeRawValue: Int

    var targetSize: CGSize {
        CGSize(width: width, height: height)
    }

    var contentMode: PHImageContentMode {
        PHImageContentMode(rawValue: contentModeRawValue) ?? .aspectFill
    }

    init(configuration: PhotoThumbnailRequestConfiguration) {
        width = Int(configuration.targetSize.width.rounded())
        height = Int(configuration.targetSize.height.rounded())
        contentModeRawValue = configuration.contentMode.rawValue
    }
}

private enum NativePhotoSectionHeaderAction {
    case selectAll
    case invertSelection
}

private final class NativePhotoSectionHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("NativePhotoSectionHeaderView")

    private let titleLabel = NSTextField(labelWithString: "")
    private let selectButton = NSButton()
    private let invertButton = NSButton()
    private var actionHandler: ((NativePhotoSectionHeaderAction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(
        title: String,
        actionHandler: @escaping (NativePhotoSectionHeaderAction) -> Void
    ) {
        titleLabel.stringValue = title
        self.actionHandler = actionHandler
    }

    private func setup() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        selectButton.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "选择全部")
        selectButton.bezelStyle = .regularSquare
        selectButton.isBordered = false
        selectButton.target = self
        selectButton.action = #selector(selectAllInSection)
        selectButton.translatesAutoresizingMaskIntoConstraints = false

        invertButton.title = "反选"
        invertButton.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "反选")
        invertButton.imagePosition = .imageLeading
        invertButton.bezelStyle = .texturedRounded
        invertButton.controlSize = .small
        invertButton.target = self
        invertButton.action = #selector(invertSelection)
        invertButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(selectButton)
        addSubview(invertButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            selectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectButton.widthAnchor.constraint(equalToConstant: 24),
            selectButton.heightAnchor.constraint(equalToConstant: 24),
            invertButton.leadingAnchor.constraint(equalTo: selectButton.trailingAnchor, constant: 5),
            invertButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func selectAllInSection() {
        actionHandler?(.selectAll)
    }

    @objc private func invertSelection() {
        actionHandler?(.invertSelection)
    }
}

@MainActor
private protocol NativePhotoCollectionViewItemDelegate: AnyObject {
    func nativePhotoItemDidOpen(_ item: PhotoAssetItem)
    func nativePhotoItemDidToggleSelection(_ item: PhotoAssetItem)
    func nativePhotoItemDidLocate(_ item: PhotoAssetItem)
}

private final class NativePhotoCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NativePhotoCollectionViewItem")
    @MainActor static var createdCount = 0
    @MainActor static var reuseCount = 0

    var item: PhotoAssetItem?
    private weak var imageService: PhotoImageService?
    private weak var delegate: NativePhotoCollectionViewItemDelegate?
    private var requestID: PHImageRequestID?
    private var requestedIdentifier: String?
    private var requestToken: UUID?
    private var degradedTask: Task<Void, Never>?
    private var resourceSizeRequestID: UUID?
    private var resourceSize: Int64?
    private var isResourceSizeUnavailable = false
    private var showsPhotoInfo = false

    private var itemView: NativePhotoItemView {
        view as! NativePhotoItemView
    }

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        Self.createdCount += 1
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.createdCount += 1
    }

    override func loadView() {
        view = NativePhotoItemView()
        itemView.owner = self
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        Self.reuseCount += 1
        cancelImageRequest()
        cancelResourceSizeRequest()
        item = nil
        imageService = nil
        delegate = nil
        resourceSize = nil
        isResourceSizeUnavailable = false
        itemView.prepareForReuse()
    }

    func configure(
        item: PhotoAssetItem,
        imageService: PhotoImageService,
        displayMode: PhotoGridDisplayMode,
        thumbnailWidth: CGFloat,
        isSelected: Bool,
        showsSelectionState: Bool,
        showsPhotoInfo: Bool,
        delegate: NativePhotoCollectionViewItemDelegate,
        forceImageReload: Bool = false
    ) {
        let changedItem = self.item?.localIdentifier != item.localIdentifier
        self.item = item
        self.imageService = imageService
        self.delegate = delegate
        self.showsPhotoInfo = showsPhotoInfo
        itemView.configure(
            item: item,
            image: itemView.image,
            isSelected: isSelected,
            showsSelectionState: showsSelectionState,
            showsPhotoInfo: showsPhotoInfo,
            resourceSizeText: resourceSizeText
        )

        if changedItem || forceImageReload || requestedIdentifier != item.localIdentifier {
            cancelImageRequest()
            itemView.image = nil
            requestThumbnail(displayMode: displayMode, thumbnailWidth: thumbnailWidth)
        }

        if showsPhotoInfo {
            requestResourceSizeIfNeeded()
        } else {
            cancelResourceSizeRequest()
            resourceSize = nil
            isResourceSizeUnavailable = false
        }
    }

    func updateSelection(isSelected: Bool, showsSelectionState: Bool) {
        itemView.updateSelection(isSelected: isSelected, showsSelectionState: showsSelectionState)
    }

    func open() {
        guard let item else { return }
        delegate?.nativePhotoItemDidOpen(item)
    }

    func toggleSelection() {
        guard let item else { return }
        delegate?.nativePhotoItemDidToggleSelection(item)
    }

    func locateInApplePhotos() {
        guard let item else { return }
        delegate?.nativePhotoItemDidLocate(item)
    }

    private func requestThumbnail(displayMode: PhotoGridDisplayMode, thumbnailWidth: CGFloat) {
        guard let item, let imageService else { return }
        let token = UUID()
        requestToken = token
        requestedIdentifier = item.localIdentifier
        let config = imageService.thumbnailRequestConfiguration(
            for: item.asset,
            displayMode: displayMode,
            thumbnailWidth: thumbnailWidth
        )
        requestID = imageService.requestThumbnail(
            for: item.asset,
            targetSize: config.targetSize,
            contentMode: config.contentMode
        ) { [weak self] identifier, image, isDegraded in
            guard let self,
                  requestedIdentifier == identifier,
                  requestToken == token
            else { return }
            if isDegraded {
                scheduleDegradedImageCommit(image, token: token, identifier: identifier)
            } else {
                degradedTask?.cancel()
                degradedTask = nil
                itemView.image = image
                #if DEBUG
                ScrollPerformanceDiagnostics.recordThumbnailFinalCommittedToUI()
                #endif
            }
        }
    }

    private func scheduleDegradedImageCommit(_ image: NSImage?, token: UUID, identifier: String) {
        degradedTask?.cancel()
        #if DEBUG
        ScrollPerformanceDiagnostics.recordThumbnailDegradedReceived()
        #endif
        degradedTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled,
                  requestToken == token,
                  requestedIdentifier == identifier
            else { return }
            itemView.image = image
            degradedTask = nil
            #if DEBUG
            ScrollPerformanceDiagnostics.recordThumbnailDegradedCommittedToUI()
            #endif
        }
    }

    private func cancelImageRequest() {
        imageService?.cancelRequest(requestID)
        requestID = nil
        requestedIdentifier = nil
        requestToken = nil
        degradedTask?.cancel()
        degradedTask = nil
    }

    private func requestResourceSizeIfNeeded() {
        guard let item, let imageService, resourceSizeRequestID == nil,
              resourceSize == nil, !isResourceSizeUnavailable
        else { return }
        resourceSizeRequestID = imageService.requestResourceSize(for: item.asset) { [weak self] identifier, size in
            guard let self, self.item?.localIdentifier == identifier else { return }
            resourceSizeRequestID = nil
            resourceSize = size
            isResourceSizeUnavailable = size == nil
            itemView.updateResourceSizeText(resourceSizeText)
        }
    }

    private func cancelResourceSizeRequest() {
        imageService?.cancelResourceSizeRequest(resourceSizeRequestID)
        resourceSizeRequestID = nil
    }

    private var resourceSizeText: String {
        if let resourceSize {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: resourceSize)
        }
        return isResourceSizeUnavailable ? "大小不可用" : "正在计算..."
    }
}

private final class NativePhotoItemView: NSView {
    weak var owner: NativePhotoCollectionViewItem?
    private let imageView = NSImageView()
    private let placeholder = NSImageView(image: NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: nil) ?? NSImage())
    private let selectionOverlay = CALayer()
    private let selectionIcon = NSImageView()
    private let liveBadge = NSImageView(image: NSImage(systemSymbolName: "livephoto", accessibilityDescription: "Live Photo") ?? NSImage())
    private let dateLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false
    private var isSelected = false
    private var showsSelectionState = false
    private var showsPhotoInfo = false
    private var canLocate = false

    var image: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            placeholder.isHidden = newValue != nil
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var isFlipped: Bool { true }

    override func prepareForReuse() {
        super.prepareForReuse()
        image = nil
        isHovered = false
        isSelected = false
        showsSelectionState = false
        showsPhotoInfo = false
        dateLabel.stringValue = ""
        sizeLabel.stringValue = ""
        updateSelectionLayers()
    }

    func configure(
        item: PhotoAssetItem,
        image: NSImage?,
        isSelected: Bool,
        showsSelectionState: Bool,
        showsPhotoInfo: Bool,
        resourceSizeText: String
    ) {
        self.image = image
        self.isSelected = isSelected
        self.showsSelectionState = showsSelectionState
        self.showsPhotoInfo = showsPhotoInfo
        canLocate = ApplePhotosLocator.canLocate(item.asset)
        liveBadge.isHidden = !item.asset.mediaSubtypes.contains(.photoLive)
        dateLabel.stringValue = item.asset.creationDate?.formatted(
            .dateTime.day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(.gladPhotosChinese)
        ) ?? "时间未知"
        sizeLabel.stringValue = resourceSizeText
        dateLabel.isHidden = !showsPhotoInfo
        sizeLabel.isHidden = !showsPhotoInfo
        updateSelectionLayers()
        needsLayout = true
    }

    func updateSelection(isSelected: Bool, showsSelectionState: Bool) {
        self.isSelected = isSelected
        self.showsSelectionState = showsSelectionState
        updateSelectionLayers()
    }

    func updateResourceSizeText(_ text: String) {
        sizeLabel.stringValue = text
    }

    override func layout() {
        super.layout()
        let infoHeight: CGFloat = showsPhotoInfo ? 28 : 0
        let imageRect = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - infoHeight))
        imageView.frame = imageRect
        placeholder.frame = imageRect.insetBy(dx: max(0, imageRect.width - 30) / 2, dy: max(0, imageRect.height - 30) / 2)
        selectionOverlay.frame = imageRect
        selectionIcon.frame = NSRect(x: imageRect.maxX - 28, y: imageRect.minY + 5, width: 22, height: 22)
        liveBadge.frame = NSRect(x: 6, y: 6, width: 19, height: 19)
        dateLabel.frame = NSRect(x: 0, y: imageRect.maxY + 1, width: bounds.width, height: 13)
        sizeLabel.frame = NSRect(x: 0, y: imageRect.maxY + 14, width: bounds.width, height: 13)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateSelectionLayers()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateSelectionLayers()
    }

    override func mouseUp(with event: NSEvent) {
        if selectionIcon.frame.insetBy(dx: -8, dy: -8).contains(convert(event.locationInWindow, from: nil)) {
            owner?.toggleSelection()
        } else {
            owner?.open()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard canLocate else {
            super.rightMouseDown(with: event)
            return
        }
        let menu = NSMenu()
        let item = NSMenuItem(title: "定位到 Apple 图库", action: #selector(locateInApplePhotos), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor
        placeholder.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        placeholder.contentTintColor = .secondaryLabelColor
        liveBadge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        liveBadge.contentTintColor = .white
        liveBadge.wantsLayer = true
        liveBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        liveBadge.layer?.cornerRadius = 9.5

        selectionOverlay.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0).cgColor
        selectionOverlay.borderColor = NSColor.controlAccentColor.cgColor
        selectionOverlay.borderWidth = 0
        selectionIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)

        [dateLabel, sizeLabel].forEach {
            $0.font = .systemFont(ofSize: 10)
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingTail
        }

        addSubview(imageView)
        addSubview(placeholder)
        addSubview(liveBadge)
        addSubview(selectionIcon)
        addSubview(dateLabel)
        addSubview(sizeLabel)
        layer?.addSublayer(selectionOverlay)
    }

    private func updateSelectionLayers() {
        let visible = showsSelectionState || isHovered || isSelected
        selectionOverlay.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isSelected ? 0.18 : 0).cgColor
        selectionOverlay.borderWidth = isSelected ? 3 : 0
        selectionIcon.isHidden = !visible
        selectionIcon.image = NSImage(
            systemSymbolName: isSelected ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: isSelected ? "取消选择" : "选择照片"
        )
        selectionIcon.contentTintColor = isSelected ? .controlAccentColor : .white
    }

    @objc private func locateInApplePhotos() {
        owner?.locateInApplePhotos()
    }
}
