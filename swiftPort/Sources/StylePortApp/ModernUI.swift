import SwiftUI

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, max(0, (width - maxWidth) / 2), for: .scrollContent)
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

extension View {
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
