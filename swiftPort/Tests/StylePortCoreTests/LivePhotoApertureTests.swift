import XCTest
@testable import StylePortCore

final class LivePhotoApertureTests: XCTestCase {
    private func u(_ value: Int) -> Bytes { bigEndianBytes(value, count: 4) }

    private func movie(cleanWidth: Int = 144, denominator: Int = 1,
                       horizontal: Int64 = 0, trailingMedia: Bool = false) -> Data {
        func track(_ kind: String, id: Int, offset: Int, sizes: [Int]) -> Bytes {
            var description: Bytes = []
            if kind == "vide" {
                let clap = makeBox("clap", payload: concatenated([
                    u(cleanWidth),u(denominator),u(112),u(1),bigEndianBytes(horizontal,count:4),u(1),u(0),u(1)]))
                let hvcc = makeBox("hvcC", payload: [1,2,3])
                var entry = Bytes(repeating: 0, count: 86)
                try! writeBytes(u(entry.count + clap.count + hvcc.count), into: &entry, at: 0)
                try! writeBytes(Bytes("hvc1".utf8), into: &entry, at: 4)
                try! writeBytes(bigEndianBytes(160,count:2) + bigEndianBytes(128,count:2), into: &entry, at: 32)
                description = entry + clap + hvcc
            }
            let sd = makeBox("stsd", payload: [0,0,0,0] + u(1) + description)
            let stts = makeBox("stts", payload: concatenated([[0,0,0,0],u(1),u(sizes.count),u(100)]))
            let stsc = makeBox("stsc", payload: concatenated([[0,0,0,0],u(1),u(1),u(sizes.count),u(1)]))
            let stsz = makeBox("stsz", payload: concatenated([[0,0,0,0],u(0),u(sizes.count)] + sizes.map(u)))
            let stco = makeBox("stco", payload: concatenated([[0,0,0,0],u(1),u(offset)]))
            let stbl = makeBox("stbl", payload: sd + stts + stsc + stsz + stco)
            let hdlr = makeBox("hdlr", payload: Bytes(repeating:0,count:8) + Bytes(kind.utf8))
            var header = Bytes(repeating: 0,count:84)
            try! writeBytes(u(id),into:&header,at:12)
            return makeBox("trak", payload: makeBox("tkhd",payload:header)
                + makeBox("mdia", payload:hdlr + makeBox("minf",payload:stbl)))
        }
        let media = makeBox("mdat", payload:[1,2,3,4,5,6])
        let moov = makeBox("moov", payload:track("vide",id:1,offset:8,sizes:[1,2])
                           + track("soun",id:2,offset:11,sizes:[3]))
        return Data(media + moov + (trailingMedia ? makeBox("mdat",payload:[7]) : []))
    }

    func testReadsSignedCleanAperture() throws {
        let aperture = try LivePhotoVideo.cleanAperture(of: movie(horizontal: -4))
        XCTAssertEqual(aperture.width,160)
        XCTAssertEqual(aperture.cleanWidth,144)
        XCTAssertEqual(aperture.horizontalOffset,-4)
        XCTAssertTrue(aperture.needsNormalization)
    }

    func testRejectsMalformedAndOutOfBoundsCrop() {
        XCTAssertThrowsError(try LivePhotoVideo.cleanAperture(of: movie(denominator:0)))
        XCTAssertThrowsError(try LivePhotoVideo.cleanAperture(of: movie(horizontal:20)))
    }

    func testReplacementPreservesAudioAndSampleTimeline() throws {
        for trailing in [false,true] {
            let original = movie(trailingMedia:trailing)
            let encoded = LivePhotoVideo.LinearThumbnail(samples:[Data([9]),Data([8,7])],hvcC:Data([5,6]),syncSamples:[0])
            let output = try LivePhotoVideo.replacingMainVideo(in:original,with:encoded)
            XCTAssertFalse(try LivePhotoVideo.cleanAperture(of:output).needsNormalization)
            let before = try Movie(original.stylePortBytes), after = try Movie(output.stylePortBytes)
            let audioBefore = try XCTUnwrap(before.tracks().first { try before.handler($0) == "soun" })
            let audioAfter = try XCTUnwrap(after.tracks().first { try after.handler($0) == "soun" })
            XCTAssertEqual(try before.samples(audioBefore),try after.samples(audioAfter))
            XCTAssertEqual(try before.sampleDeltas(before.mainVideo()),try after.sampleDeltas(after.mainVideo()))
            XCTAssertEqual(try after.samples(after.mainVideo()),[[9],[8,7]])
            XCTAssertEqual(after.boxes.last?.type,"moov")
        }
    }

    func testReplacementRejectsFrameLoss() {
        XCTAssertThrowsError(try LivePhotoVideo.replacingMainVideo(in:movie(),with:
            .init(samples:[Data([9])],hvcC:Data([1]),syncSamples:[0])))
    }
}
