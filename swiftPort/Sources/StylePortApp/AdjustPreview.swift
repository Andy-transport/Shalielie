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
        case .softSkin: return "person.fill"
        case .halo: return "circle.dotted"
        case .film: return "film"
        case .grain: return "circle.grid.3x3"
        }
    }
}

/// LUT styles from the user's .cube files: Ricoh (upload.cube) and
/// Leica Eternal (Leica_Eternal.cube). Both are 33-size 3D LUTs, applied
/// with CIColorCube; NSDataAsset loads them from the asset catalog.
enum PhotoLUT: String, CaseIterable, Identifiable {
    case none
    case ricoh
    case leica

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "原图"
        case .ricoh: return "理光"
        case .leica: return "Leica"
        }
    }

    var assetName: String? {
        switch self {
        case .none: return nil
        case .ricoh: return "RicohLUT"
        case .leica: return "LeicaLUT"
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
    var lut: PhotoLUT = .none
    var lutIntensity: Double = 1
    var paletteIntensity: Double = 1

    var isDefault: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && warmth == 0
            && texture == .standard && textureIntensity == 0 && lut == .none && paletteIntensity == 1
    }

    func apply(to image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var output = CIImage(cgImage: cgImage)
        guard let controls = CIFilter(name: "CIColorControls") else { return nil }
        controls.setValue(output, forKey: kCIInputImageKey)
        controls.setValue(NSNumber(value: brightness), forKey: kCIInputBrightnessKey)
        controls.setValue(NSNumber(value: contrast), forKey: kCIInputContrastKey)
        controls.setValue(NSNumber(value: 1 + (saturation - 1) * paletteIntensity), forKey: kCIInputSaturationKey)
        guard let controlled = controls.outputImage else { return nil }
        output = controlled
        if warmth * paletteIntensity != 0, let temperature = CIFilter(name: "CITemperatureAndTint") {
            temperature.setValue(output, forKey: kCIInputImageKey)
            temperature.setValue(
                CIVector(x: CGFloat(6500 + warmth * paletteIntensity * 2500), y: 0),
                forKey: "inputNeutral"
            )
            temperature.setValue(CIVector(x: 0, y: 0), forKey: "inputTargetNeutral")
            if let warmed = temperature.outputImage { output = warmed }
        }
        if lut != .none, lutIntensity > 0 {
            output = applyLUT(output, lut: lut, intensity: lutIntensity)
        }
        if texture != .standard, textureIntensity > 0 {
            output = applyTexture(output, intensity: textureIntensity)
        }
        let context = CIContext(options: nil)
        guard let rendered = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }

    private func applyLUT(_ input: CIImage, lut: PhotoLUT, intensity: Double) -> CIImage {
        guard let assetName = lut.assetName,
              let asset = NSDataAsset(name: assetName),
              let cube = CubeLUT.parse(asset.data),
              let filter = CIFilter(name: "CIColorCube") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(cube.size, forKey: "inputCubeDimension")
        filter.setValue(cube.data, forKey: "inputCubeData")
        guard let lutOutput = filter.outputImage else { return input }
        if intensity >= 1 { return lutOutput }
        // Blend LUT output over the original by its alpha, for intensity < 1.
        guard let matrix = CIFilter(name: "CIColorMatrix"),
              let composite = CIFilter(name: "CISourceOverCompositing") else { return lutOutput }
        matrix.setValue(lutOutput, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity)), forKey: "inputAVector")
        guard let faded = matrix.outputImage else { return lutOutput }
        composite.setValue(faded, forKey: kCIInputImageKey)
        composite.setValue(input, forKey: kCIInputBackgroundImageKey)
        return composite.outputImage ?? lutOutput
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

/// Minimal .cube parser: LUT_3D_SIZE + size^3 RGB triples, red fastest.
/// Returns CIColorCube data (RGBA floats, alpha 1) in the same order.
enum CubeLUT {
    static func parse(_ data: Data) -> (size: Int, data: Data)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var size = 0
        var triples: [(Float, Float, Float)] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last ?? "") ?? 0
                continue
            }
            if line.hasPrefix("LUT") || line.hasPrefix("DOMAIN") { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else { continue }
            triples.append((r, g, b))
        }
        guard size > 0, triples.count == size * size * size else { return nil }
        var floats: [Float] = []
        floats.reserveCapacity(triples.count * 4)
        for (r, g, b) in triples { floats.append(contentsOf: [r, g, b, 1]) }
        return (size, floats.withUnsafeBytes { Data($0) })
    }
}

