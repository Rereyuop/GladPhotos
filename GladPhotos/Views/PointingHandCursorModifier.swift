import AppKit
import SwiftUI

private struct PointingHandCursorModifier: ViewModifier {
    @State private var isCursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                if isHovering && !isCursorPushed {
                    NSCursor.pointingHand.push()
                    isCursorPushed = true
                } else if !isHovering && isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
            .onDisappear {
                if isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}
