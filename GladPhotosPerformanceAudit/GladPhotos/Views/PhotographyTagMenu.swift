import SwiftUI

struct PhotographyTagMenu: View, Equatable {
    let record: PhotographyAnalysisRecord?
    let setManualTag: (PhotographyTag?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.record == rhs.record
    }

    private var tag: PhotographyTag { record?.effectiveTag ?? .unknown }

    var body: some View {
        Menu {
            Button("设为摄影") { setManualTag(.photography) }
            Button("设为非摄影") { setManualTag(.nonPhotography) }
            Divider()
            Button("清除手动标签") { setManualTag(nil) }
                .disabled(record?.manualTag == nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("修改摄影标签")
    }

    private var label: String {
        if record?.isManual == true { return "\(tag.title) · 手动" }
        guard tag != .unknown,
              let confidence = record?.confidence,
              confidence > 0
        else { return tag.title }
        return "\(tag.title) \(Int((confidence * 100).rounded()))%"
    }

    private var iconName: String {
        switch tag {
        case .photography: "camera"
        case .nonPhotography: "rectangle.on.rectangle.slash"
        case .unknown: "questionmark.circle"
        }
    }
}
