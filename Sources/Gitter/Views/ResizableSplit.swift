import SwiftUI

/// A vertical two-pane split with a draggable divider whose position is remembered in
/// UserDefaults. Unlike `VSplitView`, the initial proportion is controllable.
struct VerticalSplit<Top: View, Bottom: View>: View {
    @AppStorage private var fraction: Double
    private let minTop: CGFloat
    private let minBottom: CGFloat
    private let top: Top
    private let bottom: Bottom

    @State private var dragStartHeight: CGFloat?
    @State private var hovering = false

    init(storageKey: String, defaultFraction: Double = 0.5, minTop: CGFloat = 120, minBottom: CGFloat = 120,
         @ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        _fraction = AppStorage(wrappedValue: defaultFraction, storageKey)
        self.minTop = minTop
        self.minBottom = minBottom
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let topHeight = clampedTopHeight(total: total)
            VStack(spacing: 0) {
                top
                    .frame(maxWidth: .infinity)
                    .frame(height: topHeight)
                    .clipped()
                divider(total: total, topHeight: topHeight)
                bottom
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
    }

    private func clampedTopHeight(total: CGFloat) -> CGFloat {
        guard total > 0 else { return minTop }
        let maxTop = max(total - minBottom, minTop)
        return min(max(total * fraction, minTop), maxTop)
    }

    private func divider(total: CGFloat, topHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .overlay {
                // Wider invisible grab area than the 1pt line.
                Color.clear.frame(height: 9).contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartHeight ?? topHeight
                                dragStartHeight = start
                                let proposed = start + value.translation.height
                                let maxTop = max(total - minBottom, minTop)
                                fraction = Double(min(max(proposed, minTop), maxTop) / total)
                            }
                            .onEnded { _ in dragStartHeight = nil }
                    )
            }
            .zIndex(1)
    }
}
