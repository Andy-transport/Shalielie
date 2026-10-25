import CoreImage
import Photos
import SwiftUI
import UIKit

/// Texture presets for the Pickglow-style editor. Every preset is operable:
/// there is no locked / membership-only preset in this build.
enum PhotoTexture: String, CaseIterable, Identifiable {
    case standard
    case softSkin
    case halo
    case film
    case grain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "标准"
        case .softSkin: return "柔肤"
        case .halo: return "光晕"
        case .film: return "胶片"
        case .grain: return "颗粒"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: return "slash.circle"
        case .softSkin: return "person"
        case .halo: return "circle.dashed"
        case .film: return "film"
        case .grain: return "circle.grid.3x3"
        }
    }
}

/// Tone + texture adjustments, rendered live with Core Image.
///
/// This is a local preview adjustment, deliberately separate from the
/// Photographic Style port: saving here writes a new adjusted copy to Photos,
/// it does not change the style data that "Add Photographic Style" writes.
struct PhotoAdjustment: Equatable {
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var warmth: Double = 0
    var texture: PhotoTexture = .standard
    var textureIntensity: Double = 0

    var isDefault: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && warmth == 0
            && texture == .standard && textureIntensity == 0
    }

    func apply(to image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var output = CIImage(cgImage: cgImage)
        guard let controls = CIFilter(name: "CIColorControls") else { return nil }
        controls.setValue(output, forKey: kCIInputImageKey)
        controls.setValue(NSNumber(value: brightness), forKey: kCIInputBrightnessKey)
        controls.setValue(NSNumber(value: contrast), forKey: kCIInputContrastKey)
        controls.setValue(NSNumber(value: saturation), forKey: kCIInputSaturationKey)
        guard let controlled = controls.outputImage else { return nil }
        output = controlled
        if warmth != 0, let temperature = CIFilter(name: "CITemperatureAndTint") {
            temperature.setValue(output, forKey: kCIInputImageKey)
            temperature.setValue(
                CIVector(x: CGFloat(6500 + warmth * 2500), y: 0),
                forKey: "inputNeutral"
            )
            temperature.setValue(CIVector(x: 0, y: 0), forKey: "inputTargetNeutral")
            if let warmed = temperature.outputImage { output = warmed }
        }
        if texture != .standard, textureIntensity > 0 {
            output = applyTexture(output, intensity: textureIntensity)
        }
        let context = CIContext(options: nil)
        guard let rendered = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }

    private func applyTexture(_ input: CIImage, intensity: Double) -> CIImage {
        var output = input
        switch texture {
        case .standard:
            break
        case .softSkin:
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(output, forKey: kCIInputImageKey)
                blur.setValue(NSNumber(value: intensity * 3), forKey: kCIInputRadiusKey)
                if let blurred = blur.outputImage { output = blurred.cropped(to: input.extent) }
            }
        case .halo:
            if let bloom = CIFilter(name: "CIBloom") {
                bloom.setValue(output, forKey: kCIInputImageKey)
                bloom.setValue(NSNumber(value: intensity * 20), forKey: kCIInputRadiusKey)
                bloom.setValue(NSNumber(value: intensity * 0.9), forKey: kCIInputIntensityKey)
                if let bloomed = bloom.outputImage { output = bloomed.cropped(to: input.extent) }
            }
        case .film:
            if let transfer = CIFilter(name: "CIPhotoEffectTransfer") {
                transfer.setValue(output, forKey: kCIInputImageKey)
                if let transferred = transfer.outputImage { output = transferred }
            }
            if let vignette = CIFilter(name: "CIVignette") {
                vignette.setValue(output, forKey: kCIInputImageKey)
                vignette.setValue(NSNumber(value: intensity * 1.5), forKey: kCIInputIntensityKey)
                vignette.setValue(NSNumber(value: 1.5), forKey: kCIInputRadiusKey)
                if let vignetted = vignette.outputImage { output = vignetted }
            }
        case .grain:
            if let random = CIFilter(name: "CIRandomGenerator"),
               let noise = random.outputImage?.cropped(to: input.extent),
               let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(noise, forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), forKey: "inputBVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity * 0.4)), forKey: "inputAVector")
                if let grained = matrix.outputImage,
                   let composite = CIFilter(name: "CISourceOverCompositing") {
                    composite.setValue(grained, forKey: kCIInputImageKey)
                    composite.setValue(output, forKey: kCIInputBackgroundImageKey)
                    if let composited = composite.outputImage { output = composited }
                }
            }
        }
        return output
    }
}

private enum EditorTab: String, CaseIterable {
    case texture
    case tone

    var title: String {
        switch self {
        case .texture: return "质感"
        case .tone: return "调色"
        }
    }

    var systemImage: String {
        switch self {
        case .texture: return "sparkles"
        case .tone: return "slider.horizontal.3"
        }
    }
}

