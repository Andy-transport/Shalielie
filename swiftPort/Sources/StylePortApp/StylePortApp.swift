import SwiftUI
import UserNotifications

@main
struct StylePortApp: App {
    @StateObject private var queue = PortQueue()
    @StateObject private var backups = BackupStore()

    init() {
        AppSettings.registerDefaults()
        UNUserNotificationCenter.current().delegate = EraseNotificationDelegate.shared
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

struct RootView: View {
    @EnvironmentObject private var queue: PortQueue
    @State private var showingActivity = false
    // 0 = 图库, 1 = 相簿, 2 = 备份. 人像不是页签, 是打开设置页的按钮.
    @State private var selectedTab = 0
    // LibraryTab 的主页 / 网格状态: 主页时底部栏隐藏, 网格时显示.
    @State private var libraryRevealed = false
    @State private var showingSettings = false

    private var showingBottomBar: Bool {
        !(selectedTab == 0 && !libraryRevealed)
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
                    HStack(spacing: 12) {
                        HStack(spacing: 28) {
                            tabButton(title: "图库", systemImage: "photo.stack", tab: 0)
                            tabButton(title: "相簿", systemImage: "square.stack", tab: 1)
                            tabButton(title: "备份", systemImage: "archivebox", tab: 2)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .floatingGlass()
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.title3)
                                .frame(width: 48, height: 48)
                                .glassCircle()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
        }
        .animation(.spring(duration: 0.3), value: queue.statusLine)
        .sheet(isPresented: $showingActivity) {
            ActivitySheet()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsTab()
        }
    }

    private func tabButton(title: String, systemImage: String, tab: Int) -> some View {
        Button {
            selectedTab = tab
            // 从相簿 / 备份切回图库时直接进网格, 不回主页
            // (主页只能从网格的 首页 回去, 那时底部栏会隐藏).
            if tab == 0 { libraryRevealed = true }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
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