/// Apple photographic-style palettes from the user's screenshots:
/// the six squares shown in Photos (Standard plus the five undertone
/// palettes). Apple's own internal style data is private, so these are
/// look-alike presets: each one sets brightness / contrast / saturation /
/// warmth to match that palette's feel, and gives the draggable palette
/// square that palette's gradient. The user can still drag the dot to
/// fine-tune afterwards.
enum AppleStyle: String, CaseIterable, Identifiable {
    case standard
    case amber
    case roseGold
    case gold
    case neutral
    case cool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "标准"
        case .amber: return "琥珀色"
        case .roseGold: return "玫瑰金"
        case .gold: return "金色"
        case .neutral: return "中性"
        case .cool: return "冷调"
        }
    }

    var gradientTop: Color {
        switch self {
        case .standard: return Color(red: 0.75, green: 0.82, blue: 0.88)
        case .amber: return Color(red: 0.95, green: 0.65, blue: 0.45)
        case .roseGold: return Color(red: 0.90, green: 0.65, blue: 0.60)
        case .gold: return Color(red: 0.98, green: 0.75, blue: 0.20)
        case .neutral: return Color(red: 0.85, green: 0.82, blue: 0.88)
        case .cool: return Color(red: 0.65, green: 0.82, blue: 0.95)
        }
    }

    var gradientBottom: Color {
        switch self {
        case .standard: return Color(red: 0.15, green: 0.22, blue: 0.28)
        case .amber: return Color(red: 0.35, green: 0.20, blue: 0.12)
        case .roseGold: return Color(red: 0.35, green: 0.28, blue: 0.25)
        case .gold: return Color(red: 0.35, green: 0.25, blue: 0.10)
        case .neutral: return Color(red: 0.25, green: 0.25, blue: 0.30)
        case .cool: return Color(red: 0.15, green: 0.20, blue: 0.30)
        }
    }

    /// Preset tone values (brightness, contrast, saturation, warmth).
    var preset: (Double, Double, Double, Double) {
        switch self {
        case .standard: return (0, 1, 1, 0)
        case .amber: return (0.05, 1.05, 1.15, 0.45)
        case .roseGold: return (0.05, 1.0, 1.10, 0.35)
        case .gold: return (0.08, 1.05, 1.20, 0.60)
        case .neutral: return (0, 0.95, 0.90, 0)
        case .cool: return (0, 1.0, 1.05, -0.50)
        }
    }
}

/// A palette square like Apple's: gradient + dot grid + one white dot.
/// The dot position comes from the style's preset, so each style's icon
/// looks different, just like the Photos palette squares. No slider
/// underneath: the Chinese title below the icon is the only label.
struct AppleStylePaletteIcon: View {
    let style: AppleStyle
    let size: CGFloat

