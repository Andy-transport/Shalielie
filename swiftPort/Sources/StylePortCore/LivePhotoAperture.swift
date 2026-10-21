import Foundation

extension LivePhotoVideo {
    public struct CleanAperture: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let cleanWidth: Double
        public let cleanHeight: Double
        public let horizontalOffset: Double
        public let verticalOffset: Double

        public var needsNormalization: Bool {
            cleanWidth != Double(width) || cleanHeight != Double(height)
                || horizontalOffset != 0 || verticalOffset != 0
        }
    }

    /// Read the visible rectangle, including signed offsets from the picture center.
    public static func cleanAperture(of video: Data) throws -> CleanAperture {
        let movie = try Movie(video.stylePortBytes)
        let main = try movie.mainVideo()
        guard let sd = try movie.sampleTables(main)["stsd"] else {
            throw StylePortError.invalidData("The video has no sample description.")
        }
        let entry = sd.offset + sd.headerSize + 8
        guard try readUInt(movie.data, sd.offset + sd.headerSize + 4, 4) == 1 else {
            throw StylePortError.invalidData("Multiple video sample descriptions are not supported.")
        }
        let size = try readUInt(movie.data, entry, 4)
        guard size >= 86, entry + size <= sd.offset + sd.size else {
            throw StylePortError.invalidData("Invalid video sample description.")
        }
        let w = try readUInt(movie.data, entry + 32, 2)
        let h = try readUInt(movie.data, entry + 34, 2)
        guard w > 0, h > 0 else { throw StylePortError.invalidData("Invalid video dimensions.") }
        let boxes = try siblingBoxes(movie.data, from: entry + 86, to: entry + size)
        guard let clap = boxes.first(where: { $0.type == "clap" }) else {
            return CleanAperture(width: w, height: h, cleanWidth: Double(w), cleanHeight: Double(h),
                                 horizontalOffset: 0, verticalOffset: 0)
        }
        guard clap.size - clap.headerSize == 32 else {
            throw StylePortError.invalidData("Invalid clean aperture.")
        }
        func fraction(_ index: Int, signed: Bool = false) throws -> Double {
            let start = clap.offset + clap.headerSize + index * 8
            let raw = try readUInt(movie.data, start, 4)
            let numerator = signed ? Double(Int32(bitPattern: UInt32(raw))) : Double(raw)
            let denominator = try readUInt(movie.data, start + 4, 4)
            guard denominator > 0 else {
                throw StylePortError.invalidData("Zero clean-aperture denominator.")
            }
            return numerator / Double(denominator)
        }
        let cw = try fraction(0), ch = try fraction(1)
        let x = try fraction(2, signed: true), y = try fraction(3, signed: true)
        guard cw > 0, ch > 0, cw <= Double(w), ch <= Double(h),
              abs(x) + cw / 2 <= Double(w) / 2 + 0.000001,
              abs(y) + ch / 2 <= Double(h) / 2 + 0.000001 else {
            throw StylePortError.invalidData("Clean aperture is outside the coded picture.")
        }
        return CleanAperture(width: w, height: h, cleanWidth: cw, cleanHeight: ch,
                             horizontalOffset: x, verticalOffset: y)
    }

    /// Replace only the main video's compressed samples after baking its clean aperture.
    /// Keep coded dimensions, track transforms, timing, audio and Live Photo metadata.
    public static func replacingMainVideo(in video: Data, with encoded: LinearThumbnail) throws -> Data {
        let target = try Movie(video.stylePortBytes)
        let main = try target.mainVideo()
        let geometry = try cleanAperture(of: video)
        let deltas = try target.sampleDeltas(main)
        guard !encoded.samples.isEmpty, encoded.samples.count == deltas.count,
              !encoded.hvcC.isEmpty,
              encoded.syncSamples.first == 0,
              encoded.syncSamples.allSatisfy({ $0 >= 0 && $0 < encoded.samples.count }) else {
            throw StylePortError.invalidData("The normalized video's samples do not match the original timeline.")
        }
        func u32(_ n: Int) -> Bytes { bigEndianBytes(n, count: 4) }
        // Keep existing offsets valid even for previously styled files with media after moov.
        var head = target.data
        if target.moov.offset + target.moov.size == head.count {
            head = Array(head[..<target.moov.offset])
        } else {
            try writeBytes(Bytes("free".utf8), into: &head, at: target.moov.offset + 4)
        }
        let offset = head.count + 8
        guard offset < Int(UInt32.max) else { throw StylePortError.invalidData("MOV is too large.") }
        func rebuilt(_ start: Int, _ end: Int) throws -> Bytes {
            var result: [Bytes] = []
            for box in try siblingBoxes(target.data, from: start, to: end) {
                let body = box.offset + box.headerSize
                switch box.type {
                case "mdia", "minf", "stbl":
                    result.append(makeBox(box.type, payload: try rebuilt(body, box.offset + box.size)))
                case "stsd":
                    let entry = body + 8
                    let size = try readUInt(target.data, entry, 4)
                    let extras = try siblingBoxes(target.data, from: entry + 86, to: entry + size).map { child -> Bytes in
                        if child.type == "hvcC" { return makeBox("hvcC", payload: encoded.hvcC.stylePortBytes) }
                        if child.type == "clap" {
                            return makeBox("clap", payload: concatenated(
                                [geometry.width, 1, geometry.height, 1, 0, 1, 0, 1].map(u32)))
                        }
                        return try byteSlice(target.data, child.offset, child.size)
                    }
                    let visual = try byteSlice(target.data, entry + 4, 82) + concatenated(extras)
                    result.append(makeBox("stsd", payload: concatenated(
                        [[0,0,0,0], u32(1), u32(visual.count + 4), visual])))
                case "stts":
                    result.append(try byteSlice(target.data, box.offset, box.size))
                case "stsc":
                    result.append(makeBox("stsc", payload: concatenated(
                        [[0,0,0,0], u32(1), u32(1), u32(encoded.samples.count), u32(1)])))
                case "stsz":
                    result.append(makeBox("stsz", payload: concatenated(
                        [[0,0,0,0], u32(0), u32(encoded.samples.count)] + encoded.samples.map { u32($0.count) })))
                    if encoded.syncSamples.count < encoded.samples.count {
                        result.append(makeBox("stss", payload: concatenated(
                            [[0,0,0,0], u32(encoded.syncSamples.count)] + encoded.syncSamples.map { u32($0 + 1) })))
                    }
                case "stco", "co64":
                    result.append(makeBox("stco", payload: concatenated([[0,0,0,0], u32(1), u32(offset)])))
                case "stss", "ctts", "sdtp", "sgpd", "sbgp", "cslg":
                    break // These describe the old encoder's frame dependencies/reordering.
                default:
                    result.append(try byteSlice(target.data, box.offset, box.size))
                }
            }
            return concatenated(result)
        }
        let newMain = makeBox("trak", payload: try rebuilt(main.offset + main.headerSize, main.offset + main.size))
        let children = try target.moovChildren().map { child in
            child == main ? newMain : try byteSlice(target.data, child.offset, child.size)
        }
        let media = makeBox("mdat", payload: concatenated(encoded.samples.map(\.stylePortBytes)))
        let output = Data(concatenated([head, media, makeBox("moov", payload: concatenated(children))]))
        let check = try Movie(output.stylePortBytes)
        guard try check.samples(check.mainVideo()) == encoded.samples.map(\.stylePortBytes) else {
            throw StylePortError.invalidData("Normalized video sample verification failed.")
        }
        return output
    }
}
