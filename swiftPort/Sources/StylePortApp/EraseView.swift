import CoreGraphics
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
    let asset: PHAsset

    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var current: UIImage?
    @State private var history: [UIImage] = []
    @State private var strokes: [EraseStroke] = []
    @State private var currentStroke: EraseStroke?
    @State private var brush: CGFloat = 28
    @State private var erasing = false
    @State private var saving = false
    @State private var message: String?

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
            let loaded = await loadOriginal()
            original = loaded
            current = loaded
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
                .disabled(strokes.isEmpty || erasing || current == nil)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            Text("本机涂抹填充：小面积、背景简单的地方效果最好；大面积或复杂纹理会模糊，不是 AI 生成填充。完成后存为新照片，不改原图。")
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
