import SwiftUI

struct VideoTrimTimelineView: View {
    @ObservedObject var state: VideoTrimState

    private let coordinateSpaceName = "videoTrimTimeline"
    private let handleWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let startX = xPosition(for: state.startTime, width: width)
            let endX = xPosition(for: state.endTime, width: width)
            let playheadX = xPosition(for: state.currentTime, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.16))
                    .frame(height: 10)

                Rectangle()
                    .fill(.black.opacity(0.48))
                    .frame(width: startX, height: 10)

                Rectangle()
                    .fill(Color.accentColor.opacity(0.82))
                    .frame(width: max(0, endX - startX), height: 10)
                    .offset(x: startX)

                Rectangle()
                    .fill(.black.opacity(0.48))
                    .frame(width: max(0, width - endX), height: 10)
                    .offset(x: endX)

                playhead
                    .position(x: playheadX, y: geometry.size.height / 2)
                    .zIndex(2)

                handle(edge: .leading)
                    .position(x: startX, y: geometry.size.height / 2)
                    .highPriorityGesture(handleGesture(.start, width: width))
                    .zIndex(3)

                handle(edge: .trailing)
                    .position(x: endX, y: geometry.size.height / 2)
                    .highPriorityGesture(handleGesture(.end, width: width))
                    .zIndex(3)
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: coordinateSpaceName)
            .gesture(playheadGesture(width: width))
        }
        .frame(minWidth: 180, idealHeight: 38, maxHeight: 38)
        .opacity(state.isReady ? 1 : 0.45)
        .allowsHitTesting(state.isReady)
        .accessibilityLabel("视频裁剪时间轴")
    }

    private var playhead: some View {
        Rectangle()
            .fill(.white)
            .frame(width: 2, height: 26)
            .shadow(color: .black.opacity(0.65), radius: 1)
    }

    private enum HandleEdge { case leading, trailing }

    private func handle(edge: HandleEdge) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor)
            .overlay {
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: 14)
            }
            .frame(width: handleWidth, height: 30)
            .contentShape(Rectangle())
    }

    private func handleGesture(_ target: VideoTrimState.DragTarget, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                if state.dragTarget != target { state.beginDragging(target) }
                let time = timeValue(for: value.location.x, width: width)
                if target == .start {
                    state.setStartTime(time)
                } else {
                    state.setEndTime(time)
                }
            }
            .onEnded { _ in state.endDragging() }
    }

    private func playheadGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                if state.dragTarget != .playhead { state.beginDragging(.playhead) }
                state.setCurrentTime(timeValue(for: value.location.x, width: width))
            }
            .onEnded { _ in state.endDragging() }
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard state.duration > 0 else { return 0 }
        return CGFloat(min(max(time / state.duration, 0), 1)) * width
    }

    private func timeValue(for x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return TimeInterval(min(max(x / width, 0), 1)) * state.duration
    }
}