/// Pickglow-style dark editor: photo on top, 质感 / 调色 panel below.
/// Every control works: texture chips, intensity, tone sliders, compare,
/// press-and-hold original, reset, share, info, and 完成 (save a new copy).
struct AdjustPreviewView: View {
    let asset: PHAsset

    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var adjusted: UIImage?
    @State private var adjustment = PhotoAdjustment()
    @State private var tab = EditorTab.texture
    @State private var compareOn = false
    @State private var showingOriginal = false
    @State private var divider: CGFloat = 0.5
    @State private var saving = false
    @State private var message: String?
    @State private var showingShare = false
    @State private var showingInfo = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            photoArea
            compareBar
            bottomPanel
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .alert(
            "调整",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("确定") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert(
            "当前调整",
            isPresented: $showingInfo
        ) {
            Button("确定") {}
        } message: {
            Text(infoText)
        }
        .sheet(isPresented: $showingShare) {
            if let adjusted { AdjustedShareSheet(image: adjusted) }
        }
        .task {
            original = await loadOriginal()
            if let original {
                adjusted = adjustment.apply(to: original)
            }
        }
        .task(id: adjustment) {
            guard let original else { return }
            adjusted = adjustment.apply(to: original)
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.15), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text(tab == .texture ? "质感" : "调色")
                    .font(.headline)
                Text(tab == .texture
                     ? (adjustment.texture == .standard ? "未添加质感" : adjustment.texture.title)
                     : "亮度 · 对比度 · 饱和度 · 暖色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                Button { if adjusted != nil { showingShare = true } } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(0.15), in: Circle())
                }
                .disabled(adjusted == nil)
                Button { showingInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.headline)
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(0.15), in: Circle())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var photoArea: some View {
        Group {
            if let original, let adjusted {
                if compareOn {
                    comparePreview(original: original, adjusted: adjusted)
                } else if showingOriginal {
                    Image(uiImage: original).resizable().scaledToFit()
                } else {
                    Image(uiImage: adjusted).resizable().scaledToFit()
                }
            } else if let original {
                Image(uiImage: original).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var compareBar: some View {
        HStack(spacing: 12) {
            Button { compareOn.toggle() } label: {
                Label("对比", systemImage: "rectangle.split.2x1")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(compareOn ? Color.white : Color.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(compareOn ? .black : .white)
            }
            .buttonStyle(.plain)
            Text("按住看原图")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(showingOriginal ? Color.white : Color.white.opacity(0.15), in: Capsule())
                .foregroundStyle(showingOriginal ? .black : .white)
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in showingOriginal = true }
                        .onEnded { _ in showingOriginal = false }
                )
        }
        .padding(.vertical, 14)
    }

    private var bottomPanel: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 44, height: 4).padding(.top, 10)
            Picker("编辑", selection: $tab) {
                ForEach(EditorTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if tab == .texture {
                textureControls
            } else {
                toneControls
            }

            HStack(spacing: 12) {
                Button { adjustment = PhotoAdjustment() } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(adjustment.isDefault)
                Button {
                    Task {
                        if await saveAdjustedCopy() { dismiss() }
                    }
                } label: {
                    HStack {
                        if saving { ProgressView().tint(.black) }
                        else { Image(systemName: "checkmark") }
                        Text("完成")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(adjusted == nil || saving)
            }
            .padding(.horizontal, 16)
            Text("质感与调色全部可直接使用。完成后存为新照片，不改摄影风格数据。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 8)
    }

    private var textureControls: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(PhotoTexture.allCases) { texture in
                        let selected = adjustment.texture == texture
                        Button {
                            adjustment.texture = texture
                            if adjustment.textureIntensity == 0 { adjustment.textureIntensity = 0.5 }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: texture.systemImage)
                                    .font(.title3)
                                    .frame(width: 68, height: 68)
                                    .background(selected ? Color.white : Color.white.opacity(0.15), in: Circle())
                                    .foregroundStyle(selected ? .black : .white)
                                Text(texture.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Text(adjustment.texture.title).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                Spacer()
                Text("\(Int(adjustment.textureIntensity * 100))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            Slider(
                value: Binding(
                    get: { adjustment.textureIntensity },
                    set: { adjustment.textureIntensity = $0 }
                ),
                in: 0...1
            )
            .padding(.horizontal, 16)
            .tint(.white)
        }
    }

    private var toneControls: some View {
        VStack(spacing: 14) {
            editorSlider(title: "亮度", value: Binding(get: { adjustment.brightness }, set: { adjustment.brightness = $0 }), range: -1...1)
            editorSlider(title: "对比度", value: Binding(get: { adjustment.contrast }, set: { adjustment.contrast = $0 }), range: 0...2)
            editorSlider(title: "饱和度", value: Binding(get: { adjustment.saturation }, set: { adjustment.saturation = $0 }), range: 0...2)
            editorSlider(title: "暖色", value: Binding(get: { adjustment.warmth }, set: { adjustment.warmth = $0 }), range: -1...1)
        }
        .padding(.horizontal, 16)
    }

    private func editorSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range).tint(.white)
        }
    }

    private var infoText: String {
        "质感：\(adjustment.texture.title) \(Int(adjustment.textureIntensity * 100))\n亮度 \(adjustment.brightness.formatted(.number.precision(.fractionLength(2)))) · 对比度 \(adjustment.contrast.formatted(.number.precision(.fractionLength(2)))) · 饱和度 \(adjustment.saturation.formatted(.number.precision(.fractionLength(2)))) · 暖色 \(adjustment.warmth.formatted(.number.precision(.fractionLength(2))))"
    }

    private func comparePreview(original: UIImage, adjusted: UIImage) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Image(uiImage: original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                Image(uiImage: adjusted)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(Rectangle().offset(x: geometry.size.width * divider))
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: geometry.size.height)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: geometry.size.width * divider)
                VStack {
                    Text("原图")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white).padding(8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack {
                    Text("调整后")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white).padding(8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        divider = min(0.95, max(0.05, value.location.x / max(geometry.size.width, 1)))
                    }
            )
        }
    }

    private func loadOriginal() async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let size = CGSize(width: 1200, height: 1200)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Saves the adjusted image as a new photo. Returns true on success.
    private func saveAdjustedCopy() async -> Bool {
        guard let adjusted else { return false }
        saving = true
        defer { saving = false }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: adjusted)
                }, completionHandler: { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "AdjustPreview",
                            code: 0,
                            userInfo: [NSLocalizedDescriptionKey: "The adjusted copy could not be saved."]
                        ))
                    }
                })
            }
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}

private struct AdjustedShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
