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
                .environmentObject(backups)
                .task { queue.backups = backups }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var queue: PortQueue
    @State private var showingActivity = false

    /// "Me" sits apart from the other tabs, at the bottom right, on iOS 26 (the search role is
    /// the system's detached trailing tab); earlier systems show it as a normal tab.
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView {
                Tab("Library", systemImage: "photo.on.rectangle") { LibraryTab() }
                Tab("Albums", systemImage: "rectangle.stack") { AlbumsTab() }
                Tab("Backup Bin", systemImage: "archivebox") { BackupBinTab() }
                Tab("Me", systemImage: "person.crop.circle", role: .search) { SettingsTab() }
            }
        } else {
            TabView {
                LibraryTab()
                    .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
                AlbumsTab()
                    .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                BackupBinTab()
                    .tabItem { Label("Backup Bin", systemImage: "archivebox") }
                SettingsTab()
                    .tabItem { Label("Me", systemImage: "person.crop.circle") }
            }
        }
    }

    var body: some View {
        tabs
        .modernTabBar()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let status = queue.statusLine {
                Button {
                    showingActivity = true
                    queue.dismissStatus()
                } label: {
                    ActivityCapsule(status: status, isRunning: queue.isRunning)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 56)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: queue.statusLine)
        .sheet(isPresented: $showingActivity) {
            ActivitySheet()
        }
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
