#if canImport(AVFoundation) && canImport(VideoToolbox)
import AVFoundation
import VideoToolbox

/// Encodes a Live Photo video's linear thumbnail on the device: every frame of the main
/// video, in stored orientation, at 128x96 as HEVC Main 10 without frame reordering and a key
/// frame at least every 30 frames, as `mov_style_tracks.py` does with ffmpeg.
public enum LinearThumbnailEncoder {
    public static let width = 128
    public static let height = 96

    public static func encode(videoURL: URL) async throws -> LivePhotoVideo.LinearThumbnail {
        return try await encode(videoURL: videoURL, width: width, height: height, aperture: nil)
    }

    /// Re-encode only cropped main videos; untouched/full-aperture videos remain byte-identical.
    public static func normalizeAperture(videoURL: URL) async throws -> Data {
        let original = try Data(contentsOf: videoURL)
        let aperture = try LivePhotoVideo.cleanAperture(of: original)
        guard aperture.needsNormalization else { return original }
        let encoded = try await encode(videoURL: videoURL, width: aperture.width,
                                       height: aperture.height, aperture: aperture)
        return try LivePhotoVideo.replacingMainVideo(in: original, with: encoded)
    }

    private static func encode(videoURL: URL, width: Int, height: Int,
                               aperture: LivePhotoVideo.CleanAperture?) async throws -> LivePhotoVideo.LinearThumbnail {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StylePortError.invalidData("The Live Photo video has no video track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw StylePortError.invalidData("The Live Photo video can't be decoded.")
        }
        reader.add(output)

        let encoder = try Encoder(width: width, height: height, aperture: aperture)
        defer { encoder.invalidate() }
        guard reader.startReading() else {
            throw reader.error ?? StylePortError.invalidData("The Live Photo video can't be read.")
        }
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            try encoder.encode(
                image,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),
                duration: CMSampleBufferGetDuration(sample)
            )
        }
        if reader.status == .failed {
            throw reader.error ?? StylePortError.invalidData("The Live Photo video can't be read.")
        }
        return try encoder.finish()
    }

    private final class Encoder: @unchecked Sendable {
        private let aperture: LivePhotoVideo.CleanAperture?
        private let outputWidth: Int
        private let outputHeight: Int
        private let session: VTCompressionSession
        private let transfer: VTPixelTransferSession
        private let pool: CVPixelBufferPool
        private let lock = NSLock()
        /// Frames handed to the encoder, and what came back for each, by input index.
        private var pendingCount = 0
        private var collected: [Int: (Data, Bool)] = [:]
        private var hvcC: Data?
        private var failure: OSStatus = noErr

        init(width: Int, height: Int, aperture: LivePhotoVideo.CleanAperture?) throws {
            self.aperture = aperture
            self.outputWidth = width
            self.outputHeight = height
            var session: VTCompressionSession?
            try check(VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            ), "create the HEVC encoder")
            guard let session else { throw StylePortError.invalidData("No HEVC encoder.") }
            self.session = session
            try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                           value: kVTProfileLevel_HEVC_Main10_AutoLevel), "select Main 10")
            try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                                           value: kCFBooleanFalse), "turn off frame reordering")
            try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                           value: 30 as CFNumber), "set the key frame interval")
            try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                                           value: kCFBooleanFalse), "turn off real-time encoding")

            var transfer: VTPixelTransferSession?
            try check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer),
                      "create the scaler")
            guard let transfer else { throw StylePortError.invalidData("No scaler.") }
            self.transfer = transfer
            if aperture != nil {
                try check(VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode,
                    value: kVTScalingMode_CropSourceToCleanAperture), "select clean-aperture scaling")
                try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                    value: max(width * height * 8, 4_000_000) as CFNumber), "set video quality")
            }

            var pool: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            try check(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool),
                      "create the frame pool")
            guard let pool else { throw StylePortError.invalidData("No frame pool.") }
            self.pool = pool
        }

        func encode(_ image: CVImageBuffer, presentationTime: CMTime, duration: CMTime) throws {
            var scaled: CVPixelBuffer?
            try check(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled), "allocate a frame")
            guard let scaled else { throw StylePortError.invalidData("No frame.") }
            if let aperture {
                let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
                let alreadyCropped = abs(Double(w) - aperture.cleanWidth) < 0.000001
                    && abs(Double(h) - aperture.cleanHeight) < 0.000001
                guard alreadyCropped || (w == aperture.width && h == aperture.height) else {
                    throw StylePortError.invalidData("Unexpected decoded clean-aperture dimensions.")
                }
                let source: [String: Any] = [
                    kCVImageBufferCleanApertureWidthKey as String: alreadyCropped ? Double(w) : aperture.cleanWidth,
                    kCVImageBufferCleanApertureHeightKey as String: alreadyCropped ? Double(h) : aperture.cleanHeight,
                    kCVImageBufferCleanApertureHorizontalOffsetKey as String: alreadyCropped ? 0 : aperture.horizontalOffset,
                    kCVImageBufferCleanApertureVerticalOffsetKey as String: alreadyCropped ? 0 : aperture.verticalOffset
                ]
                CVBufferSetAttachment(image, kCVImageBufferCleanApertureKey, source as CFDictionary, .shouldPropagate)
                CVBufferPropagateAttachments(image, scaled)
                let full: [String: Any] = [
                    kCVImageBufferCleanApertureWidthKey as String: outputWidth,
                    kCVImageBufferCleanApertureHeightKey as String: outputHeight,
                    kCVImageBufferCleanApertureHorizontalOffsetKey as String: 0,
                    kCVImageBufferCleanApertureVerticalOffsetKey as String: 0
                ]
                CVBufferSetAttachment(scaled, kCVImageBufferCleanApertureKey, full as CFDictionary, .shouldPropagate)
            }
            try check(VTPixelTransferSessionTransferImage(transfer, from: image, to: scaled), "scale a frame")
            let index = lock.withLock {
                defer { pendingCount += 1 }
                return pendingCount
            }
            try check(VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: scaled,
                presentationTimeStamp: presentationTime,
                duration: duration,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { [self] status, _, sample in
                self.collect(status: status, sample: sample, index: index)
            }, "encode a frame")
        }

        private func collect(status: OSStatus, sample: CMSampleBuffer?, index: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else {
                if failure == noErr { failure = status == noErr ? -1 : status }
                return
            }
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let copied = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard copied == noErr else {
                if failure == noErr { failure = copied }
                return
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            collected[index] = (bytes, !notSync)
            if hvcC == nil, let format = CMSampleBufferGetFormatDescription(sample),
               let atoms = CMFormatDescriptionGetExtension(
                   format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
               ) as? [String: Any] {
                hvcC = atoms["hvcC"] as? Data
            }
        }

        func finish() throws -> LivePhotoVideo.LinearThumbnail {
            try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid),
                      "finish encoding")
            return try lock.withLock {
                guard failure == noErr else { throw encoderError(failure, "encode a frame") }
                guard let hvcC else { throw StylePortError.invalidData("The HEVC encoder gave no hvcC.") }
                guard collected.count == pendingCount else {
                    throw StylePortError.invalidData(
                        "The HEVC encoder returned \(collected.count) of \(pendingCount) frames."
                    )
                }
                let ordered = (0..<pendingCount).map { collected[$0]! }
                return LivePhotoVideo.LinearThumbnail(
                    samples: ordered.map(\.0),
                    hvcC: hvcC,
                    syncSamples: ordered.indices.filter { ordered[$0].1 }
                )
            }
        }

        func invalidate() {
            VTCompressionSessionInvalidate(session)
            VTPixelTransferSessionInvalidate(transfer)
        }
    }
}

private func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw encoderError(status, action) }
}

private func encoderError(_ status: OSStatus, _ action: String) -> StylePortError {
    .invalidData("Couldn't \(action) for the Live Photo video (\(status)).")
}
#endif
