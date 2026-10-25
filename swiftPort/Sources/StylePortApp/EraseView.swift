import CoreGraphics
import CoreML
import Photos
import SwiftUI
import UIKit

/// A brush stroke in image-normalized coordinates (0...1 in both axes).
/// The brush size is also normalized: a fraction of the image width, so
/// view and image coordinates share one uniform scale (aspect fit).
private struct EraseStroke {
    var points: [CGPoint]
    var brush: CGFloat
}

/// Object removal, done on-device: paint over the unwanted thing, then
/// "消除" fills the painted area from its surrounding pixels.
///
/// This is diffusion inpainting, not AI generative fill: it works well
/// for small objects on fairly uniform backgrounds (sky, wall, grass,
/// sea) and will look soft / smeared on large objects or complex
/// textures. That limit is stated in the UI, not hidden.
struct EraseView: View {
    let asset: PHAsset?
    let initialImage: UIImage?

    init(asset: PHAsset) {
        self.asset = asset
        self.initialImage = nil
    }

    init(image: UIImage) {
        self.asset = nil
        self.initialImage = image
    }

    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var current: UIImage?
    @State private var history: [UIImage] = []
    @State private var strokes: [EraseStroke] = []
    @State private var currentStroke: EraseStroke?
    @State private var brush: CGFloat = 28
    @State private var erasing = false
    @State private var aiErasing = false
    @State private var downloadingModel = false
    @State private var saving = false
    @State private var message: String?
    @State private var complianceBlocked = false
    @State private var complianceConfirmed = false
    @State private var showingCompliance = false
    @State private var compliancePendingAI = false
    @State private var complianceScanning = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                photoArea
                controls
            }
        }
        .presentationBackground(Color.black)
        .preferredColorScheme(.dark)
        .alert(
            "消除",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("确定") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task {
            if let initialImage {
                original = initialImage
                current = initialImage
            } else {
                let loaded = await loadOriginal()
                original = loaded
                current = loaded
            }
            if let original {
                complianceBlocked = await Task.detached(priority: .userInitiated) {
                    flagHeuristicSuspect(image: original)
                }.value
            }
            complianceScanning = false
        }
        .alert(
            "合规确认",
            isPresented: $showingCompliance
        ) {
            Button("确认不涉及，继续消除") {
                complianceConfirmed = true
                let useAI = compliancePendingAI
                Task { if useAI { await applyAIErase() } else { await applyErase() } }
            }
            Button("涉及上述标识，取消", role: .cancel) {
                complianceBlocked = true
                message = "按合规要求，涉及国旗、国徽、党旗、党徽、红旗的照片不得消除，本照片的消除功能已停用。"
            }
        } message: {
            Text("请确认：本照片不涉及中华人民共和国国旗、国徽、党旗、党徽、红旗等标识。涉及上述标识的照片不得消除。")
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
                Text("消除").font(.headline)
                Text(strokes.isEmpty && currentStroke == nil ? "手指涂抹不要的东西，再点消除" : "已涂抹，点消除填充")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await saveCopy() } } label: {
                Text(saving ? "保存中…" : "完成")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .frame(height: 48)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .disabled(current == nil || saving || erasing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var photoArea: some View {
        Group {
            if let current {
                GeometryReader { geometry in
                    let size = geometry.size
                    let imageSize = current.size
                    let scale = min(size.width / imageSize.width, size.height / imageSize.height)
                    let displayWidth = imageSize.width * scale
                    let displayHeight = imageSize.height * scale
                    ZStack {
                        Image(uiImage: current)
                            .resizable()
                            .scaledToFit()
                            .frame(width: displayWidth, height: displayHeight)
                        // Painted mask, drawn in the same frame as the photo.
                        Path { path in
                            for stroke in strokes + (currentStroke.map { [$0] } ?? []) {
                                guard let first = stroke.points.first else { continue }
                                path.move(to: CGPoint(x: first.x * displayWidth, y: first.y * displayHeight))
                                for point in stroke.points.dropFirst() {
                                    path.addLine(to: CGPoint(x: point.x * displayWidth, y: point.y * displayHeight))
                                }
                            }
                        }
                        .stroke(Color.red.opacity(0.55), style: StrokeStyle(lineWidth: brush, lineCap: .round, lineJoin: .round))
                    }
                    .frame(width: size.width, height: size.height)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let point = CGPoint(
                                    x: min(max((value.location.x - (size.width - displayWidth) / 2) / displayWidth, 0), 1),
                                    y: min(max((value.location.y - (size.height - displayHeight) / 2) / displayHeight, 0), 1)
                                )
                                if currentStroke == nil {
                                    currentStroke = EraseStroke(points: [point], brush: brush / displayWidth)
                                } else {
                                    currentStroke?.points.append(point)
                                }
                            }
                            .onEnded { _ in
                                if let stroke = currentStroke {
                                    strokes.append(stroke)
                                    currentStroke = nil
                                }
                            }
                    )
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if complianceScanning {
                Text("正在做合规审查…")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if complianceBlocked {
                Text("合规审查：本照片疑似或已确认涉及中华人民共和国国旗、国徽、党旗、党徽、红旗，按合规要求消除功能已停用。")
                    .font(.footnote).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            } else {
                Text("合规：涉及中华人民共和国国旗、国徽、党旗、党徽、红旗的照片不得消除。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            HStack {
                Text("笔刷").font(.subheadline.weight(.medium)).foregroundStyle(.white)
                Spacer()
                Text("\(Int(brush))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            Slider(value: $brush, in: 10...80)
                .padding(.horizontal, 16)
                .tint(.white)
            HStack(spacing: 12) {
                Button {
                    strokes.removeAll()
                    currentStroke = nil
                } label: {
                    Label("清除涂抹", systemImage: "trash")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.15), in: Capsule())
                }
                .disabled(strokes.isEmpty && currentStroke == nil)
                Button {
                    if let previous = history.popLast() {
                        current = previous
                        strokes.removeAll()
                    }
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.15), in: Capsule())
                }
                .disabled(history.isEmpty)
                Button {
                    Task { await applyErase() }
                } label: {
                    Label(erasing ? "消除中…" : "消除", systemImage: "eraser.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                .disabled(strokes.isEmpty || erasing || current == nil || complianceBlocked || complianceScanning)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            Button {
                Task { await applyAIErase() }
            } label: {
                Label(aiErasing ? "AI 消除中…" : (downloadingModel ? "正在下载 AI 模型…" : "AI 消除"), systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(strokes.isEmpty || aiErasing || erasing || downloadingModel || current == nil || complianceBlocked || complianceScanning)
            .padding(.horizontal, 16)
            Text("普通消除是本机扩散填充，小面积、背景简单的地方效果最好；AI 消除用 LaMa 模型生成填充，首次使用时下载模型（约 60MB 以上），照片不出手机。完成后存为新照片，不改原图。")
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

    private func loadOriginal() async -> UIImage? {
        guard let asset else { return nil }
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

    private func applyErase() async {
        guard let image = current, !strokes.isEmpty, !erasing else { return }
        guard !complianceBlocked else { return }
        guard complianceConfirmed else { compliancePendingAI = false; showingCompliance = true; return }
        erasing = true
        defer { erasing = false }
        let strokes = strokes
        let result = await Task.detached(priority: .userInitiated) {
            inpaint(image: image, strokes: strokes)
        }.value
        guard let result else {
            message = "消除失败，请再试一次。"
            return
        }
        history.append(image)
        current = result
        self.strokes.removeAll()
    }

    private func saveCopy() async {
        guard let current else { return }
        saving = true
        defer { saving = false }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: current)
                }, completionHandler: { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: NSError(domain: "EraseView", code: 0))
                    }
                })
            }
            message = "已存为新照片。"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}


    // MARK: - AI erase (LaMa, on-device)

    /// LaMaFP16_512 from the open-source Inpaint-iOS project (GPL-3.0,
    /// based on advimman/lama). The model is NOT bundled in the IPA:
    /// on first AI erase it is downloaded to Documents, three files
    /// totalling roughly 60MB+, and reused afterwards. If the download
    /// only yields a tiny placeholder file (e.g. a Git LFS pointer),
    /// that is treated as a failure with a clear message, not a crash.
    static var modelDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaMaFP16_512.mlpackage")
    }

    static var modelFiles: [(relative: String, url: URL)] {
        let base = "https://raw.githubusercontent.com/wudijimao/Inpaint-iOS/main/Inpaint/LaMaFP16_512.mlpackage"
        return [
            ("Manifest.json", URL(string: base + "/Manifest.json")!),
            ("Data/com.apple.CoreML/model.mlmodel", URL(string: base + "/Data/com.apple.CoreML/model.mlmodel")!),
            ("Data/com.apple.CoreML/weights/weight.bin", URL(string: base + "/Data/com.apple.CoreML/weights/weight.bin")!),
        ]
    }

    private func downloadModelIfNeeded() async throws {
        let directory = Self.modelDirectory
        let weightURL = directory.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        if FileManager.default.fileExists(atPath: weightURL.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: weightURL.path)[.size] as? Int) ?? 0
            if size > 10_000_000 { return }
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (relative, url) in Self.modelFiles {
            let destination = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: weightURL.path)[.size] as? Int) ?? 0
        guard size > 10_000_000 else {
            try? FileManager.default.removeItem(at: directory)
            throw NSError(domain: "EraseView", code: 1, userInfo: [NSLocalizedDescriptionKey: "模型文件下载到的不是完整权重（可能是占位文件），AI 消除暂不可用，请重试或用普通消除。"])
        }
    }

    private func applyAIErase() async {
        guard let image = current, !strokes.isEmpty, !aiErasing, !erasing else { return }
        guard !complianceBlocked else { return }
        guard complianceConfirmed else { compliancePendingAI = true; showingCompliance = true; return }
        aiErasing = true
        defer { aiErasing = false }
        do {
            if !FileManager.default.fileExists(atPath: Self.modelDirectory.path) {
                downloadingModel = true
                defer { downloadingModel = false }
                try await downloadModelIfNeeded()
            } else {
                try await downloadModelIfNeeded()
            }
            let strokes = strokes
            let result = try await Task.detached(priority: .userInitiated) {
                try aiInpaint(image: image, strokes: strokes)
            }.value
            guard let result else {
                message = "AI 消除失败，请再试一次，或用普通消除。"
                return
            }
            history.append(image)
            current = result
            self.strokes.removeAll()
        } catch {
            message = "AI 消除失败：\(error.localizedDescription)"
        }
    }

