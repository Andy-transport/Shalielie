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
                if enabled {
                    HStack(spacing: 10) {
                        SiriOrb()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Siri 光效").font(.subheadline.weight(.medium))
                            Text("彩色光沿屏幕边缘流动").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    VStack(spacing: 10) {
                        Image(systemName: "eraser.fill")
                            .font(.title)
                            .frame(width: 72, height: 72)
                            .glassCircle()
                        Text(loadingPhoto ? "正在读取照片…" : "消除")
                            .font(.headline)
                        Text("选择照片消除")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .disabled(loadingPhoto)
                Text("选一张照片，手指涂抹不要的东西：普通消除用本机扩散填充，AI 消除用 LaMa 模型生成填充（首次使用时下载模型，照片不出手机）。完成后存为新照片，不改原图。合规：涉及敏感标识的照片不得消除，消除页会先做合规审查。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("照片消除")
            } footer: {
                Text("也可以在照片详情页的调整编辑器里点橡皮图标打开同一个消除页。")
            }
        }
        .onChange(of: enabled) { _, value in
            if value { playBundledSound("SiriChime") }
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
            // Apple Intelligence Siri edge glow: when Apple Intelligence
            // is on, a colourful gradient light wraps the screen edges,
            // like invoking Siri in iOS 18. It is purely visual and
            // never blocks taps.
            if enabled {
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.pink, .orange, .yellow, .green, .blue, .purple, .pink]),
                        center: .center,
                        angle: .degrees(angle)
                    ),
                    lineWidth: 10
                )
                .blur(radius: 16)
                .opacity(0.85)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.pink, .orange, .yellow, .green, .blue, .purple, .pink]),
                        center: .center,
                        angle: .degrees(angle)
                    ),
                    lineWidth: 3
                )
                .opacity(0.95)
        }
        .padding(2)
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}

/// Siri orb preview: a small colourful ball with a breathing glow,
/// shown on this page when Apple Intelligence is on.
private struct SiriOrb: View {
    @State private var angle: Double = 0
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [.pink, .orange, .yellow, .green, .blue, .purple, .pink]),
                        center: .center,
                        angle: .degrees(angle)
                    )
                )
                .blur(radius: 10)
                .opacity(0.7)
                .scaleEffect(breathing ? 1.15 : 1.0)
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [.pink, .orange, .yellow, .green, .blue, .purple, .pink]),
                        center: .center,
                        angle: .degrees(angle)
                    )
                )
        }
        .frame(width: 36, height: 36)
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                angle = 360
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
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
    guard let asset = NSDataAsset(name: name) else { return }
    do {
        bundledSoundPlayer = try AVAudioPlayer(data: asset.data)
        bundledSoundPlayer?.play()
    } catch {
        // Sound is cosmetic; never block the feature on audio failure.
    }
}
