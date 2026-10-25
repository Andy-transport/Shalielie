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
    /// Centre crop aspect ratio (width / height), nil = original.
    var cropAspect: Double? = nil
    /// Extend: fraction of width/height added on each side (0 = none).
    var extendRatio: Double = 0
    /// Reframe: crop scale (1 = none) + shift (-1...1) in each direction.
    var reframeScale: Double = 1
    var reframeDX: Double = 0
    var reframeDY: Double = 0

    var isDefault: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && warmth == 0
            && texture == .standard && textureIntensity == 0 && lut == .none && paletteIntensity == 1
            && cropAspect == nil && extendRatio == 0 && reframeScale == 1
            && reframeDX == 0 && reframeDY == 0
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
        guard var rendered = context.createCGImage(output, from: output.extent) else { return nil }
        if let ratio = cropAspect {
            let w = rendered.width, h = rendered.height
            let current = Double(w) / Double(h)
            var cropRect: CGRect
            if ratio > current {
                let ch = Double(w) / ratio
                cropRect = CGRect(x: 0, y: Int((Double(h) - ch) / 2), width: w, height: Int(ch))
            } else {
                let cw = Double(h) * ratio
                cropRect = CGRect(x: Int((Double(w) - cw) / 2), y: 0, width: Int(cw), height: h)
            }
            if let cropped = rendered.cropping(to: cropRect) { rendered = cropped }
        }
        // Reframe: crop to a smaller frame, shifted in the chosen direction.
        if reframeScale < 1 {
            let w = rendered.width, h = rendered.height
            let cw = Int(Double(w) * reframeScale), ch = Int(Double(h) * reframeScale)
            let maxX = w - cw, maxY = h - ch
            let x = Int(Double(maxX) / 2 * (1 + reframeDX))
            let y = Int(Double(maxY) / 2 * (1 + reframeDY))
            if let cropped = rendered.cropping(to: CGRect(x: max(0, x), y: max(0, y), width: cw, height: ch)) {
                rendered = cropped
            }
        }
        // Extend: larger canvas, border filled with a blurred, enlarged
        // copy of the photo as background, original sharp in the centre.
        // This is a blurred-background fill, not AI generative outpainting.
        if extendRatio > 0 {
            let w = rendered.width, h = rendered.height
            let nw = Int(Double(w) * (1 + 2 * extendRatio)), nh = Int(Double(h) * (1 + 2 * extendRatio))
            let ox = (nw - w) / 2, oy = (nh - h) / 2
            var bg = CIImage(cgImage: rendered)
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(bg, forKey: kCIInputImageKey)
                blur.setValue(NSNumber(value: 30), forKey: kCIInputRadiusKey)
                if let blurred = blur.outputImage { bg = blurred.cropped(to: bg.extent) }
            }
            if let bgRendered = context.createCGImage(bg, from: bg.extent) {
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                if let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: nw * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.interpolationQuality = .high
                    ctx.draw(bgRendered, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                    ctx.draw(rendered, in: CGRect(x: ox, y: oy, width: w, height: h))
                    if let extended = ctx.makeImage() { rendered = extended }
                }
            }
        }
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


private enum EditorTab: String, CaseIterable {
    case styles
    case tone
    case tools

    var title: String {
        switch self {
        case .styles: return "质感"
        case .tone: return "影调"
        case .tools: return "工具"
        }
    }

    var systemImage: String {
        switch self {
        case .styles: return "circle.grid.3x3"
        case .tone: return ""
        case .tools: return "wand.and.stars"
        }
    }
}

/// 影调自拟图标：不是系统图标，是代码画的明暗渐变圆，
/// 左上亮、右下暗，代表影调（亮度 / 对比的明暗范围）。
private struct ToneIcon: View {
    var body: some View {
        Image("ToneIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
    }
}

private enum ToolsTool {
    case lut
    case extend
    case reframe
}


/// Photos-style light editor: white background, Cancel/Done pills
/// on top, photo in the middle, style name and a bottom pill for
/// 质感 / 调色 / LUT, like the iPhone Photos STYLES editor.
/// Every control works: texture chips, intensity, tone sliders, compare,
/// press-and-hold original, reset, share, info, and 完成 (save a new copy).
struct AdjustPreviewView: View {
    let asset: PHAsset

    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var adjusted: UIImage?
    @State private var adjustment = PhotoAdjustment()
    @AppStorage("appleIntelligenceEnabled") private var appleIntelligenceEnabled = true