/// Diffusion inpainting: masked pixels are filled layer by layer from
/// already-filled neighbours, so each masked pixel is written once.
private func inpaint(image: UIImage, strokes: [EraseStroke]) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return nil }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

    // Rasterize strokes into a mask.
    var mask = [Bool](repeating: false, count: width * height)
    for stroke in strokes {
        let radius = max(1, Int(stroke.brush * CGFloat(width)))
        for index in stroke.points.indices {
            let point = stroke.points[index]
            let cx = Int(point.x * CGFloat(width))
            let cy = Int(point.y * CGFloat(height))
            let previous: CGPoint? = index > 0 ? stroke.points[index - 1] : nil
            // Walk the segment so fast drags do not leave gaps.
            let steps: Int
            if let previous {
                let dx = (point.x - previous.x) * CGFloat(width)
                let dy = (point.y - previous.y) * CGFloat(height)
                steps = max(1, Int(max(abs(dx), abs(dy)) / CGFloat(max(1, radius / 2))))
            } else {
                steps = 1
            }
            for step in 0...steps {
                let t = steps == 0 ? 0 : CGFloat(step) / CGFloat(steps)
                let px = previous.map { Int(($0.x + (point.x - $0.x) * t) * CGFloat(width)) } ?? cx
                let py = previous.map { Int(($0.y + (point.y - $0.y) * t) * CGFloat(height)) } ?? cy
                for y in (py - radius)...(py + radius) {
                    guard y >= 0, y < height else { continue }
                    for x in (px - radius)...(px + radius) {
                        guard x >= 0, x < width else { continue }
                        let dx = x - px
                        let dy = y - py
                        if dx * dx + dy * dy <= radius * radius {
                            mask[y * width + x] = true
                        }
                    }
                }
            }
        }
    }

    var filled = mask.map { !$0 }
    // Frontier: masked pixels touching a filled pixel, filled in order.
    var queue: [Int] = []
    var queued = [Bool](repeating: false, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            guard mask[index] else { continue }
            let neighbours = [
                (x > 0) ? index - 1 : -1,
                (x + 1 < width) ? index + 1 : -1,
                (y > 0) ? index - width : -1,
                (y + 1 < height) ? index + width : -1,
            ]
            if neighbours.contains(where: { $0 >= 0 && filled[$0] }) {
                queue.append(index)
                queued[index] = true
            }
        }
    }
    var head = 0
    while head < queue.count {
        let index = queue[head]
        head += 1
        guard mask[index], !filled[index] else { continue }
        let x = index % width
        let y = index / width
        var sumR = 0, sumG = 0, sumB = 0, count = 0
        let neighbours = [
            (x > 0) ? index - 1 : -1,
            (x + 1 < width) ? index + 1 : -1,
            (y > 0) ? index - width : -1,
            (y + 1 < height) ? index + width : -1,
            (x > 0 && y > 0) ? index - width - 1 : -1,
            (x + 1 < width && y > 0) ? index - width + 1 : -1,
            (x > 0 && y + 1 < height) ? index + width - 1 : -1,
            (x + 1 < width && y + 1 < height) ? index + width + 1 : -1,
        ]
        for neighbour in neighbours where neighbour >= 0 && filled[neighbour] {
            let offset = neighbour * 4
            sumR += Int(pixels[offset])
            sumG += Int(pixels[offset + 1])
            sumB += Int(pixels[offset + 2])
            count += 1
        }
        guard count > 0 else { continue }
        let offset = index * 4
        pixels[offset] = UInt8(sumR / count)
        pixels[offset + 1] = UInt8(sumG / count)
        pixels[offset + 2] = UInt8(sumB / count)
        pixels[offset + 3] = 255
        filled[index] = true
        for neighbour in neighbours where neighbour >= 0 && mask[neighbour] && !filled[neighbour] && !queued[neighbour] {
            queue.append(neighbour)
            queued[neighbour] = true
        }
    }

    guard let output = context.makeImage() else { return nil }
    return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
}

