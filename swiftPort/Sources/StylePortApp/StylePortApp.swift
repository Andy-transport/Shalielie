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

    var body: some View {
        LibraryTab()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let status = queue.statusLine {
                Button {
                    showingActivity = true
                    queue.dismissStatus()
                } label: {
                    ActivityCapsule(status: status, isRunning: queue.isRunning)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
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
