import Photos
import PhotosUI
import SwiftUI

struct LivePhotoPlayerView: NSViewRepresentable {
    let livePhoto: PHLivePhoto
    let assetIdentifier: String
    let replayTrigger: Int
    let automaticallyPlays: Bool
    let isMuted: Bool

    init(
        livePhoto: PHLivePhoto,
        assetIdentifier: String,
        replayTrigger: Int = 0,
        automaticallyPlays: Bool = true,
        isMuted: Bool = false
    ) {
        self.livePhoto = livePhoto
        self.assetIdentifier = assetIdentifier
        self.replayTrigger = replayTrigger
        self.automaticallyPlays = automaticallyPlays
        self.isMuted = isMuted
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .aspectFit
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.audioVolume = 1
        view.isMuted = isMuted
        view.livePhoto = livePhoto

        let clickGesture = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.replay)
        )
        view.addGestureRecognizer(clickGesture)
        context.coordinator.livePhotoView = view
        context.coordinator.assetIdentifier = assetIdentifier
        context.coordinator.livePhotoIdentifier = ObjectIdentifier(livePhoto)
        context.coordinator.replayTrigger = replayTrigger
        if automaticallyPlays {
            playOnce(view)
        }
        return view
    }

    func updateNSView(_ view: PHLivePhotoView, context: Context) {
        let livePhotoIdentifier = ObjectIdentifier(livePhoto)
        if context.coordinator.assetIdentifier != assetIdentifier ||
            context.coordinator.livePhotoIdentifier != livePhotoIdentifier {
            view.stopPlayback()
            view.livePhoto = livePhoto
            context.coordinator.assetIdentifier = assetIdentifier
            context.coordinator.livePhotoIdentifier = livePhotoIdentifier
            if automaticallyPlays {
                playOnce(view)
            }
        } else if context.coordinator.replayTrigger != replayTrigger {
            context.coordinator.replayTrigger = replayTrigger
            context.coordinator.replay()
        }
        view.isMuted = isMuted
    }

    static func dismantleNSView(
        _ view: PHLivePhotoView,
        coordinator: Coordinator
    ) {
        view.stopPlayback()
        view.livePhoto = nil
        coordinator.livePhotoView = nil
        coordinator.assetIdentifier = nil
        coordinator.livePhotoIdentifier = nil
        coordinator.replayTrigger = 0
    }

    private func playOnce(_ view: PHLivePhotoView) {
        DispatchQueue.main.async { [weak view] in
            view?.startPlayback(with: .full)
        }
    }

    final class Coordinator: NSObject {
        weak var livePhotoView: PHLivePhotoView?
        var assetIdentifier: String?
        var livePhotoIdentifier: ObjectIdentifier?
        var replayTrigger = 0

        @objc func replay() {
            livePhotoView?.stopPlayback()
            livePhotoView?.startPlayback(with: .full)
        }
    }
}