/// AI inpainting with LaMaFP16_512 (image + mask in, image out).
/// Steps: render the brush strokes as a black/white mask, crop the
/// painted area to a square, run the model at 512x512, blend only the
/// masked area back (unmasked pixels stay exactly as they were), and
/// paste the crop back into the full photo.
private func aiInpaint(image: UIImage, strokes: [EraseStroke]) throws -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0, !strokes.isEmpty else { return nil }

    // Mask image, in pixel coordinates.
    let maskRenderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
    let maskImage = maskRenderer.image { context in
        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        UIColor.white.setStroke()
        for stroke in strokes {
            let path = UIBezierPath()
            path.lineWidth = max(1, stroke.brush * CGFloat(width))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            guard let first = stroke.points.first else { continue }
            path.move(to: CGPoint(x: first.x * CGFloat(width), y: first.y * CGFloat(height)))
            for point in stroke.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height)))
            }
            path.stroke()
        }
    }
    guard let maskCG = maskImage.cgImage else { return nil }

    // Square crop around the painted area, clamped to the photo.
    var minX = CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxX: CGFloat = 0
    var maxY: CGFloat = 0
    var maxBrush: CGFloat = 0
    for stroke in strokes {
        maxBrush = max(maxBrush, stroke.brush * CGFloat(width))
        for point in stroke.points {
            minX = min(minX, point.x * CGFloat(width))
            minY = min(minY, point.y * CGFloat(height))
            maxX = max(maxX, point.x * CGFloat(width))
            maxY = max(maxY, point.y * CGFloat(height))
        }
    }
    minX -= maxBrush; minY -= maxBrush; maxX += maxBrush; maxY += maxBrush
    var side = max(maxX - minX, maxY - minY, 64)
    side = min(side, CGFloat(min(width, height)))
    var originX = minX + (maxX - minX - side) / 2
    var originY = minY + (maxY - minY - side) / 2
    originX = min(max(originX, 0), CGFloat(width) - side)
    originY = min(max(originY, 0), CGFloat(height) - side)
    let crop = CGRect(x: originX, y: originY, width: side, height: side)
    guard let croppedCG = cgImage.cropping(to: crop),
          let croppedMaskCG = maskCG.cropping(to: crop) else { return nil }
    let croppedImage = UIImage(cgImage: croppedCG)
    let croppedMask = UIImage(cgImage: croppedMaskCG)

    func resized(_ image: UIImage, to size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    let target = CGSize(width: 512, height: 512)
    let resizedImage = resized(croppedImage, to: target)
    let resizedMask = resized(croppedMask, to: target)
    guard let resizedImageCG = resizedImage.cgImage,
          let resizedMaskCG = resizedMask.cgImage else { return nil }
    let imageBuffer = try MLFeatureValue(cgImage: resizedImageCG, pixelsWide: 512, pixelsHigh: 512, pixelFormatType: kCVPixelFormatType_32ARGB).imageBufferValue
    let maskBuffer = try MLFeatureValue(cgImage: resizedMaskCG, pixelsWide: 512, pixelsHigh: 512, pixelFormatType: kCVPixelFormatType_OneComponent8).imageBufferValue
    guard let imageBuffer, let maskBuffer else { return nil }

    var configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndGPU
    let model = try MLModel(contentsOf: EraseView.modelDirectory, configuration: configuration)
    let input = try MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(pixelBuffer: imageBuffer),
        "mask": MLFeatureValue(pixelBuffer: maskBuffer),
    ])
    let output = try model.prediction(from: input)
    guard let outBuffer = output.featureValue(for: "output")?.imageBufferValue else { return nil }
    let outCI = CIImage(cvPixelBuffer: outBuffer)
    let ciContext = CIContext(options: nil)
    guard let outCG = ciContext.createCGImage(outCI, from: outCI.extent) else { return nil }
    let outImage = UIImage(cgImage: outCG)

    // Blend only the masked area, so unmasked pixels are untouched.
    guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
    blend.setValue(CIImage(cgImage: outCG), forKey: kCIInputImageKey)
    blend.setValue(CIImage(cgImage: resizedImageCG), forKey: kCIInputBackgroundImageKey)
    blend.setValue(CIImage(cgImage: resizedMaskCG), forKey: "inputMaskImage")
    guard let blended = blend.outputImage,
          let blendedCG = ciContext.createCGImage(blended, from: blended.extent) else { return nil }
    let blendedImage = UIImage(cgImage: blendedCG)
    let blendedBack = resized(blendedImage, to: CGSize(width: side, height: side))
    guard let blendedBackCG = blendedBack.cgImage else { return nil }

    // Paste the blended crop back into the full photo, in pixels.
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(blendedBackCG, in: crop)
    guard let finalCG = context.makeImage() else { return nil }
    return UIImage(cgImage: finalCG, scale: image.scale, orientation: image.imageOrientation)
}

