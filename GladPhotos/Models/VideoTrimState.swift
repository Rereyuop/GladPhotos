import AVFoundation
import Combine
import Foundation

@MainActor
final class VideoTrimState: ObservableObject {
    enum DragTarget {
        case start, end, playhead
    }

    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var startTime: TimeInterval = 0
    @Published private(set) var endTime: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isReady = false
    @Published private(set) var playbackError: String?
    @Published private(set) var dragTarget: DragTarget?

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    var selectionDuration: TimeInterval { max(0, endTime - startTime) }

    var minimumClipDuration: TimeInterval {
        guard duration > 0 else { return 0 }
        return min(duration, min(1, max(0.05, duration * 0.01)))
    }

    func configure(player: AVPlayer, duration: TimeInterval) {
        detachPlayer()
        self.player = player

        guard duration.isFinite, duration > 0 else {
            playbackError = "视频没有可用的时长信息。"
            return
        }

        self.duration = duration
        startTime = 0
        endTime = duration
        currentTime = 0
        isReady = true
        playbackError = nil

        statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "播放器加载失败。"
            Task { @MainActor [weak self] in
                self?.markPlaybackFailed(reason)
            }
        }

        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            guard let self, let player else { return }
            Task { @MainActor in
                self.updatePlayback(time.seconds, player: player)
            }
        }
    }

    func detachPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player = nil
    }

    func beginDragging(_ target: DragTarget) {
        dragTarget = target
    }

    func endDragging() {
        dragTarget = nil
    }

    func setStartTime(_ value: TimeInterval, seek: Bool = true) {
        guard isReady else { return }
        startTime = clamp(value, lower: 0, upper: endTime - minimumClipDuration)
        if currentTime < startTime { currentTime = startTime }
        if seek { seekPlayer(to: startTime) }
    }

    func setEndTime(_ value: TimeInterval, seek: Bool = true) {
        guard isReady else { return }
        endTime = clamp(value, lower: startTime + minimumClipDuration, upper: duration)
        if currentTime > endTime { currentTime = endTime }
        if seek { seekPlayer(to: endTime) }
    }

    func setCurrentTime(_ value: TimeInterval) {
        guard isReady else { return }
        currentTime = clamp(value, lower: 0, upper: duration)
        seekPlayer(to: currentTime)
    }

    func reset() {
        guard isReady else { return }
        startTime = 0
        endTime = duration
        currentTime = 0
        seekPlayer(to: 0)
    }

    func markPlaybackFailed(_ reason: String) {
        playbackError = reason
        isReady = false
    }

    static func format(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "--:--:--.---" }
        let milliseconds = Int64((value * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, remainder)
    }

    static func parse(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]),
              hours >= 0, minutes >= 0, minutes < 60,
              seconds >= 0, seconds < 60 else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private func updatePlayback(_ value: TimeInterval, player: AVPlayer) {
        guard value.isFinite else { return }

        if player.currentItem?.status == .failed {
            markPlaybackFailed(player.currentItem?.error?.localizedDescription ?? "播放器加载失败。")
            return
        }

        currentTime = clamp(value, lower: 0, upper: duration)
        guard dragTarget == nil, endTime > startTime else { return }

        if player.rate != 0, currentTime < startTime {
            seekPlayer(to: startTime)
        } else if currentTime >= endTime - 0.015 {
            player.pause()
            currentTime = startTime
            seekPlayer(to: startTime)
        }
    }

    private func seekPlayer(to value: TimeInterval) {
        let time = CMTime(seconds: value, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func clamp(_ value: TimeInterval, lower: TimeInterval, upper: TimeInterval) -> TimeInterval {
        min(max(value.isFinite ? value : lower, lower), max(lower, upper))
    }
}
