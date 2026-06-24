import AppKit
import Photos
import SwiftUI

struct ZoomablePhotoView: View {
    let image: NSImage
    let pixelSize: CGSize
    var onHorizontalSwipe: (HorizontalSwipeEvent) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onInteractionStateChanged: (PhotoInteractionState) -> Void = { _ in }
    var onDismissProgressChanged: (CGFloat) -> Void = { _ in }

    var body: some View {
        ZoomableCanvas(
            pixelSize: pixelSize,
            onHorizontalSwipe: onHorizontalSwipe,
            onDismiss: onDismiss,
            onInteractionStateChanged: onInteractionStateChanged,
            onDismissProgressChanged: onDismissProgressChanged
        ) {
            Image(nsImage: image)
                .resizable()
        } overviewContent: {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

struct ZoomableLivePhotoView: View {
    let livePhoto: PHLivePhoto
    let assetIdentifier: String
    let pixelSize: CGSize
    var onHorizontalSwipe: (HorizontalSwipeEvent) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onInteractionStateChanged: (PhotoInteractionState) -> Void = { _ in }
    var onDismissProgressChanged: (CGFloat) -> Void = { _ in }

    @State private var replayTrigger = 0

    var body: some View {
        ZoomableCanvas(
            pixelSize: pixelSize,
            onSingleClick: { replayTrigger += 1 },
            onHorizontalSwipe: onHorizontalSwipe,
            onDismiss: onDismiss,
            onInteractionStateChanged: onInteractionStateChanged,
            onDismissProgressChanged: onDismissProgressChanged
        ) {
            LivePhotoPlayerView(
                livePhoto: livePhoto,
                assetIdentifier: assetIdentifier,
                replayTrigger: replayTrigger
            )
        } overviewContent: {
            LivePhotoPlayerView(
                livePhoto: livePhoto,
                assetIdentifier: "\(assetIdentifier)-overview",
                automaticallyPlays: false,
                isMuted: true
            )
        }
    }
}

enum HorizontalSwipeEvent {
    case changed(translation: CGFloat, delta: CGFloat, velocity: CGFloat)
    case ended(translation: CGFloat, velocity: CGFloat, predictedEndTranslation: CGFloat)
}

enum PhotoInteractionState: Equatable {
    case idle
    case interactiveDismiss
    case cancelSettling
    case commitAnimating
    case absorbingMomentum
    case finished
}

private struct ZoomableCanvas<Content: View, OverviewContent: View>: View {
    let pixelSize: CGSize
    let onSingleClick: () -> Void
    let onHorizontalSwipe: (HorizontalSwipeEvent) -> Void
    let onDismiss: () -> Void
    let onInteractionStateChanged: (PhotoInteractionState) -> Void
    let onDismissProgressChanged: (CGFloat) -> Void
    let content: Content
    let overviewContent: OverviewContent

    init(
        pixelSize: CGSize,
        onSingleClick: @escaping () -> Void = {},
        onHorizontalSwipe: @escaping (HorizontalSwipeEvent) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {},
        onInteractionStateChanged: @escaping (PhotoInteractionState) -> Void = { _ in },
        onDismissProgressChanged: @escaping (CGFloat) -> Void = { _ in },
        @ViewBuilder content: () -> Content,
        @ViewBuilder overviewContent: () -> OverviewContent
    ) {
        self.pixelSize = pixelSize
        self.onSingleClick = onSingleClick
        self.onHorizontalSwipe = onHorizontalSwipe
        self.onDismiss = onDismiss
        self.onInteractionStateChanged = onInteractionStateChanged
        self.onDismissProgressChanged = onDismissProgressChanged
        self.content = content()
        self.overviewContent = overviewContent()
    }

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var isInitialized = false
    @State private var pagingTranslation: CGFloat = 0
    @State private var interactionState: PhotoInteractionState = .idle
    @State private var gestureTranslation: CGSize = .zero
    @State private var dismissOffset: CGFloat = 0
    @State private var dismissVelocity: CGFloat = 0
    @State private var fingerPhaseFinished = true
    @State private var momentumPhaseFinished = true
    @State private var dismissAnimationFinished = true
    @State private var ownsScrollSequence = false

    private let maximumScale: CGFloat = 5
    private let scrollDeadZone: CGFloat = 12
    private let dismissThreshold: CGFloat = 100
    private let dismissProgressDistance: CGFloat = 240
    private let dismissVelocityThreshold: CGFloat = 900

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            let renderedSize = scaledImageSize(at: scale, in: viewport)
            let dismissProgress = min(max(dismissOffset / dismissProgressDistance, 0), 1)

            ZStack(alignment: .bottomTrailing) {
                content
                    .frame(width: renderedSize.width, height: renderedSize.height)
                    .offset(offset)
                    .frame(width: viewport.width, height: viewport.height)
                    .clipped()
                    .scaleEffect(1 - dismissProgress * 0.12)
                    .offset(y: dismissOffset)

                ZoomInteractionView(
                    onSingleClick: onSingleClick,
                    onDoubleClick: { location in
                        toggleActualSize(at: location, in: viewport)
                    },
                    onMagnify: { factor, location, phase in
                        handleMagnify(factor: factor, location: location, phase: phase, viewport: viewport)
                    },
                    onVerticalScroll: { event in
                        handleVerticalScroll(event, viewport: viewport)
                    },
                    onHorizontalSwipe: { event in
                        handleHorizontalSwipe(event, viewport: viewport)
                    },
                    onScrollPan: { delta in
                        guard isZoomed else { return }
                        offset.width += delta.width
                        offset.height += delta.height
                        offset = clampedOffset(offset, scale: scale, viewport: viewport)
                    },
                    prefersPan: isZoomed,
                    ownsScrollSequence: ownsScrollSequence,
                    onDrag: { translation in
                        guard isZoomed, interactionState == .idle else { return }
                        offset.width += translation.width
                        offset.height += translation.height
                        offset = clampedOffset(offset, scale: scale, viewport: viewport)
                    }
                )

                if isZoomed {
                    overview(in: viewport)
                        .padding(16)
                }
            }
            .onAppear {
                resetToFit(in: viewport)
            }
            .onChange(of: viewport) { oldSize, newSize in
                guard newSize.width > 0, newSize.height > 0 else { return }
                if !isInitialized || approximatelyFit {
                    resetToFit(in: newSize)
                } else {
                    offset = clampedOffset(offset, scale: scale, viewport: newSize)
                }
            }
        }
    }

    private func overview(in viewport: CGSize) -> some View {
        let size = overviewSize
        let imageRect = aspectFitRect(for: pixelSize, in: size)
        let renderedSize = scaledImageSize(at: scale, in: viewport)
        let visibleFraction = CGSize(
            width: min(viewport.width / renderedSize.width, 1),
            height: min(viewport.height / renderedSize.height, 1)
        )
        let viewportRectSize = CGSize(
            width: imageRect.width * visibleFraction.width,
            height: imageRect.height * visibleFraction.height
        )
        let centerFraction = CGPoint(
            x: 0.5 - offset.width / renderedSize.width,
            y: 0.5 - offset.height / renderedSize.height
        )
        let viewportCenter = CGPoint(
            x: imageRect.minX + imageRect.width * centerFraction.x,
            y: imageRect.minY + imageRect.height * centerFraction.y
        )

        return ZStack {
            Color.black.opacity(0.72)

            overviewContent
                .frame(width: imageRect.width, height: imageRect.height)
                .position(x: imageRect.midX, y: imageRect.midY)

            Rectangle()
                .stroke(Color.blue, lineWidth: 2)
                .background(Color.blue.opacity(0.08))
                .frame(width: viewportRectSize.width, height: viewportRectSize.height)
                .position(viewportCenter)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    moveViewport(to: value.location, imageRect: imageRect, viewport: viewport)
                }
        )
    }

