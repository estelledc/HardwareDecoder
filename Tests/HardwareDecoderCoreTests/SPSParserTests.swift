import XCTest
@testable import HardwareDecoderCore

final class SPSParserTests: XCTestCase {

    /// Ground-truth values for 1.h264 captured from ffprobe:
    ///   width=852 height=480 profile=High(100) level=30 chroma=420
    func testParseRealStreamMetadata() throws {
        let path = fixturesPath("1.h264")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let units = H264Stream.parse(data)
        let (sps, _) = H264Stream.extractSPSPPS(from: units)
        guard let sps = sps else {
            XCTFail("SPS missing in fixture")
            return
        }
        // SPS payload includes the NAL header byte; SPSParser handles that.
        guard let info = H264SPSParser.parse(sps) else {
            XCTFail("SPS parse returned nil")
            return
        }
        XCTAssertEqual(info.profileIdc, 100, "Expected High profile")
        XCTAssertEqual(info.levelIdc, 30, "Expected level 3.0")
        XCTAssertEqual(info.width, 852, "Cropped luma width")
        XCTAssertEqual(info.height, 480, "Cropped luma height")
        XCTAssertEqual(info.chromaFormatIdc, 1, "4:2:0 chroma")
        XCTAssertGreaterThan(info.numRefFrames, 0)
    }

    func testParseFailsOnTooShortInput() {
        // Below the minimum 4-byte profile/level prefix — must return nil.
        XCTAssertNil(H264SPSParser.parse(Data([0x67])))
        XCTAssertNil(H264SPSParser.parse(Data()))
    }

    private func fixturesPath(_ name: String) -> String {
        // Resource bundle lays out copied fixtures under Fixtures/.
        let bundleDir = Bundle.module.bundleURL.appendingPathComponent("Fixtures")
        let candidate = bundleDir.appendingPathComponent(name).path
        return candidate
    }
}
