import SwiftUI
import UIKit

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

/// The tab bar's state as the tabs' main screens see it, for sliding between them.
struct TabPager {
    var index = 0
    var count = 1
    /// +1 when the last switch went to a later tab, -1 to an earlier one.
    var direction = 0
    /// Changes on every switch, so a screen knows to slide in.
    var token = 0
    var go: ((Int) -> Void)?

    func canMove(_ step: Int) -> Bool { (0..<count).contains(index + step) }
}

private struct TabPagerKey: EnvironmentKey {
    static let defaultValue = TabPager()
}

extension EnvironmentValues {
    var tabPager: TabPager {
        get { self[TabPagerKey.self] }
        set { self[TabPagerKey.self] = newValue }
    }
}

/// A tab's main screen follows a sideways swipe and slides off to the next tab; every switch,
/// by swipe or by tapping the tab bar, slides the new screen in from the same side.
private struct TabSwipe: ViewModifier {
    @Environment(\.tabPager) private var pager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat = 0
    @State private var horizontal: Bool?
    @State private var seenToken = 0
    @State private var entranceX: CGFloat = 0
    @State private var entranceOpacity = 1.0

    private var width: CGFloat { UIScreen.main.bounds.width }

    func body(content: Content) -> some View {
        content
            .offset(x: dragX + entranceX)
            .opacity(entranceOpacity)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Decide once per drag: vertical scrolling never moves the screen sideways.
                        if horizontal == nil {
                            horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
                        }
                        guard horizontal == true else { return }
                        let dx = value.translation.width
                        // Resist past the first and last tab.
                        dragX = pager.canMove(dx < 0 ? 1 : -1) ? dx : dx / 3
                    }
                    .onEnded { value in
                        defer { horizontal = nil }
                        guard horizontal == true else { return }
                        let dx = value.translation.width
                        let step = dx < 0 ? 1 : -1
                        let far = abs(dx) > width * 0.25 || abs(value.predictedEndTranslation.width) > width * 0.6
                        guard far, pager.canMove(step), let go = pager.go else {
                            withAnimation(.spring(duration: 0.3)) { dragX = 0 }
                            return
                        }
                        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.14)) { dragX = -CGFloat(step) * width }
                        Task { @MainActor in
                            if !reduceMotion { try? await Task.sleep(for: .milliseconds(140)) }
                            go(step)
                            var reset = Transaction()
                            reset.disablesAnimations = true
                            withTransaction(reset) { dragX = 0 }
                        }
                    }
            )
            .onAppear(perform: enter)
    }

    private func enter() {
        guard pager.token != seenToken else { return }
        seenToken = pager.token
        guard pager.direction != 0, !reduceMotion else { return }
        entranceX = CGFloat(pager.direction) * width * 0.35
        entranceOpacity = 0
        withAnimation(.spring(duration: 0.32, bounce: 0)) {
            entranceX = 0
            entranceOpacity = 1
        }
    }
}

extension View {
    /// Swipe left or right on a tab's main screen to move to the next or previous tab.
    func tabSwipe() -> some View {
        modifier(TabSwipe())
    }

    /// The tile a photo zooms out of and back into (iOS 18+).
    @ViewBuilder
    func zoomSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Open and close with the system zoom, which also gives the pull-down-to-close gesture.
    @ViewBuilder
    func zoomTransition(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
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