    private var overviewSize: CGSize {
        let maxSize = CGSize(width: 180, height: 120)
        let rect = aspectFitRect(for: pixelSize, in: maxSize)
        return CGSize(width: max(rect.width, 72), height: max(rect.height, 54))
    }

    private func moveViewport(
        to location: CGPoint,
        imageRect: CGRect,
        viewport: CGSize
    ) {
        guard imageRect.contains(location) else { return }
        let fraction = CGPoint(
            x: (location.x - imageRect.minX) / imageRect.width,
            y: (location.y - imageRect.minY) / imageRect.height
        )
        let renderedSize = scaledImageSize(at: scale, in: viewport)
        let newOffset = CGSize(
            width: (0.5 - fraction.x) * renderedSize.width,
            height: (0.5 - fraction.y) * renderedSize.height
        )
        offset = clampedOffset(newOffset, scale: scale, viewport: viewport)
    }

    private func toggleActualSize(at location: CGPoint, in viewport: CGSize) {
        if approximatelyFit {
            let actualSizeScale = min(max(1 / fitScale(in: viewport), 2), maximumScale)
            withAnimation(.easeInOut(duration: 0.18)) {
                setScale(
                    actualSizeScale,
                    anchoredAt: location,
                    in: viewport
                )
            }
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                resetToFit(in: viewport)
            }
        }
    }

    private func zoom(by factor: CGFloat, at location: CGPoint, in viewport: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        setScale(scale * factor, anchoredAt: location, in: viewport)
    }

    private func handleMagnify(
        factor: CGFloat,
        location: CGPoint,
        phase: NSEvent.Phase,
        viewport: CGSize
    ) {
        zoom(by: factor, at: location, in: viewport)
    }

    private func handleVerticalScroll(_ event: VerticalScrollEvent, viewport: CGSize) {
        switch event {
        case .began:
            gestureTranslation = .zero
            ownsScrollSequence = true
            dismissVelocity = 0
            fingerPhaseFinished = false
            momentumPhaseFinished = false
            dismissAnimationFinished = false

        case .changed(let delta, let velocity, _):
            switch interactionState {
            case .interactiveDismiss:
                // Keep the signed accumulation. An upward reversal can return
                // all the way to zero before the fingers lift.
                dismissOffset = max(dismissOffset + delta, 0)
                dismissVelocity = velocity
                onDismissProgressChanged(min(dismissOffset / dismissProgressDistance, 1))

            case .idle:
                gestureTranslation.height += delta
                guard gestureTranslation.height >= scrollDeadZone else { return }
                if approximatelyFit {
                    setInteractionState(.interactiveDismiss)
                    dismissOffset = max(gestureTranslation.height - scrollDeadZone, 0)
                    dismissVelocity = velocity
                    onDismissProgressChanged(min(dismissOffset / dismissProgressDistance, 1))
                }

            case .cancelSettling, .commitAnimating, .absorbingMomentum, .finished:
                break
            }

        case .fingerEnded(let cancelled):
            fingerPhaseFinished = true
            // AppKit will immediately send momentumBegan when this sequence has
            // inertia; absent that, the direct phase ending completes momentum.
            momentumPhaseFinished = true
            if interactionState == .interactiveDismiss {
                finishDismissGesture(cancelled: cancelled, viewport: viewport)
            } else if interactionState == .idle {
                dismissAnimationFinished = true
            }
            gestureTranslation = .zero
            finishSequenceIfPossible()

        case .momentumBegan:
            ownsScrollSequence = true
            momentumPhaseFinished = false

        case .momentumEnded:
            momentumPhaseFinished = true
            finishSequenceIfPossible()
        }
    }

    private func finishDismissGesture(cancelled: Bool, viewport: CGSize) {
        let endsDownward = dismissVelocity >= 0
        let shouldDismiss = !cancelled && endsDownward &&
            (dismissOffset >= dismissThreshold || dismissVelocity >= dismissVelocityThreshold)
        if shouldDismiss {
            setInteractionState(.commitAnimating)
            withAnimation(.easeOut(duration: 0.2), completionCriteria: .logicallyComplete) {
                dismissOffset = max(viewport.height, dismissProgressDistance)
                onDismissProgressChanged(1)
            } completion: {
                dismissAnimationFinished = true
                if momentumPhaseFinished {
                    finishSequenceIfPossible()
                } else {
                    setInteractionState(.absorbingMomentum)
                }
            }
        } else {
            setInteractionState(.cancelSettling)
            withAnimation(
                .spring(response: 0.28, dampingFraction: 0.82),
                completionCriteria: .logicallyComplete
            ) {
                dismissOffset = 0
                onDismissProgressChanged(0)
            } completion: {
                dismissAnimationFinished = true
                finishSequenceIfPossible()
            }
        }
    }

    private func finishSequenceIfPossible() {
        guard fingerPhaseFinished, momentumPhaseFinished, dismissAnimationFinished else { return }
        ownsScrollSequence = false
        if interactionState == .commitAnimating || interactionState == .absorbingMomentum {
            setInteractionState(.finished)
            onDismiss()
        } else if interactionState == .cancelSettling {
            setInteractionState(.idle)
        }
    }

    private func setInteractionState(_ state: PhotoInteractionState) {
        guard interactionState != state else { return }
        interactionState = state
        onInteractionStateChanged(state)
    }

    private func handleHorizontalSwipe(_ event: HorizontalSwipeEvent, viewport: CGSize) {
        switch event {
        case .changed(let translation, let delta, let velocity):
            guard interactionState == .idle, approximatelyFit else { return }
            pagingTranslation = translation
            onHorizontalSwipe(.changed(
                translation: pagingTranslation,
                delta: delta,
                velocity: velocity
            ))

        case .ended(_, let velocity, _):
            guard interactionState == .idle, approximatelyFit else {
                pagingTranslation = 0
                return
            }
            let translation = pagingTranslation
            let predicted = translation + velocity * 0.2
            onHorizontalSwipe(.ended(
                translation: translation,
                velocity: velocity,
                predictedEndTranslation: predicted
            ))
            pagingTranslation = 0
        }
    }

    private func setScale(
        _ proposedScale: CGFloat,
        anchoredAt location: CGPoint,
        in viewport: CGSize,
        minimumScale: CGFloat? = nil
    ) {
        let newScale = min(max(proposedScale, minimumScale ?? 1), maximumScale)
        guard abs(newScale - scale) > 0.0001 else { return }

        let viewportCenter = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let anchor = CGPoint(x: location.x - viewportCenter.x, y: location.y - viewportCenter.y)
        let ratio = newScale / scale
        let newOffset = CGSize(
            width: anchor.x - (anchor.x - offset.width) * ratio,
            height: anchor.y - (anchor.y - offset.height) * ratio
        )
        scale = newScale
        offset = clampedOffset(newOffset, scale: newScale, viewport: viewport)
    }

    private func resetToFit(in viewport: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        scale = 1
        offset = .zero
        isInitialized = true
    }

    private func fitScale(in viewport: CGSize) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        return min(viewport.width / pixelSize.width, viewport.height / pixelSize.height)
    }

    private func scaledImageSize(at scale: CGFloat, in viewport: CGSize) -> CGSize {
        let fit = fitScale(in: viewport)
        return CGSize(width: pixelSize.width * fit * scale, height: pixelSize.height * fit * scale)
    }

    private var isZoomed: Bool {
        scale > 1.001
    }

    private var approximatelyFit: Bool {
        abs(scale - 1) < 0.001
    }

    private func clampedOffset(_ offset: CGSize, scale: CGFloat, viewport: CGSize) -> CGSize {
        let imageSize = scaledImageSize(at: scale, in: viewport)
        let limitX = max((imageSize.width - viewport.width) / 2, 0)
        let limitY = max((imageSize.height - viewport.height) / 2, 0)
        return CGSize(
            width: min(max(offset.width, -limitX), limitX),
            height: min(max(offset.height, -limitY), limitY)
        )
    }

    private func aspectFitRect(for content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

private enum VerticalScrollEvent {
    case began
    case changed(delta: CGFloat, velocity: CGFloat, location: CGPoint)
    case fingerEnded(cancelled: Bool)
    case momentumBegan
    case momentumEnded
}

private struct ZoomInteractionView: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: (CGPoint) -> Void
    let onMagnify: (CGFloat, CGPoint, NSEvent.Phase) -> Void
    let onVerticalScroll: (VerticalScrollEvent) -> Void
    let onHorizontalSwipe: (HorizontalSwipeEvent) -> Void
    let onScrollPan: (CGSize) -> Void
    let prefersPan: Bool
    let ownsScrollSequence: Bool
    let onDrag: (CGSize) -> Void

    func makeNSView(context: Context) -> InteractionNSView {
        let view = InteractionNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: InteractionNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: InteractionNSView) {
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.onMagnify = onMagnify
        view.onVerticalScroll = onVerticalScroll
        view.onHorizontalSwipe = onHorizontalSwipe
        view.onScrollPan = onScrollPan
        view.prefersPan = prefersPan
        view.setSequenceOwnership(ownsScrollSequence)
        view.onDrag = onDrag
    }
}

