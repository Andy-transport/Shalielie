import SwiftUI

@main
struct StylePortApp: App {
    @StateObject private var queue = PortQueue()
    @StateObject private var backups = BackupStore()

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(queue)
                .environment(\.portQueue, queue)
                .environmentObject(backups)
                .task { queue.backups = backups }
        }
    }
}

private struct PortQueueKey: EnvironmentKey {
    static let defaultValue: PortQueue? = nil
}

extension EnvironmentValues {
    /// The queue without observing it, for views that start jobs but don't show progress.
    var portQueue: PortQueue? {
        get { self[PortQueueKey.self] }
        set { self[PortQueueKey.self] = newValue }
    }
}

/// Shared flag: true while a photo detail view is open in any grid.
/// RootView hides the bottom bar while this is true.
final class PhotoDetailState: ObservableObject {
    @Published var isPresented = false
}

struct RootView: View {
    @EnvironmentObject private var queue: PortQueue
    @StateObject private var photoDetailState = PhotoDetailState()
    @State private var showingActivity = false
    // 0 = 图库, 1 = 相簿, 2 = 备份. 人像不是页签, 是打开设置页的按钮.
    @State private var selectedTab = 0
    // LibraryTab 的主页 / 网格状态: 主页时底部栏隐藏, 网格时显示.
    @State private var libraryRevealed = false
    @State private var showingSettings = false

    private var showingBottomBar: Bool {
        !(selectedTab == 0 && !libraryRevealed) && !photoDetailState.isPresented
    }

    var body: some View {
        Group {
            switch selectedTab {
            case 1:
                AlbumsTab()
            case 2:
                BackupBinTab()
            default:
                LibraryTab(libraryRevealed: $libraryRevealed)
            }
        }
        .environmentObject(photoDetailState)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if let status = queue.statusLine {
                    Button {
                        showingActivity = true
                        queue.dismissStatus()
                    } label: {
                        ActivityCapsule(status: status, isRunning: queue.isRunning)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showingBottomBar {
                    HStack(spacing: 14) {
                        HStack(spacing: 36) {
                            tabButton(title: "图库", systemImage: "photo.stack", tab: 0)
                            tabButton(title: "相簿", systemImage: "square.stack", tab: 1)
                            tabButton(title: "备份", systemImage: "archivebox", tab: 2)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        // Plain translucent capsule instead of floatingGlass:
                        // the glass container was hiding the tab labels on
                        // device, leaving icons with a large empty space.
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .contentShape(Capsule())
                        // High priority: a swipe starting on a tab button must
                        // switch tabs instead of being swallowed by the button.
                        // A plain tap still fires the button (drag fails first).
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 30)
                                .onEnded { value in
                                    withAnimation {
                                        if value.translation.width < -30 {
                                            selectTab(min(2, selectedTab + 1))
                                        } else if value.translation.width > 30 {
                                            selectTab(max(0, selectedTab - 1))
                                        }
                                    }
                                }
                        )
                        Button { showingSettings = true } label: {
                            Image(systemName: "person.fill")
                                .font(.title2)
                                .frame(width: 56, height: 56)
                                .glassCircle()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.3), value: queue.statusLine)
        .animation(.easeInOut(duration: 0.25), value: showingBottomBar)
        .sheet(isPresented: $showingActivity) {
            ActivitySheet()
        }
        .fullScreenCover(isPresented: $showingSettings) {
            SettingsTab()
        }
    }

    private func selectTab(_ tab: Int) {
        selectedTab = tab
        // 从相簿 / 备份切回图库时直接进网格, 不回主页
        // (主页只能从网格的 首页 回去, 那时底部栏会隐藏).
        if tab == 0 { libraryRevealed = true }
    }

    private func tabButton(title: String, systemImage: String, tab: Int) -> some View {
        Button {
            selectTab(tab)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.white)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selectedTab == tab ? Color.accentColor.opacity(0.25) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ActivityCapsule: View {
    let status: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isRunning {
                ProgressView()
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(status)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .floatingGlass()
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
