import Photos
import StylePortCore
import SwiftUI
import UIKit

struct SettingsTab: View {
    @EnvironmentObject private var backups: BackupStore
    @AppStorage(AppSettings.replaceOriginalsKey) private var replaceOriginals = false
    @AppStorage(AppSettings.analyzePhotoKey) private var analyzePhoto = true
    @AppStorage(AppSettings.textureKey) private var texture = true
    @State private var access = PhotoLibraryService.status
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack(spacing: 14) {
                            Image("AboutIcon")
                                .resizable()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppSettings.displayName).font(.title3.bold())
                                Text(L("Version") + " " + AppSettings.appVersion)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Picker("When Styling a Photo", selection: $replaceOriginals) {
                        Text("Save as New").tag(false)
                        Text("Replace Original").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Mode")
                } footer: {
                    if replaceOriginals {
                        Text("The styled photo takes the original's place, with its date, location, favorite and albums. The original goes to the Backup Bin, so you can restore it.")
                    } else {
                        Text("The styled photo is saved next to the original as a new photo, named with \"_Floating_light\".")
                    }
                }

                Section {
                    Toggle("Analyze Each Photo", isOn: $analyzePhoto)
                    Toggle("Add Texture & Grain", isOn: $texture)
                } header: {
                    Text("Style")
                } footer: {
                    Text("分析会测量照片自身的色调，而不是参考照片的色调。质感与颗粒会加入 iOS 27 的控制项，照片有人脸数据时还会加入柔肤。")
                }

                Section("Photos & Backups") {
                    LabeledContent {
                        Text(accessTitle)
                    } label: {
                        Label("Photo Access", systemImage: "photo.on.rectangle")
                    }
                    if access == .limited {
                        Button {
                            LimitedLibrary.presentPicker()
                        } label: {
                            Label("Select More Photos…", systemImage: "photo.badge.plus")
                        }
                    } else if access != .authorized {
                        Button {
                            LimitedLibrary.openSettings()
                        } label: {
                            Label("Open Settings", systemImage: "gearshape")
                        }
                    }
                    Button {
                        LimitedLibrary.openSettings()
                    } label: {
                        Label("Select Range or All", systemImage: "photo.badge.plus")
                    }
                    LabeledContent {
                        Text(backupSummary)
                    } label: {
                        Label("Backup Bin", systemImage: "archivebox")
                    }
                }

                Section {
                    Label("The Add Photographic Style action always saves a new photo and never replaces one.", systemImage: "square.2.layers.3d")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let url = URL(string: "shortcuts://") {
                        Link(destination: url) {
                            Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                        }
                    }
                } header: {
                    Text("Shortcuts")
                }

                Section {
                    NavigationLink {
                        FeaturesView()
                    } label: {
                        Label("Features", systemImage: "sparkles")
                    }
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        Label("Privacy", systemImage: "lock.shield")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于浮光", systemImage: "info.circle")
                    }
                } header: {
                    Text("About")
                }
            }
            .readableWidth()
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Access can change in Settings while the app is in the background.
            if phase == .active { access = PhotoLibraryService.status }
        }
    }

    private var accessTitle: String {
        switch access {
        case .authorized: return L("All Photos")
        case .limited: return L("Selected Photos")
        case .notDetermined: return L("Not Determined")
        default: return L("No Access")
        }
    }

    private var backupSummary: String {
        guard !backups.entries.isEmpty else { return L("No originals") }
        let count = backups.entries.count == 1 ? L("1 original") : L("\(backups.entries.count) originals")
        let size = ByteCountFormatter.string(fromByteCount: backups.totalBytes, countStyle: .file)
        return count + ", " + size
    }
}

struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @State private var authorCopied = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image("AboutIcon")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityHidden(true)
                    Text(AppSettings.displayName)
                        .font(.title.bold())
                    Text("Photographic Styles for every iPhone photo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "Version 1.1.3")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("该app由Muse和Claud编译")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Text("Experimental, unofficial software, not affiliated with Apple. Keep your original photos.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("作者") {
                Button {
                    // Direct to the author's Douyin: try the Douyin app first,
                    // fall back to the Douyin web page. The ID is also copied
                    // so the user can search if the link lands on search.
                    UIPasteboard.general.string = "351453703"
                    if let appURL = URL(string: "snssdk1128://search?keyword=351453703"),
                       UIApplication.shared.canOpenURL(appURL) {
                        openURL(appURL)
                    } else if let webURL = URL(string: "https://www.douyin.com/search/351453703?type=user") {
                        openURL(webURL)
                    } else {
                        authorCopied = true
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image("AuthorAvatar")
                            .resizable()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Мороз").font(.headline)
                            Text("抖音：351453703")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .readableWidth()
        .navigationTitle("关于浮光")
        .alert("已复制抖音号", isPresented: $authorCopied) {
            Button("确定") { authorCopied = false }
        } message: {
            Text("抖音号 351453703 已复制，到抖音搜索即可找到作者。")
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeaturesView: View {
    var body: some View {
        List {
            Section {
                Feature(
                    symbol: "camera.filters",
                    title: "Photographic Styles palette",
                    text: "Adds the style palette introduced with iPhone 16 to HEIC photos from earlier iPhones, so you can change the style in Photos and change it back."
                )
                Feature(
                    symbol: "circle.grid.3x3",
                    title: "Texture & Grain",
                    text: "Adds the iOS 27 Texture and Grain controls, and Soft Skin for portraits with face data. Photos from iPhone 16 and 17 that already have a style get just these."
                )
                Feature(
                    symbol: "livephoto",
                    title: "Live Photos",
                    text: "Live Photos keep their motion when their video can be styled. Cropped videos are re-encoded to prevent blurred edges. If video processing fails, the job explains why a still was saved; the original keeps its motion."
                )
                Feature(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Save as new or replace",
                    text: "Keep both versions, or replace the original with its date, location, favorite and albums carried over."
                )
                Feature(
                    symbol: "archivebox",
                    title: "Backup Bin",
                    text: "Every replaced original is kept, with its video, until you restore or delete it."
                )
                Feature(
                    symbol: "square.2.layers.3d",
                    title: "Shortcuts",
                    text: "Add a style from any shortcut with the Add Photographic Style action."
                )
            }
        }
        .readableWidth()
        .navigationTitle("Features")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Feature(
                    symbol: "iphone",
                    title: "Everything stays on this device",
                    text: "Photos are processed on your iPhone or iPad and never uploaded. Floating light has no servers, no accounts, no analytics and no ads."
                )
                Feature(
                    symbol: "photo.on.rectangle",
                    title: "Only the photos you allow",
                    text: "With limited access Floating light sees only the photos you select. Photos stored in iCloud are downloaded by iOS when you style them."
                )
                Feature(
                    symbol: "lock.shield",
                    title: "Backups are yours",
                    text: "The Backup Bin lives in the app's own storage on this device and is deleted with the app."
                )
            }
        }
        .readableWidth()
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Feature: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
