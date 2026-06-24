import AVKit
import SwiftUI

struct ExternalVideoDetailView: View {
    let item: ExternalMediaItem

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var didFinishLoading = false
    @State private var showsSourceInfo = false
    @State private var showsTrimPanel = false
    @StateObject private var trimState = VideoTrimState()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if didFinishLoading {
                ContentUnavailableView(
                    "无法播放视频",
                    systemImage: "video.slash",
                    description: Text("文件可能已损坏、被移除或无法访问。")
                )
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .navigationTitle(item.filename)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsTrimPanel.toggle()
                    }
                } label: {
                    Label("剪辑", systemImage: showsTrimPanel ? "scissors.circle.fill" : "scissors")
                }
                .help(showsTrimPanel ? "关闭裁剪面板" : "打开裁剪面板")
                .disabled(player == nil)
                .pointingHandCursor()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsSourceInfo.toggle()
                    }
                } label: {
                    Label("原文件参数", systemImage: showsSourceInfo ? "info.circle.fill" : "info.circle")
                }
                .help(showsSourceInfo ? "关闭原文件参数" : "显示原文件参数")
                .pointingHandCursor()
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsSourceInfo {
                VideoSourceInfoPanel(fileURL: item.url)
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottom) {
            if showsTrimPanel {
                VideoTrimPanel(sourceURL: item.url, state: trimState)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(9)
            }
        }
        .task(id: item.id) {
            let asset = AVURLAsset(url: item.url)
            do {
                let isPlayable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                guard isPlayable else {
                    trimState.markPlaybackFailed("该视频无法由 AVPlayer 播放。")
                    didFinishLoading = true
                    return
                }
                let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = newPlayer
                trimState.configure(player: newPlayer, duration: duration)
            } catch {
                trimState.markPlaybackFailed(error.localizedDescription)
            }
            didFinishLoading = true
        }
        .onDisappear {
            player?.pause()
            trimState.detachPlayer()
        }
        .onExitCommand {
            dismiss()
        }
    }
}