    @State private var tab = EditorTab.styles
    @State private var toolsTool = ToolsTool.lut
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
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                photoArea
                compareBar
                bottomPanel
            }
        }
        .presentationBackground(Color(uiColor: .systemBackground))
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
        VStack(spacing: 12) {
            HStack {
                Button("取消") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .foregroundStyle(.primary)
                    .floatingGlass()
                    .buttonStyle(.plain)
                Spacer()
                Button {
                    Task {
                        if await saveAdjustedCopy() { dismiss() }
                    }
                } label: {
                    HStack {
                        if saving { ProgressView().tint(.primary) }
                        Text("完成")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .foregroundStyle(adjusted == nil || saving ? Color.secondary : Color.primary)
                    .floatingGlass()
                }
                .buttonStyle(.plain)
                .disabled(adjusted == nil || saving)
            }
            HStack {
                Spacer()
                Text(tab.title)
                    .font(.title3.weight(.medium))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 16) {
                    Button { showingErase = true } label: {
                        Image("EraseIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                    .accessibilityLabel("消除不要的东西")
                    .disabled(!appleIntelligenceEnabled)
                    .opacity(appleIntelligenceEnabled ? 1 : 0.5)
                    Button { if adjusted != nil { showingShare = true } } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(adjusted == nil)
                    Button { showingInfo = true } label: {
                        Image(systemName: "info.circle")
                    }
                }
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .floatingGlass()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
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
                ProgressView().tint(.primary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }

    private var compareBar: some View {
        HStack(spacing: 12) {
            Button { compareOn.toggle() } label: {
                Label("对比", systemImage: "rectangle.split.2x1")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(compareOn ? Color.primary : Color.primary.opacity(0.08), in: Capsule())
                    .foregroundStyle(compareOn ? Color(uiColor: .systemBackground) : .primary)
            }
            .buttonStyle(.plain)
            Text("按住看原图")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(showingOriginal ? Color.primary : Color.primary.opacity(0.08), in: Capsule())
                .foregroundStyle(showingOriginal ? Color(uiColor: .systemBackground) : .primary)
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
            // Current style name, centred like Photos ("STANDARD").
            Text(bottomStyleName)
                .font(.title3.weight(.medium))
                .tracking(2)
                .foregroundStyle(.primary)
                .padding(.top, 8)

            if tab == .styles {
                stylesControls
            } else if tab == .tone {
                toneControls
            } else if tab == .tools {
                toolsControls
            }

            // Photos-style bottom pill: icon + label per tab, selected
            // tab gets a small yellow triangle marker above its icon.
            HStack(spacing: 0) {
                ForEach(EditorTab.allCases, id: \.self) { item in
                    let selected = item == tab
                    Button { tab = item } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .top) {
                                if item == .tone {
                                    ToneIcon()
                                } else if item == .tools {
                                    // Tools icon: user's woven-loops image, in the
                                    // same monochrome template style as the others.
                                    Image("ToolsIcon")
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: item.systemImage)
                                        .font(.title3)
                                        .frame(height: 28)
                                }
                                if selected {
                                    Triangle()
                                        .fill(Color.yellow)
                                        .frame(width: 10, height: 8)
                                        .offset(y: -8)
                                }
                            }
                            Text(item.title)
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Photos-style dark pill: dark glass with white / grey icons
            // and a yellow triangle on the selected tab, regardless of
            // the system appearance. Size is unchanged: same padding,
            // icon size, font size and full-width layout as before.
            .environment(\.colorScheme, .dark)
            .floatingGlass()
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 16)

            HStack {
                Button { adjustment = PhotoAdjustment() } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(adjustment.isDefault)
                Spacer()
                Text("质感、调色、LUT 全部可直接使用。完成后存为新照片。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var bottomStyleName: String {
        switch tab {
        case .styles: return "质感"
        case .tone: return "影调"
        case .tools: return "工具"
        }
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
                                    .fill(Color.primary.opacity(0.2))
                                    .frame(width: 1, height: 44)
                            }
                            Button {
                                adjustment.texture = texture
                                if adjustment.textureIntensity == 0 { adjustment.textureIntensity = 0.5 }
                            } label: {
                                VStack(spacing: 8) {
                                    textureChipIcon(for: texture)
                                        .frame(width: 68, height: 68)
                                        .background(adjustment.texture == texture ? Color.white : Color.primary.opacity(0.08), in: Circle())
                                        .foregroundStyle(adjustment.texture == texture ? .black : .primary)
                                        .shadow(color: adjustment.texture == texture ? .black.opacity(0.15) : .clear, radius: 8, y: 2)
                                    Text(texture.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    // Mini intensity bar under the selected chip only:
                                    // 10 ticks mirroring the main tick bar's intensity.
                                    // Filled ticks are yellow, the tick at the current
                                    // value is 30% taller and yellow, the rest are grey.
                                    // Unselected chips reserve the same height so the
                                    // row does not jump when the selection changes.
                                    if adjustment.texture == texture {
                                        textureMiniBar(intensity: adjustment.textureIntensity)
                                    } else {
                                        Color.clear.frame(width: 57, height: 13)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Text(adjustment.texture.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer()
                Text("\(Int(adjustment.textureIntensity * 100))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            textureTickSlider
                .padding(.horizontal, 16)
        }
    }

    /// Compact intensity bar shown under the selected texture chip:
    /// 10 ticks, filled ticks yellow, the tick at the current value
    /// 30% taller and yellow, the rest grey. It mirrors the main
    /// tick bar's intensity and is not itself a control.
    private func textureMiniBar(intensity: Double) -> some View {
        let filled = Int((intensity * 10).rounded())
        let current = min(9, max(0, filled))
        return HStack(spacing: 3) {
            ForEach(0..<10, id: \.self) { i in
                let isCurrent = i == current
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isCurrent || i < filled ? Color.yellow : Color.primary.opacity(0.25))
                    .frame(width: 3, height: isCurrent ? 13 : 10)
            }
        }
        .frame(height: 13)
    }

    /// Texture intensity as a tick bar, no slider: 125 ticks in total.
    /// Colours are grey-yellow: the tick at the current value is
    /// 30% taller than the rest and yellow, the rest are short and
    /// grey. Dragging across the bar snaps the intensity to the
    /// nearest step.
    private var textureTickSlider: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 1
            let tickWidth = max(1, (geometry.size.width - spacing * 124) / 125)
            let current = Int((adjustment.textureIntensity * 124).rounded())
            HStack(spacing: spacing) {
                ForEach(0..<125, id: \.self) { i in
                    let isCurrent = i == current
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(isCurrent ? Color.yellow : Color.primary.opacity(0.25))
                        .frame(width: tickWidth, height: isCurrent ? 21 : 16)
                }
            }
            .frame(height: 21)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(value.location.x / geometry.size.width, 0), 1)
                        adjustment.textureIntensity = (x * 124).rounded() / 124
                    }
            )
        }
        .frame(height: 28)
    }

    /// Brand marks for the LUT chips: Ricoh as its RICOH wordmark drawn
    /// in code, Leica as the user's red-circle Leica script image.
    private func lutChipIcon(for lut: PhotoLUT, selected: Bool) -> some View {
        Group {
            if lut == .ricoh {
                Text("RICOH")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1)
            } else if lut == .leica {
                Image("LeicaIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
            } else {
                Image(systemName: "slash.circle")
                    .font(.title3)
            }
        }
        .frame(width: 68, height: 68)
        .background(selected ? Color.primary : Color.primary.opacity(0.08), in: Circle())
        .foregroundStyle(selected ? Color(uiColor: .systemBackground) : .primary)
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
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Text(adjustment.lut.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
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
            .tint(.primary)
        }
    }


    /// 风格页签现在只剩质感。
    private var stylesControls: some View {
        textureControls
    }


    /// Tools tab, all in Chinese: LUT is usable; 扩展 + 重构图 are
    /// shown grey and disabled (暂不可用), like the second screenshot
    /// where they appear greyed out. Tapping them does nothing.
    private var toolsControls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                toolChip(title: "LUT", tool: .lut) {
                    Image(systemName: "square.stack.3d")
                        .font(.title3)
                }
                unavailableToolChip(title: "扩展") {
                    ExtendIcon()
                }
                unavailableToolChip(title: "重构图") {
                    ReframeIcon()
                }
                Button { showingErase = true } label: {
                    Text("AI消除")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .disabled(!appleIntelligenceEnabled)
                .opacity(appleIntelligenceEnabled ? 1 : 0.5)
            }
            .padding(.horizontal, 16)
            if !appleIntelligenceEnabled {
                Text("需打开 Apple智能才能用 AI消除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            lutControls
        }
    }

    /// A greyed-out, disabled tool chip: grey circle, grey icon and text,
    /// no tap action. Used for 扩展 and 重构图, which are unavailable.
    private func unavailableToolChip<Content: View>(title: String, @ViewBuilder icon: () -> Content) -> some View {
        Button {} label: {
            VStack(spacing: 8) {
                icon()
                    .frame(width: 68, height: 68)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(true)
        .opacity(0.6)
    }

    private func toolChip<Content: View>(title: String, tool: ToolsTool, @ViewBuilder icon: () -> Content) -> some View {
        let selected = toolsTool == tool
        return Button { toolsTool = tool } label: {
            VStack(spacing: 8) {
                icon()
                    .frame(width: 68, height: 68)
                    .background(selected ? Color.white : Color.primary.opacity(0.08), in: Circle())
                    .foregroundStyle(selected ? .black : .primary)
                    .shadow(color: selected ? .black.opacity(0.15) : .clear, radius: 8, y: 2)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
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
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range).tint(.primary)
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

/// Small downward-pointing triangle marker above the selected tab in
/// the Photos-style bottom pill.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Extend icon, like the second screenshot: a square with a hatched
/// (striped) border, meaning the canvas is extended outward.
private struct ExtendIcon: View {
    var body: some View {
        ZStack {
            Rectangle()
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .frame(width: 34, height: 34)
            Rectangle()
                .stroke(lineWidth: 2)
                .frame(width: 20, height: 20)
        }
    }
}

/// Reframe icon, like the second screenshot: three arrows, one up and
/// two down-outward, meaning the framing is moved.
private struct ReframeIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "arrow.up")
                .font(.headline)
                .offset(y: -14)
            Image(systemName: "arrow.down.left")
                .font(.headline)
                .offset(x: -14, y: 12)
            Image(systemName: "arrow.down.right")
                .font(.headline)
                .offset(x: 14, y: 12)
        }
    }
}