private final class InteractionNSView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var onMagnify: ((CGFloat, CGPoint, NSEvent.Phase) -> Void)?
    var onVerticalScroll: ((VerticalScrollEvent) -> Void)?
    var onHorizontalSwipe: ((HorizontalSwipeEvent) -> Void)?
    var onScrollPan: ((CGSize) -> Void)?
    var prefersPan = false
    var onDrag: ((CGSize) -> Void)?

    private var previousDragLocation: CGPoint?
    private var didDrag = false
    private var scrollAxis: ScrollAxis?
    private var horizontalTranslation: CGFloat = 0
    private var lastHorizontalVelocity: CGFloat = 0
    private var lastHorizontalTimestamp: TimeInterval?
    private var lastVerticalTimestamp: TimeInterval?
    private var didBeginLockedAxis = false
    private var deadZoneTranslation = CGSize.zero
    private var ownsScrollSequence = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    func setSequenceOwnership(_ owns: Bool) {
        ownsScrollSequence = owns
    }

    private enum ScrollAxis {
        case horizontal
        case vertical
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        guard let window else { return }
        window.makeFirstResponder(self)
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.cancelOwnedSequence() })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in self?.cancelOwnedSequence() })
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func cancelOwnedSequence() {
        guard ownsScrollSequence else { return }
        onVerticalScroll?(.fingerEnded(cancelled: true))
        onVerticalScroll?(.momentumEnded)
        ownsScrollSequence = false
        scrollAxis = nil
        didBeginLockedAxis = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let location = swiftUILocation(for: event)
        if event.clickCount == 2 {
            onDoubleClick?(location)
            previousDragLocation = nil
        } else {
            didDrag = false
            previousDragLocation = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        let location = convert(event.locationInWindow, from: nil)
        if let previousDragLocation {
            onDrag?(CGSize(
                width: location.x - previousDragLocation.x,
                height: previousDragLocation.y - location.y
            ))
        }
        previousDragLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1, !didDrag {
            onSingleClick?()
        }
        previousDragLocation = nil
        didDrag = false
        NSCursor.openHand.set()
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(
            max(0.01, 1 + event.magnification),
            swiftUILocation(for: event),
            event.phase
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }

        if event.phase == .began {
            ownsScrollSequence = true
            scrollAxis = nil
            didBeginLockedAxis = false
            deadZoneTranslation = .zero
            horizontalTranslation = 0
            lastHorizontalVelocity = 0
            lastHorizontalTimestamp = event.timestamp
            lastVerticalTimestamp = event.timestamp
            onVerticalScroll?(.began)
        }

        // Momentum belongs to the direct sequence that created it. It is never
        // allowed to mutate the visual state, but its terminal phase controls
        // when the transparent capture view may be removed.
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase == .began { onVerticalScroll?(.momentumBegan) }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                onVerticalScroll?(.momentumEnded)
                ownsScrollSequence = false
                scrollAxis = nil
            }
            return
        }

        guard ownsScrollSequence else { return }

        if prefersPan {
            onScrollPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            if event.phase == .ended || event.phase == .cancelled {
                onVerticalScroll?(.fingerEnded(cancelled: event.phase == .cancelled))
            }
            return
        }

        if scrollAxis == nil {
            deadZoneTranslation.width += event.scrollingDeltaX
            deadZoneTranslation.height += event.scrollingDeltaY
            let horizontal = abs(deadZoneTranslation.width)
            let vertical = abs(deadZoneTranslation.height)
            if max(horizontal, vertical) >= 10 {
                scrollAxis = horizontal > vertical ? .horizontal : .vertical
                didBeginLockedAxis = true
            }
        }

        if scrollAxis == .horizontal, event.hasPreciseScrollingDeltas {
            let delta = event.scrollingDeltaX
            if abs(delta) > 0.01, let lastHorizontalTimestamp {
                let elapsed = max(event.timestamp - lastHorizontalTimestamp, 1.0 / 240.0)
                lastHorizontalVelocity = delta / elapsed
            }
            lastHorizontalTimestamp = event.timestamp
            horizontalTranslation += delta
            onHorizontalSwipe?(.changed(
                translation: horizontalTranslation,
                delta: delta,
                velocity: lastHorizontalVelocity
            ))

            if event.phase == .ended || event.phase == .cancelled {
                let prediction = horizontalTranslation + lastHorizontalVelocity * 0.2
                onHorizontalSwipe?(.ended(
                    translation: horizontalTranslation,
                    velocity: lastHorizontalVelocity,
                    predictedEndTranslation: prediction
                ))
                onVerticalScroll?(.fingerEnded(cancelled: event.phase == .cancelled))
            }
            return
        }

        if scrollAxis == .vertical {
            let elapsed = max(event.timestamp - (lastVerticalTimestamp ?? event.timestamp), 1.0 / 240.0)
            let velocity = event.scrollingDeltaY / elapsed
            lastVerticalTimestamp = event.timestamp
            onVerticalScroll?(.changed(
                delta: event.scrollingDeltaY,
                velocity: velocity,
                location: swiftUILocation(for: event)
            ))
        }

        if event.phase == .ended || event.phase == .cancelled {
            if scrollAxis == .vertical, didBeginLockedAxis {
                onVerticalScroll?(.fingerEnded(cancelled: event.phase == .cancelled))
            } else if scrollAxis == nil {
                onVerticalScroll?(.fingerEnded(cancelled: event.phase == .cancelled))
            }
            didBeginLockedAxis = false
        }
    }

    private func swiftUILocation(for event: NSEvent) -> CGPoint {
        let location = convert(event.locationInWindow, from: nil)
        return CGPoint(x: location.x, y: bounds.height - location.y)
    }
}
