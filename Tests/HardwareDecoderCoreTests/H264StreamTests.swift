import XCTest
@testable import HardwareDecoderCore

final class H264StreamTests: XCTestCase {

    func testParseAnnexBSingleStartCode() {
        // 3-byte start code (00 00 01) followed by NAL header type=7 (SPS)
        let stream = Data([0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E,
                           0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80])
        let units = H264Stream.parse(stream)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].nalUnitType, 7)
        XCTAssertEqual(units[1].nalUnitType, 8)
    }

    func testParseAnnexBDualStartCode() {
        // mix of 4-byte (00 00 00 01) and 3-byte (00 00 01) start codes
        let stream = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E,
                           0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80,
                           0x00, 0x00, 0x00, 0x01, 0x65, 0x88])
        let units = H264Stream.parse(stream)
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units.map { $0.nalUnitType }, [7, 8, 5])
    }

    func testExtractSPSPPS() throws {
        let path = fixturesPath("1.h264")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let units = H264Stream.parse(data)
        let (sps, pps) = H264Stream.extractSPSPPS(from: units)
        XCTAssertNotNil(sps)
        XCTAssertNotNil(pps)
        // First byte of SPS is the NAL header with type=7 (forbidden=0, ref=3, type=7 → 0x67).
        XCTAssertEqual(sps!.first! & 0x1F, 7)
        XCTAssertEqual(pps!.first! & 0x1F, 8)
    }

    func testFixForbiddenBit() {
        var data = Data([0xE7, 0x42, 0x00])  // forbidden_bit=1
        H264Stream.fixForbiddenBit(&data)
        XCTAssertEqual(data[0], 0x67)        // forbidden_bit cleared
    }

    func testFixForbiddenBitNoOpWhenZero() {
        var data = Data([0x67, 0x42, 0x00])
        H264Stream.fixForbiddenBit(&data)
        XCTAssertEqual(data[0], 0x67)
    }

    private func fixturesPath(_ name: String) -> String {
        let bundleDir = Bundle.module.bundleURL.appendingPathComponent("Fixtures")
        return bundleDir.appendingPathComponent(name).path
    }
}
