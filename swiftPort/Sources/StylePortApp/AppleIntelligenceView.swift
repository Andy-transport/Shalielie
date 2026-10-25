import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

/// Apple Intelligence & Siri page: the Apple Intelligence switch, with
/// the Erase row directly below it in the same card. Erase has no
/// switch of its own: it follows this switch, so it can never be
/// opened on its own. It is also reachable from the Adjust editor
/// (top eraser button and the Tools AI消除 button), same switch.
struct AppleIntelligenceView: View {
    @AppStorage("appleIntelligenceEnabled") private var enabled = true
    @State private var pickerItem: PhotosPickerItem?
    @State private var eraseImage: UIImage?
    @State private var showingErase = false
    @State private var loadingPhoto = false
    @State private var activationGlow = false
    @State private var activationBurst = false
    @State private var downloadingModel = false
    @State private var downloadProgress: Double? = nil
    @State private var modelDownloadFailed = false

    var body: some View {
        ZStack {
            Form {
            Section {
                HStack(spacing: 14) {
                    Image("AppleIntelligence")
                        .resizable()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple智能与Siri").font(.title3.bold())
                        Text("照片消除集中在这里").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Toggle("Apple智能", isOn: $enabled)
                if enabled && modelDownloadFailed {
                    Text("LaMa 模型下载失败，消除时会用本机扩散填充；重新打开开关可再试一次。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if enabled && EraseView.isModelReady {
                    Text("LaMa 模型已就绪。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // Erase lives directly below the Apple Intelligence
                // switch, in this same card, not as a separate section.
                // No switch of its own: the 打开 button is only enabled
                // while Apple Intelligence is on.
                HStack(spacing: 14) {
                    Image("EraseIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loadingPhoto ? "正在读取照片…" : "消除")
                            .font(.headline)
                        Text("选择照片消除")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text("打开")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.08), in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .disabled(loadingPhoto || !enabled)
                }
                .opacity(enabled ? 1 : 0.5)
                .padding(.vertical, 4)
                if !enabled {
                    Text("需打开 Apple智能才能用消除。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .onChange(of: enabled) { _, value in
            if value {
                playBundledSound("SiriChime")
                activationGlow = true
                // Toggle-on activation effect: a soft Siri glow burst
                // expanding from the centre, on top of the edge glow,
                // for the same 3 seconds, then out.
                activationBurst = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    activationGlow = false
                    activationBurst = false
                }
                // First time Apple Intelligence is turned on, download
                // the LaMa model, so Erase is ready when it is used.
                if !EraseView.isModelReady {
                    Task {
                        downloadingModel = true
                        downloadProgress = nil
                        UserDefaults.standard.set(0.0, forKey: "lamaModelDownloadProgress")
                        modelDownloadFailed = false
                        do {
                            try await EraseView.downloadModelIfNeeded { progress in
                                downloadProgress = progress
                                UserDefaults.standard.set(progress, forKey: "lamaModelDownloadProgress")
                            }
                            postEraseReadyNotification()
                            UserDefaults.standard.set(-1.0, forKey: "lamaModelDownloadProgress")
                        } catch {
                            modelDownloadFailed = true
                            UserDefaults.standard.set(-1.0, forKey: "lamaModelDownloadProgress")
                            Task {
                                try? await Task.sleep(for: .seconds(5))
                                modelDownloadFailed = false
                            }
                        }
                        downloadingModel = false
                        downloadProgress = nil
                    }
                }
            }
        }
        .onAppear {
            if enabled && !EraseView.isModelReady && !downloadingModel {
                Task {
                    downloadingModel = true
                    downloadProgress = nil
                    UserDefaults.standard.set(0.0, forKey: "lamaModelDownloadProgress")
                    modelDownloadFailed = false
                    do {
                        try await EraseView.downloadModelIfNeeded { progress in
                                downloadProgress = progress
                                UserDefaults.standard.set(progress, forKey: "lamaModelDownloadProgress")
                            }
                        postEraseReadyNotification()
                        UserDefaults.standard.set(-1.0, forKey: "lamaModelDownloadProgress")
                    } catch {
                        modelDownloadFailed = true
                        UserDefaults.standard.set(-1.0, forKey: "lamaModelDownloadProgress")
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            modelDownloadFailed = false
                        }
                    }
                    downloadingModel = false
                    downloadProgress = nil
                }
            }
            // Sound and animation start in the same moment: play the
            // Siri sound and show the edge glow together for 3 seconds.
            activationGlow = true
            playBundledSound("SiriChime")
            Task {
                try? await Task.sleep(for: .seconds(3))
                activationGlow = false
            }
        }
        .navigationTitle("Apple智能与Siri")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            loadingPhoto = true
            Task {
                defer { loadingPhoto = false }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    eraseImage = image
                    showingErase = true
                }
                pickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showingErase) {
            if let eraseImage {
                EraseView(image: eraseImage)
            }
        }
            // Siri edge glow, only 3 seconds at a time: it lights up
            // together with the sound when this page opens or when the
            // Apple Intelligence toggle is turned on, then goes out.
            // It never stays on permanently.
            if activationGlow {
                SiriGlowBorder()
                    .allowsHitTesting(false)
            }
            if activationBurst {
                ActivationBurstView()
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Siri edge glow: a colourful gradient border that slowly rotates
/// around the screen edges, with a soft blurred halo behind a sharp
/// inner line, like the light Siri shows when it is listening.
private struct SiriGlowBorder: View {
    @State private var angle: Double = 0
    @State private var breathing = false

    // Like the Siri settings page in the screenshot: NOT a sharp
    // border line, but a soft, diffuse halo leaking in from the
    // screen edges, stronger at the corners, pink/orange on the
    // left, purple/blue on the right and bottom. Two wide, heavily
    // blurred gradient strokes give that soft light, not a line.
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 48, style: .continuous)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.pink, .orange, .purple, .blue, .cyan, .pink]),
                        center: .center,
                        angle: .degrees(angle)
                    ),
                    lineWidth: 64
                )
                .blur(radius: 42)
                .opacity(breathing ? 0.75 : 0.55)
            RoundedRectangle(cornerRadius: 48, style: .continuous)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.pink, .orange, .purple, .blue, .cyan, .pink]),
                        center: .center,
                        angle: .degrees(angle)
                    ),
                    lineWidth: 22
                )
                .blur(radius: 18)
                .opacity(0.55)
        }
        .padding(0)
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                angle = 360
            }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}


