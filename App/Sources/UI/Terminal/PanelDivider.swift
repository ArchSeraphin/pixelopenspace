import AppKit
import SwiftUI

/// Horizontal divider above the terminal panel: drag it to resize the panel (resize cursor on hover).
struct PanelDivider: View {
    @Binding var height: Double
    let range: ClosedRange<Double>

    @State private var dragStartHeight: Double?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != isHovering else { return }
                isHovering = inside
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? height
                        if dragStartHeight == nil { dragStartHeight = height }
                        let proposed = start - Double(value.translation.height)
                        height = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Séparateur du terminal")
            .accessibilityValue("\(Int(height)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: height = min(height + 40, range.upperBound)
                case .decrement: height = max(height - 40, range.lowerBound)
                @unknown default: break
                }
            }
    }
}
