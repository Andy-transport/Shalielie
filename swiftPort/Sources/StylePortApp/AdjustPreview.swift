import CoreImage
import Photos
import SwiftUI
import UIKit

/// The four adjustments offered by the new Adjust & Preview sheet.
///
/// This is a local preview adjustment (brightness / contrast / saturation /
/// warmth), rendered with Core Image. It is deliberately separate from the
/// Photographic Style port: saving here writes a new adjusted copy to Photos,
/// it does not change the style data that "Add Photographic Style" writes.
struct PhotoAdjustment: Equatable {
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var warmth: Double = 0

    var isDefault: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && warmth == 0
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
        let context = CIContext(options: nil)
        guard let rendered = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}

private enum AdjustmentPreviewMode: String, CaseIterable {
    case adjusted
    case original
    case compare

    var title: String {
        switch self {
        case .adjusted: return "Adjusted"
        case .original: return "Original"
        case .compare: return "Compare"
        }
    }
}

/// Adjust a photo and see the result before saving it.
///
/// Opened from a photo's detail view. The preview is live: every slider move
/// re-renders the preview image, and Compare drags a divider across the photo
/// so the original (left) and the adjusted version (right) can be judged
/// side by side on the same photo.
struct AdjustPreviewView: View {
    let asset: PHAsset

    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var adjusted: UIImage?
    @State private var adjustment = PhotoAdjustment()
    @State private var mode = AdjustmentPreviewMode.compare
    @State private var divider: CGFloat = 0.5
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    preview
                        .frame(maxWidth: .infinity)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )

                    Picker("Preview", selection: $mode) {
                        ForEach(AdjustmentPreviewMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 16) {
                        adjustmentSlider(
                            title: "Brightness",
                            value: Binding(
                                get: { adjustment.brightness },
                                set: { adjustment.brightness = $0 }
                            ),
                            range: -1...1
                        )
                        adjustmentSlider(
                            title: "Contrast",
                            value: Binding(
                                get: { adjustment.contrast },
                                set: { adjustment.contrast = $0 }
                            ),
                            range: 0...2
                        )
                        adjustmentSlider(
                            title: "Saturation",
                            value: Binding(
                                get: { adjustment.saturation },
                                set: { adjustment.saturation = $0 }
                            ),
                            range: 0...2
                        )
                        adjustmentSlider(
                            title: "Warmth",
                            value: Binding(
                                get: { adjustment.warmth },
                                set: { adjustment.warmth = $0 }
                            ),
                            range: -1...1
                        )
                    }

                    HStack(spacing: 12) {
                        Button("Reset") { adjustment = PhotoAdjustment() }
                            .buttonStyle(.bordered)
                            .disabled(adjustment.isDefault)
                        Button {
                            Task { await saveAdjustedCopy() }
                        } label: {
                            if saving { ProgressView() }
                            else { Label("Save Adjusted Copy", systemImage: "square.and.arrow.down") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(adjusted == nil || saving)
                    }

                    Text("This saves a new adjusted copy to Photos. It does not change the Photographic Style added by “Add Photographic Style”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Adjust & Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Adjust & Preview",
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
            ) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
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
    }

    @ViewBuilder
    private var preview: some View {
        if let original, let adjusted {
            switch mode {
            case .adjusted:
                Image(uiImage: adjusted)
                    .resizable()
                    .scaledToFit()
            case .original:
                Image(uiImage: original)
                    .resizable()
                    .scaledToFit()
            case .compare:
                comparePreview(original: original, adjusted: adjusted)
            }
        } else if let original {
            Image(uiImage: original)
                .resizable()
                .scaledToFit()
        } else {
            ProgressView()
        }
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
                    // Clip to the right of the divider: original stays on the left,
                    // adjusted shows on the right.
                    .clipShape(
                        Rectangle()
                            .offset(x: geometry.size.width * divider)
                    )
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: geometry.size.height)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: geometry.size.width * divider)
                VStack {
                    Text("Original")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack {
                    Text("Adjusted")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
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

    private func adjustmentSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
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

    private func saveAdjustedCopy() async {
        guard let adjusted else { return }
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
            message = "Adjusted copy saved to Photos."
        } catch {
            message = error.localizedDescription
        }
    }
}
