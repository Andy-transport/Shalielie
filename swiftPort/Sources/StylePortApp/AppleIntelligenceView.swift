import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

/// Apple Intelligence & Siri page, now tappable instead of greyed out.
/// Photo elimination lives here: pick a photo, paint over what you
/// don't want, and erase it here, instead of hunting for the eraser
/// in other editors. The detail-view Adjust editor still offers the
/// same eraser, but this page is the single home for elimination.
struct AppleIntelligenceView: View {
    @AppStorage("appleIntelligenceEnabled") private var enabled = true
    @State private var pickerItem: PhotosPickerItem?
    @State private var eraseImage: UIImage?
    @State private var showingErase = false
    @State private var loadingPhoto = false
    @State private var activationGlow = false
    @State private var downloadingModel = false
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
                if enabled && downloadingModel {
                    Text("正在下载 LaMa 模型…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if enabled && modelDownloadFailed {
                    Text("LaMa 模型下载失败，消除时会用本机扩散填充；重新打开开关可再试一次。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if enabled && EraseView.isModelReady {
                    Text("LaMa 模型已就绪。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 14) {
                    Image(systemName: "eraser.fill")
                        .font(.title)
                        .frame(width: 72, height: 72)
                        .glassCircle()
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
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .disabled(loadingPhoto || !enabled)
                }
                .opacity(enabled ? 1 : 0.5)
                .padding(.vertical, 8)
                if !enabled {
                    Text("需打开 Apple智能才能用消除。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("选一张照片，手指涂抹不要的东西：普通消除用本机扩散填充，消除用 LaMa 模型生成填充（打开 Apple智能时首次下载模型，照片不出手机）。完成后存为新照片，不改原图。合规：涉及敏感标识的照片不得消除，消除页会先做合规审查。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("照片消除")
            } footer: {
                Text("也可以在照片详情页的调整编辑器里点底部的消除页签打开同一个消除页。")
            }
        }
        .onChange(of: enabled) { _, value in
            if value {
                playBundledSound("SiriChime")
                activationGlow = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    activationGlow = false
                }
                // First time Apple Intelligence is turned on, download
                // the LaMa model, so Erase is ready when it is used.
                if !EraseView.isModelReady {
                    Task {
                        downloadingModel = true
                        modelDownloadFailed = false
                        do {
                            try await EraseView.downloadModelIfNeeded()
                        } catch {
                            modelDownloadFailed = true
                        }
                        downloadingModel = false
                    }
                }
            }
        }
        .onAppear {
            if enabled && !EraseView.isModelReady && !downloadingModel {
                Task {
                    downloadingModel = true
                    modelDownloadFailed = false
                    do {
                        try await EraseView.downloadModelIfNeeded()
                    } catch {
                        modelDownloadFailed = true
                    }
                    downloadingModel = false
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