/// Toggle-on activation burst: a soft, colourful glow that expands
/// from the centre and fades out over about 2.6 seconds. It is only
/// shown when the Apple Intelligence switch is turned on, never
/// permanently, and it never blocks touches.
private struct ActivationBurstView: View {
    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0.9

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [.pink, .orange, .purple, .blue, .cyan, .pink]),
                        center: .center
                    )
                )
                .blur(radius: 60)
                .frame(width: 420, height: 420)
                .scaleEffect(scale)
                .opacity(opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 2.6)) {
                scale = 1.5
                opacity = 0
            }
        }
    }
}

/// Local-notification delegate so the "照片消除已就绪" banner shows
/// even while the app is in the foreground.
final class EraseNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = EraseNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// After the model finishes downloading, pop an iPhone notification.
/// Authorization is requested first; if the user declines, no banner
/// can appear (iOS rule), and the in-app "已就绪" line still shows.
private func postEraseReadyNotification() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "照片消除已就绪"
        content.body = "LaMa 模型已下载完成，现在可以消除照片了。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "erase-ready", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        center.add(request)
    }
}

/// Play a short bundled sound (NSDataAsset from Assets.xcassets).
/// Kept in a static player so it is not released mid-play.
/// Respects the silent switch (default audio session).
private var bundledSoundPlayer: AVAudioPlayer?

func playBundledSound(_ name: String) {
    // Home-page speaker permission: off means no sound at all.
    // Default is on when the setting has never been touched.
    if UserDefaults.standard.object(forKey: "speakerEnabled") as? Bool == false { return }
    guard let asset = NSDataAsset(name: name) else { return }
    do {
        bundledSoundPlayer = try AVAudioPlayer(data: asset.data)
        bundledSoundPlayer?.play()
    } catch {
        // Sound is cosmetic; never block the feature on audio failure.
    }
}
