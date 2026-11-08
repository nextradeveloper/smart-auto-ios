import CoreGraphics
import XCTest
@testable import SmartAuto

/// The software encoder must produce what the 368G plays: Baseline level 3.1 with MediaCodec's
/// NAL headers, SPS and PPS in front of every key frame.
final class SoftwareVideoEncoderTests: XCTestCase {
    func testKeyFrameIsBaseline31WithParameterSets() throws {
        let encoder = try XCTUnwrap(SoftwareVideoEncoder(width: 1280, height: 528, bitRate: 1_500_000, frameRate: 10))
        let context = try XCTUnwrap(encoder.makeContext())
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 100, y: 100, width: 400, height: 200))

        let key = try XCTUnwrap(encoder.encode(context, keyFrame: true))
        XCTAssertEqual(H264NAL.headers(inAnnexB: key), [0x67, 0x68, 0x65])
        let sps = try XCTUnwrap(H264NAL.units(inAnnexB: key).first)
        XCTAssertEqual(Array(sps.prefix(4)), [0x67, 66, 0x00, 31]) // Baseline, no constraints, level 3.1

        context.fill(CGRect(x: 600, y: 100, width: 100, height: 100))
        let next = try XCTUnwrap(encoder.encode(context, keyFrame: false))
        XCTAssertEqual(H264NAL.headers(inAnnexB: next).map { $0 & 0x1F }, [1])
        XCTAssertLessThan(next.count, key.count)
    }

    func testUnitsSplitsThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65, 0xCC, 0xDD])
        XCTAssertEqual(H264NAL.units(inAnnexB: stream), [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65, 0xCC, 0xDD])])
    }
}
