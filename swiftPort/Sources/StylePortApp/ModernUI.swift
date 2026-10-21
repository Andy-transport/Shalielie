import SwiftUI

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let margin = (width - maxWidth) / 2
        // Below the limit, keep the system's inset grouped margins: a zero margin would
        // stretch rows edge to edge.
        Group {
            if margin > 0 {
                content.contentMargins(.horizontal, margin, for: .scrollContent)
            } else {
                content
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { width = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, new in width = new }
            }
        }
    }
}

/// A localized string for places that need a String rather than a view's LocalizedStringKey.
func L(_ key: String.LocalizationValue) -> String { String(localized: key) }

private struct TabSwipe: ViewModifier {
    @Environment(\.switchTab) private var switchTab

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                let dx = value.translation.width
                // Clearly sideways and far enough: vertical scrolling must never switch tabs.
                guard abs(dx) > 80, abs(dx) > abs(value.translation.height) * 2 else { return }
                switchTab?(dx < 0 ? 1 : -1)
            }
        )
    }
}

extension View {
    /// Swipe left or right on a tab's main screen to move to the next or previous tab.
    func tabSwipe() -> some View {
        modifier(TabSwipe())
    }

    /// Keep a list or form at a comfortable reading width on iPad and in landscape.
    func readableWidth(_ maxWidth: CGFloat = 720) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth))
    }

    /// A centred form sheet on iPad (iOS 18+); iPhone is unchanged.
    @ViewBuilder
    func formSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(.form)
        } else {
            self
        }
    }

    /// Use the system's Liquid Glass on iOS 26+, with material fallbacks on older devices.
    @ViewBuilder
    func floatingGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func modernProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func modernTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
