import Foundation

/// One HEVC-coded tile/sample, as VideoToolbox returns it: the sample bytes
/// (VCL NALs, parameter sets live in hvcC, not in the sample) plus its hvcC box payload.
public struct SyntheticTile {
    public let payload: Data
    public let hvcC: Data
    public init(payload: Data, hvcC: Data) {
        self.payload = payload
        self.hvcC = hvcC
    }
}

/// Build a style-ported iPhone HDR HEIF from synthetic tiles, without a real
/// iPhone HDR photo as input.
///
/// This is experimental v1. It reuses the phone-validated 48-12 donor graph:
/// the source image is resized to 4032x3024, split into 48 primary tiles,
/// a flat gain map is split into 12 HDR tiles, a 416x312 thumbnail is added,
/// and a minimal Apple EXIF (with MakerNote 0x54 injected) is synthesized.
/// Texture/Grain items are added too, so Photos should show the
/// 质感 (texture) tab with 标准 / 柔肤 / 光晕 / 胶片 / 颗粒. The flat gain map means the HDR reconstruction is SDR-like;
/// if Photos shows the photo too bright or too dark, the flat gain value
/// is the first thing to tune in the next iteration.
public enum SyntheticHDRPort {
    public static func port(
        primaryTiles: [SyntheticTile],
        hdrTiles: [SyntheticTile],
        thumbnail: SyntheticTile
    ) throws -> Data {
        guard primaryTiles.count == 48 else {
            throw StylePortError.invalidData("Synthetic primary tiles must be 48, got \(primaryTiles.count).")
        }
        guard hdrTiles.count == 12 else {
            throw StylePortError.invalidData("Synthetic HDR tiles must be 12, got \(hdrTiles.count).")
        }
        let profile = try DonorProfileLoader.load(named: "48-12")
        let manifest = profile.manifest
        var metadata = profile.metadataBox
        var payloads = profile.retainedPayloads

        for (index, tile) in primaryTiles.enumerated() {
            payloads[manifest.donorPrimaryTiles[index]] = tile.payload.stylePortBytes
        }
        for (index, tile) in hdrTiles.enumerated() {
            payloads[manifest.donorHDRTiles[index]] = tile.payload.stylePortBytes
        }
        payloads[manifest.donorThumbnailItem] = thumbnail.payload.stylePortBytes
        payloads[manifest.donorLinearThumbnailItem] = thumbnail.payload.stylePortBytes

        let exif = try AppleExif.injectMakerNoteTag(
            into: syntheticEXIF(),
            payload: profile.makerNote54,
            type: manifest.smartStyleMakerNoteType
        )
        payloads[manifest.donorExifItem] = exif

        // Codec configuration must match the tiles actually encoded, not the donor's.
        func hvcCBox(_ tile: SyntheticTile) -> Bytes {
            makeBox("hvcC", payload: tile.hvcC.stylePortBytes)
        }
        metadata = try HEIF.replaceItemProperty(
            in: metadata,
            itemID: manifest.donorPrimaryTiles[0],
            type: "hvcC",
            sourceBox: hvcCBox(primaryTiles[0])
        )
        metadata = try HEIF.replaceItemProperty(
            in: metadata,
            itemID: manifest.donorThumbnailItem,
            type: "hvcC",
            sourceBox: hvcCBox(thumbnail)
        )
        metadata = try HEIF.replaceItemProperty(
            in: metadata,
            itemID: manifest.donorHDRTiles[0],
            type: "hvcC",
            sourceBox: hvcCBox(hdrTiles[0])
        )
        metadata = try HEIF.replaceProperty(
            in: metadata,
            propertyIndex: manifest.linearThumbnailHVCCPropertyIndex,
            with: hvcCBox(thumbnail),
            expectedType: "hvcC"
        )
        metadata = try HEIF.replaceItemProperty(
            in: metadata,
            itemID: manifest.donorLinearThumbnailItem,
            type: "ispe",
            sourceBox: HEIF.dimensionsBox(width: 416, height: 312)
        )

        // No mattes, no depth in a converted SDR photo: donor matte slots must
        // not leak donor content, so they get exactly-empty frames, as the
        // normal donor-graph port does for unfilled slots.
        let donorMeta = try topBox(metadata, type: "meta")
        let donorProperties = try HEIF.parseProperties(metadata, meta: donorMeta)
        let donorInfos = try HEIF.parseItemInfo(metadata, meta: donorMeta)
        for itemID in donorInfos.keys {
            guard let uri = HEIF.auxiliaryURI(donorProperties, itemID: itemID),
                  HEIF.matteURISet.contains(uri) else { continue }
            if try HEIF.propertyBytes(metadata, table: donorProperties, itemID: itemID, type: "hvcC")
                == AppleBytes.classicMatteHvcc {
                payloads[itemID] = AppleBytes.classicMatteEmpty
            }
        }

        // Texture/Grain: this is what makes Photos show the 质感 tab with
        // 标准 / 柔肤 / 光晕 / 胶片 / 颗粒, alongside the 调色板 tab.
        let added = try Texture.addItems(
            to: metadata,
            primary: manifest.donorPrimaryItem,
            people: nil,
            grainSeed: nil
        )
        metadata = added.0
        payloads.merge(added.1) { _, new in new }

        let rebuilt = try StylePorter().rebuild(profile: profile, metadata: metadata, payloads: payloads)
        return Data(rebuilt)
    }

    /// Minimal EXIF TIFF that AppleExif.injectMakerNoteTag can work with:
    /// IFD0 -> ExifIFD (0x8769) -> MakerNote (0x927c) with a dummy entry,
    /// so the 0x54 style tag can be added. The HEIF exif item starts with
    /// a 4-byte TIFF offset (0), then the TIFF data.
    private static func syntheticEXIF() -> Bytes {
        func u16(_ v: Int) -> Bytes { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func u32(_ v: Int) -> Bytes {
            [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        }
        // MakerNote: "Apple iOS\0" + 2 pad + "II" + 1 entry + next-IFD 0.
        var makerNote: Bytes = []
        makerNote += Bytes("Apple iOS".utf8) + [0, 0, 0]
        makerNote += Bytes("II".utf8)
        makerNote += u16(1)
        // Entry: tag 1, type 7 (undefined), count 4, value "test" inline.
        makerNote += u16(1) + u16(7) + u32(4) + Bytes("test".utf8)
        makerNote += u32(0)

        let exifIFDOffset = 26
        let makerNoteOffset = 44
        var tiff: Bytes = []
        tiff += Bytes("II".utf8) + u16(42) + u32(8)
        // IFD0: 1 entry (ExifIFD pointer), next 0.
        tiff += u16(1)
        tiff += u16(0x8769) + u16(4) + u32(1) + u32(exifIFDOffset)
        tiff += u32(0)
        // ExifIFD: 1 entry (MakerNote), next 0.
        tiff += u16(1)
        tiff += u16(0x927c) + u16(7) + u32(makerNote.count) + u32(makerNoteOffset)
        tiff += u32(0)
        tiff += makerNote
        return [0, 0, 0, 0] + tiff
    }
}
