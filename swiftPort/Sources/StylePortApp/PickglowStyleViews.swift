import Photos
import SwiftUI
import UIKit

/// Pickglow-style welcome screen. Every row is a real action, not a picture:
/// 选择照片 goes to photo selection, 添加风格 goes to the library grid where
/// a photo can be styled, 到照片 App 编辑 tries to open the Photos app.
struct WelcomeView: View {
    var onSkip: () -> Void
    var onContinue: () -> Void
    var onSelectPhotos: () -> Void
    var onBrowseAll: () -> Void
    var onConvert: () -> Void = {}

    @State private var photosOpenFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 10) {
                    Image("AboutIcon")
                        .resizable()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("Floating light").font(.title3.bold())
                }
                Spacer()
                Button("跳过") { onSkip() }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .floatingGlass()
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(.largeTitle)
                        .frame(width: 96, height: 96)
                        .glassCircle()
                        .padding(.top, 28)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("欢迎").font(.subheadline).foregroundStyle(.secondary)
                        Text("让HEIF照片\n用上摄影风格")
                            .font(.system(size: 40, weight: .bold))
                            .lineSpacing(4)
                        Text("在本机为照片写入摄影风格数据。存入后，到照片 App 里像新拍的照片一样调整。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                    }

                    VStack(spacing: 0) {
                        welcomeRow(
                            systemImage: "photo",
                            title: "选择照片",
                            subtitle: "从图库选择，或用「文件」导入 JPG、RAW 与实况照片。",
                            action: onSelectPhotos
                        )
                        Divider().padding(.leading, 72)
                        welcomeRow(
                            systemImage: "square.and.arrow.down",
                            title: "添加风格，一次存入",
                            subtitle: "检查兼容性、写入并校验风格数据，一次存入照片。",
                            action: onBrowseAll
                        )
                        Divider().padding(.leading, 72)
                        welcomeRow(
                            systemImage: "photo.on.rectangle.angled",
                            title: "到照片 App 编辑",
                            subtitle: "打开这张照片，轻点「编辑」使用摄影风格。",
                            action: openPhotosApp
                        )
                    }
                    .glassCard(24)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Capsule().fill(Color.primary).frame(width: 28, height: 6)
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                }
                Button { onContinue() } label: {
                    Text("继续")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .floatingGlass()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .alert(
            "无法打开照片 App",
            isPresented: $photosOpenFailed
        ) {
            Button("确定") {}
        } message: {
            Text("请手动打开系统照片 App，找到刚才存入的照片再点编辑。")
        }
    }

    private func welcomeRow(systemImage: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 56, height: 56)
                    .glassCircle()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineSpacing(2)
                }
                Spacer()
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openPhotosApp() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                DispatchQueue.main.async { photosOpenFailed = true }
            }
        }
    }
}

/// Pickglow-style home screen for the Library tab.
///
/// This is the start screen, not the full library grid: it shows a banner,
/// an empty "我的照片" card until photos are chosen, and two working buttons.
/// 选择照片 reveals the grid (and opens the limited-library picker when
/// access is limited); 文件 · RAW opens the file importer.
struct PickglowHomeView: View {
    var status: PHAuthorizationStatus
    var photoCount: Int
    var onSelectPhotos: () -> Void
    var onImportFiles: () -> Void
    var onBrowseAll: () -> Void
    var onConvert: () -> Void = {}

    @State private var showingSettings = false
    @State private var appeared = false
    @AppStorage("speakerEnabled") private var speakerEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image("AboutIcon")
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Text("Floating light").font(.largeTitle.bold())
                    Spacer()
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .glassCircle()
                    }
                    .buttonStyle(.plain)
                }

                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.55, green: 0.78, blue: 1.0), Color(red: 0.22, green: 0.48, blue: 0.96), Color(red: 0.04, green: 0.14, blue: 0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Text("风格")
                            .font(.caption.weight(.semibold))
                            .tracking(3)
                            .foregroundStyle(.white.opacity(0.8))
                        Text("让HEIF照片用上摄影风格")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text("写入风格数据，回到照片 App 继续调色与质感")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                Text("我的照片").font(.title2.bold())

                VStack(spacing: 12) {
                    if photoCount == 0 {
                        Image(systemName: "photo.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                        Text("还没有照片").font(.headline)
                        Text("点「选择照片」从图库添加，或从文件导入相机照片和 RAW。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                    } else {
                        Text("已加载 \(photoCount) 张照片")
                            .font(.headline)
                            .padding(.top, 20)
                        Button("浏览全部照片") { onBrowseAll() }
                            .font(.subheadline.weight(.semibold))
                            .padding(.bottom, 20)
                    }
                }
                .frame(maxWidth: .infinity)
                .glassCard()

                HStack(spacing: 12) {
                    Button { onSelectPhotos() } label: {
                        Label("选择照片", systemImage: "photo")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .floatingGlass()
                    }
                    .buttonStyle(.plain)
                    Button { onImportFiles() } label: {
                        Label("文件", systemImage: "folder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .floatingGlass()
                    }
                    .buttonStyle(.plain)
                }

                Button { onConvert() } label: {
                    Label("转换 HEIF", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .floatingGlass()
                }
                .buttonStyle(.plain)

                Button("浏览全部照片") { onBrowseAll() }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                // Home-page permissions: photo access status, plus a
                // speaker row. iOS has no separate speaker permission
                // dialog, so this row is the app's speaker switch:
                // on = Siri sound plays through the speaker, off = muted.
                // Turning it on plays the Siri sound once as a test.
                VStack(alignment: .leading, spacing: 12) {
                    Text("权限").font(.headline)
                    HStack {
                        Label("照片", systemImage: "photo")
                        Spacer()
                        Text(photoAccessText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Label("扬声器", systemImage: "speaker.wave.2")
                        Spacer()
                        Toggle("", isOn: $speakerEnabled)
                            .labelsHidden()
                    }
                }
                .padding(16)
                .glassCard()
                .onChange(of: speakerEnabled) { _, value in
                    if value { playBundledSound("SiriChime") }
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .animation(.easeOut(duration: 0.45), value: appeared)
        .onAppear { appeared = true }
        .sheet(isPresented: $showingSettings) {
            SettingsTab()
        }
    }

    private var photoAccessText: String {
        switch status {
        case .authorized: return "全部"
        case .limited: return "选择范围"
        case .denied, .restricted: return "未允许"
        case .notDetermined: return "未设置"
        @unknown default: return "未知"
        }
    }
}
