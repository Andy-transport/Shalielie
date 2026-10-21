import SwiftUI

/// A localized string for places that need a String rather than a view's LocalizedStringKey.
func L(_ key: String.LocalizationValue) -> String { String(localized: key) }

/// Use the system's Liquid Glass on iOS 26+, with material fallbacks on older devices.
extension View {
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
