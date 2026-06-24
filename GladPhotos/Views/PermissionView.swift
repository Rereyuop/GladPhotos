import SwiftUI

struct PermissionView: View {
    let authorizationState: PhotoLibraryService.AuthorizationState
    let requestAuthorization: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("需要访问照片", systemImage: "photo")
        } description: {
            Text("允许访问 Mac 照片图库后，可以显示本地照片缩略图。")
        } actions: {
            VStack {
                Button {
                    Task {
                        await requestAuthorization()
                    }
                } label: {
                    Label("允许访问照片", systemImage: "photo")
                }
                .pointingHandCursor()

                if authorizationState == .denied {
                    Button {
                        openPhotoSettings()
                    } label: {
                        Label("打开系统设置", systemImage: "gear")
                    }
                    .pointingHandCursor()
                }
            }
        }
    }

    private func openPhotoSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