/// Best-effort on-device compliance pre-check, not a legal identifier:
/// a photo with a large strong-red area plus a compact yellow element
/// (stars / hammer-and-sickle / emblem gold, as on the national flag,
/// party flag and national emblem) is treated as suspect and its
/// elimination is blocked. A plain red flag with no yellow element, or
/// a small emblem, will not be caught by this scan, so the user
/// declaration in EraseView is the second layer. False positives are
/// possible on ordinary red-and-yellow photos; that is the conservative
/// trade-off for this rule.
private func flagHeuristicSuspect(image: UIImage) -> Bool {
    guard let cgImage = image.cgImage else { return false }
    let size = 256
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let data = context.data else { return false }
    let pixels = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
    var redCount = 0
    var yellowCount = 0
    var yellowMinX = size, yellowMinY = size, yellowMaxX = 0, yellowMaxY = 0
    for y in 0..<size {
        for x in 0..<size {
            let offset = (y * size + x) * 4
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            if r > 150 && g < 100 && b < 100 && r - g > 80 { redCount += 1 }
            if r > 180 && g > 150 && b < 100 && r - b > 100 && g - b > 80 {
                yellowCount += 1
                yellowMinX = min(yellowMinX, x); yellowMaxX = max(yellowMaxX, x)
                yellowMinY = min(yellowMinY, y); yellowMaxY = max(yellowMaxY, y)
            }
        }
    }
    let total = size * size
    let redRatio = Double(redCount) / Double(total)
    let yellowRatio = Double(yellowCount) / Double(total)
    guard redRatio > 0.10, yellowRatio > 0.003, yellowCount > 0 else { return false }
    let yellowWidth = Double(yellowMaxX - yellowMinX + 1) / Double(size)
    let yellowHeight = Double(yellowMaxY - yellowMinY + 1) / Double(size)
    // Stars / emblem gold sit in a compact area, not spread over the whole photo.
    return yellowWidth < 0.6 && yellowHeight < 0.6
}
