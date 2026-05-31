import XCTest
@testable import HardwareDecoderCore

final class IDRIndexTests: XCTestCase {

    func testBuildSkipsNonFrameNALs() {
        // Mock NAL stream: SPS, PPS, IDR, P, P, SEI, IDR, P
        let units: [(payload: Data, nalUnitType: UInt8)] = [
            (Data(), 7), (Data(), 8),                // not counted
            (Data(), 5),                              // IDR @ frame 0
            (Data(), 1), (Data(), 1),                 // P frames 1, 2
            (Data(), 6),                              // SEI, not counted
            (Data(), 5),                              // IDR @ frame 3
            (Data(), 1),                              // P frame 4
        ]
        let index = IDRIndex.build(nalUnits: units, fps: 30.0)
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index[0].frameIndex, 0)
        XCTAssertEqual(index[0].nalUnitOffset, 2)
        XCTAssertEqual(index[1].frameIndex, 3)
        XCTAssertEqual(index[1].nalUnitOffset, 6)
    }

    func testNearestIDRBeforeFirstReturnsNil() {
        let entries = [
            IDREntry(frameIndex: 30, nalUnitOffset: 32, estimatedTs: 1.0),
            IDREntry(frameIndex: 60, nalUnitOffset: 64, estimatedTs: 2.0),
        ]
        XCTAssertNil(IDRIndex.nearestIDR(at: 0.5, in: entries))
    }

    func testNearestIDRPicksLargestLEQ() {
        let entries = [
            IDREntry(frameIndex: 0, nalUnitOffset: 2, estimatedTs: 0.0),
            IDREntry(frameIndex: 30, nalUnitOffset: 35, estimatedTs: 1.0),
            IDREntry(frameIndex: 60, nalUnitOffset: 70, estimatedTs: 2.0),
        ]
        XCTAssertEqual(IDRIndex.nearestIDR(at: 1.7, in: entries)?.frameIndex, 30)
        XCTAssertEqual(IDRIndex.nearestIDR(at: 2.0, in: entries)?.frameIndex, 60)
        XCTAssertEqual(IDRIndex.nearestIDR(at: 999, in: entries)?.frameIndex, 60)
    }

    func testFromProbeMetaRoundtrip() {
        let raw: [[String: Any]] = [
            ["frame_idx": 0, "nalu_offset": 3, "ts": 0.0],
            ["frame_idx": 90, "nalu_offset": 95, "ts": 3.0],
        ]
        let entries = IDRIndex.fromProbeMeta(raw, fps: 30.0)
        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(entries?[1].frameIndex, 90)
        XCTAssertEqual(entries?[1].nalUnitOffset, 95)
        XCTAssertEqual(entries?[1].estimatedTs ?? 0, 3.0, accuracy: 0.0001)
    }

    func testFromProbeMetaRejectsMalformed() {
        let bad: [[String: Any]] = [["frame_idx": "x"]]
        XCTAssertNil(IDRIndex.fromProbeMeta(bad, fps: 30))
    }
}