    var body: some View {
        let values = style.preset
        let dotX = CGFloat(values.3 / 2 + 0.5) * size
        let dotY = CGFloat(0.5 - (values.2 - 1) / 2) * size
        ZStack {
            LinearGradient(colors: [style.gradientTop, style.gradientBottom], startPoint: .top, endPoint: .bottom)
            ForEach(0..<9, id: \.self) { row in
                ForEach(0..<9, id: \.self) { col in
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: max(size / 18, 3), height: max(size / 18, 3))
                        .position(x: size * CGFloat(col + 1) / 10, y: size * CGFloat(row + 1) / 10)
                }
            }
            Circle()
                .fill(Color.white)
                .frame(width: size * 0.22, height: size * 0.22)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .position(x: dotX, y: dotY)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private enum EditorTab: String, CaseIterable {
    case texture
    case tone
    case lut
    case palette

    var title: String {
        switch self {
        case .texture: return "质感"
        case .tone: return "调色"
        case .lut: return "LUT"
        case .palette: return "调色盘"
        }
    }

    var systemImage: String {
        switch self {
        case .texture: return "sparkles"
        case .tone: return "slider.horizontal.3"
        case .lut: return "square.stack.3d"
        case .palette: return "circle.grid.3x3"
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
    @AppStorage(AppSettings.photographicStyleEnabledKey) private var photographicStyleEnabled = true
    @AppStorage(AppSettings.appleStyleKey) private var appleStyleRaw = "standard"

    private var appleStyle: AppleStyle { AppleStyle(rawValue: appleStyleRaw) ?? .standard }
    @State private var tab = EditorTab.texture
    @State private var compareOn = false
    @State private var showingOriginal = false
    @State private var divider: CGFloat = 0.5
    @State private var saving = false
    @State private var message: String?
    @State private var showingShare = false
    @State private var showingInfo = false
    @State private var showingErase = false

    var body: some View {
        ZStack {
            // Fill the whole sheet, including the top safe area, with black.
            // Previously only the VStack had a black background, so the
            // sheet's light background showed as a white band above the
            // top bar and clipped its buttons.
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                photoArea
                compareBar
                bottomPanel
            }
        }
        .presentationBackground(Color.black)
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
        .fullScreenCover(isPresented: $showingErase) {
            EraseView(asset: asset)
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
                Text(tab.title)
                    .font(.headline)
                Text(tab == .texture
                     ? (adjustment.texture == .standard ? "未添加质感" : adjustment.texture.title)
                     : tab == .lut
                     ? (adjustment.lut == .none ? "未使用 LUT" : adjustment.lut.title)
                     : tab == .palette
                     ? "\(appleStyle.title) · 冷暖 · 浓淡，拖动白点实时调"
                     : "亮度 · 对比度 · 饱和度 · 暖色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                Button { showingErase = true } label: {
                    Image(systemName: "eraser.fill")
                        .font(.headline)
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(0.15), in: Circle())
                }
                .accessibilityLabel("消除不要的东西")
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
            } else if tab == .lut {
                lutControls
            } else if tab == .palette {
                paletteControls
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
            Text("质感、调色、LUT（理光、Leica）与调色盘全部可直接使用。完成后存为新照片，不改摄影风格数据。")
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

    /// Texture chip icons matching the Photos reference: filled person,
    /// dotted circle for halo, film strip, and a 5x5 dot grid for grain
    /// (instead of the 3x3 system grid).
    private func textureChipIcon(for texture: PhotoTexture) -> some View {
        Group {
            if texture == .grain {
                VStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { _ in
                        HStack(spacing: 4) {
                            ForEach(0..<5, id: \.self) { _ in
                                Circle().frame(width: 3, height: 3)
                            }
                        }
                    }
                }
            } else {
                Image(systemName: texture.systemImage)
                    .font(.title3)
            }
        }
    }

    private var textureControls: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(PhotoTexture.allCases.enumerated()), id: \.element) { _, texture in
                        Group {
                            if texture == .grain {
                                Rectangle()
                                    .fill(Color.white.opacity(0.3))
                                    .frame(width: 1, height: 44)
                            }
                            Button {
                                adjustment.texture = texture
                                if adjustment.textureIntensity == 0 { adjustment.textureIntensity = 0.5 }
                            } label: {
                                VStack(spacing: 8) {
                                    textureChipIcon(for: texture)
                                        .frame(width: 68, height: 68)
                                        .background(adjustment.texture == texture ? Color.white : Color.white.opacity(0.15), in: Circle())
                                        .foregroundStyle(adjustment.texture == texture ? .black : .white)
                                    Text(texture.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                }
                            }
                            .buttonStyle(.plain)
                        }
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

    /// Brand marks for the LUT chips, drawn in code (no image assets):
    /// Ricoh as its RICOH wordmark, Leica as its red dot + Leica wordmark.
    private func lutChipIcon(for lut: PhotoLUT, selected: Bool) -> some View {
        Group {
            if lut == .ricoh {
                Text("RICOH")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1)
            } else if lut == .leica {
                VStack(spacing: 2) {
                    Circle().fill(Color(red: 0.89, green: 0.02, blue: 0.08))
                        .frame(width: 16, height: 16)
                    Text("Leica")
                        .font(.system(size: 11, weight: .bold, design: .serif))
                }
            } else {
                Image(systemName: "slash.circle")
                    .font(.title3)
            }
        }
        .frame(width: 68, height: 68)
        .background(selected ? Color.white : Color.white.opacity(0.15), in: Circle())
        .foregroundStyle(selected ? .black : .white)
    }

    private var lutControls: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(PhotoLUT.allCases) { lut in
                        let selected = adjustment.lut == lut
                        Button {
                            adjustment.lut = lut
                            if adjustment.lutIntensity == 0 { adjustment.lutIntensity = 1 }
                        } label: {
                            VStack(spacing: 8) {
                                lutChipIcon(for: lut, selected: selected)
                                Text(lut.title)
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
                Text(adjustment.lut.title).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                Spacer()
                Text("\(Int(adjustment.lutIntensity * 100))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            Slider(
                value: Binding(
                    get: { adjustment.lutIntensity },
                    set: { adjustment.lutIntensity = $0 }
                ),
                in: 0...1
            )
            .padding(.horizontal, 16)
            .tint(.white)
        }
    }

    /// Truly adjustable palette, like the iPhone style palette: a dot grid
    /// with a draggable white dot. Horizontal = warmth (left cool, right
    /// warm), vertical = saturation (top vivid, bottom muted). Dragging
    /// writes straight into the same warmth/saturation the tone sliders
    /// show, so the preview updates live and saving keeps the result.
    private var paletteControls: some View {
        VStack(spacing: 12) {
            if photographicStyleEnabled {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(AppleStyle.allCases) { style in
                            Button {
                                appleStyleRaw = style.rawValue
                                let values = style.preset
                                adjustment.paletteIntensity = 1
                                adjustment.brightness = values.0
                                adjustment.contrast = values.1
                                adjustment.saturation = values.2
                                adjustment.warmth = values.3
                            } label: {
                                VStack(spacing: 8) {
                                    Text(style.title)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.25), in: Capsule())
                                    AppleStylePaletteIcon(style: style, size: 56)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(style.rawValue == appleStyleRaw ? Color.white : Color.clear, lineWidth: 2)
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            GeometryReader { geometry in
                let size = geometry.size
                let pointX = CGFloat(adjustment.warmth / 2 + 0.5) * size.width
                let pointY = CGFloat(0.5 - (adjustment.saturation - 1) / 2) * size.height
                ZStack {
                    LinearGradient(
                        colors: photographicStyleEnabled
                            ? [appleStyle.gradientTop, appleStyle.gradientBottom]
                            : [Color(red: 0.55, green: 0.78, blue: 1.0), Color(red: 0.04, green: 0.1, blue: 0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    ForEach(0..<9, id: \.self) { row in
                        ForEach(0..<9, id: \.self) { col in
                            Circle()
                                .fill(Color.white.opacity(0.35))
                                .frame(width: 5, height: 5)
                                .position(
                                    x: size.width * CGFloat(col + 1) / 10,
                                    y: size.height * CGFloat(row + 1) / 10
                                )
                        }
                    }
                    Circle()
                        .fill(Color.white)
                        .frame(width: 36, height: 36)
                        .shadow(color: .black.opacity(0.4), radius: 6)
                        .position(x: pointX, y: pointY)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = min(max(value.location.x / size.width, 0), 1)
                            let y = min(max(value.location.y / size.height, 0), 1)
                            adjustment.warmth = Double(x - 0.5) * 2
                            adjustment.saturation = 1 + Double(0.5 - y) * 2
                        }
                )
            }
            .frame(height: 280)
            .padding(.horizontal, 16)
            HStack {
                Text("冷").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("暖").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            HStack {
                Text("冷暖 \(adjustment.warmth.formatted(.number.precision(.fractionLength(2))))")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                Spacer()
                Text("浓淡 \(adjustment.saturation.formatted(.number.precision(.fractionLength(2))))")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            HStack {
                Text("强度").font(.subheadline.weight(.medium)).foregroundStyle(.white)
                Spacer()
                Text("\(Int(adjustment.paletteIntensity * 100))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            Slider(
                value: Binding(
                    get: { adjustment.paletteIntensity },
                    set: { adjustment.paletteIntensity = $0 }
                ),
                in: 0...1
            )
            .padding(.horizontal, 16)
            .tint(.white)
            Text("上下拖改浓淡，左右拖改冷暖；调色页签里的暖色和饱和度会同步变化。拉杆拉到 0 是原图效果，拉到 100 是完整风格。")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
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
