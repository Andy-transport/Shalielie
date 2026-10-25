import CoreImage
import CoreVideo
import StylePortCore
import VideoToolbox

/// Encode one still tile as a single HEVC sample with its hvcC, using the
/// same VideoToolbox pattern as the Live Photo linear-thumbnail encoder.
/// v1 uses HEVC Main 10 for every tile, thumbnail and gain-map tile.
enum HEVCStillEncoder {
    static func encode(_ cgImage: CGImage) throws -> SyntheticTile {
        let width = cgImage.width
        let height = cgImage.height
        guard width % 2 == 0, height % 2 == 0 else {
            throw LibraryError.saveFailed("瓦片尺寸必须为偶数：\(width)x\(height)")
        }
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        guard CVPixelBufferCreate(nil, width, height,
                                  kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else {
            throw LibraryError.saveFailed("无法分配像素缓冲")
        }
        let ciImage = CIImage(cgImage: cgImage)
        CIContext().render(ciImage, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           colorSpace: CGColorSpaceCreateDeviceRGB())

        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(
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
        ) == noErr, let session else {
            throw LibraryError.saveFailed("无法创建 HEVC 编码器")
        }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: 1 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanFalse)

        var sampleData: Data?
        var hvcCData: Data?
        var encodeError: OSStatus = noErr
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: buffer,
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 1),
            frameProperties: nil,
            infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample,
                  let block = CMSampleBufferGetDataBuffer(sample) else {
                encodeError = status == noErr ? -1 : status
                return
            }
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let copied = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard copied == noErr else { encodeError = copied; return }
            sampleData = bytes
            if let format = CMSampleBufferGetFormatDescription(sample),
               let atoms = CMFormatDescriptionGetExtension(
                   format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
               ) as? [String: Any] {
                hvcCData = atoms["hvcC"] as? Data
            }
        }
        guard status == noErr else {
            throw LibraryError.saveFailed("HEVC 编码失败 (\(status))")
        }
        guard VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) == noErr else {
            throw LibraryError.saveFailed("HEVC 编码收尾失败")
        }
        guard encodeError == noErr, let payload = sampleData, let hvcC = hvcCData else {
            throw LibraryError.saveFailed("HEVC 编码器没有返回瓦片数据")
        }
        return SyntheticTile(payload: payload, hvcC: hvcC)
    }

    /// Resize/crop a decoded image to an exact size, centre-cropped to aspect.
    static func resized(_ cgImage: CGImage, to size: CGSize) -> CGImage? {
        let source = CIImage(cgImage: cgImage)
        let sourceAspect = source.extent.width / source.extent.height
        let targetAspect = size.width / size.height
        var cropped = source
        if sourceAspect > targetAspect {
            let newWidth = source.extent.height * targetAspect
            let x = source.extent.origin.x + (source.extent.width - newWidth) / 2
            cropped = source.cropped(to: CGRect(x: x, y: source.extent.origin.y, width: newWidth, height: source.extent.height))
        } else {
            let newHeight = source.extent.width / targetAspect
            let y = source.extent.origin.y + (source.extent.height - newHeight) / 2
            cropped = source.cropped(to: CGRect(x: source.extent.origin.x, y: y, width: source.extent.width, height: newHeight))
        }
        let scaleX = size.width / cropped.extent.width
        let scaleY = size.height / cropped.extent.height
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return CIContext().createCGImage(scaled, from: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    /// Split an image into a grid of tiles, in row-major order.
    static func tiles(of image: CGImage, columns: Int, rows: Int, tileSize: Int) -> [CGImage] {
        var result: [CGImage] = []
        for row in 0..<rows {
            for col in 0..<columns {
                let x = col * tileSize
                let y = row * tileSize
                let w = min(tileSize, image.width - x)
                let h = min(tileSize, image.height - y)
                guard w > 0, h > 0, let tile = image.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { continue }
                result.append(tile)
            }
        }
        return result
    }
}
