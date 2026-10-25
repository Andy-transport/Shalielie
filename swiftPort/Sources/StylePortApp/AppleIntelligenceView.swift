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
            }

            Section {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(loadingPhoto ? "正在读取照片…" : "选择照片消除", systemImage: "eraser.fill")
                }
                .disabled(loadingPhoto)
                Text("选一张照片，手指涂抹不要的东西：普通消除用本机扩散填充，AI 消除用 LaMa 模型生成填充（首次使用时下载模型，照片不出手机）。完成后存为新照片，不改原图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("照片消除")
            } footer: {
                Text("也可以在照片详情页的调整编辑器里点橡皮图标打开同一个消除页。")
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
    }
}
