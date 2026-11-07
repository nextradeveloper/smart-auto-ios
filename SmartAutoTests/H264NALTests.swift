import XCTest
@testable import SmartAuto

final class H264NALTests: XCTestCase {
    func testVideoToolboxHeadersBecomeMediaCodecHeaders() {
        XCTAssertEqual(H264NAL.normalizedHeader(0x27), 0x67) // SPS, nal_ref_idc 1
        XCTAssertEqual(H264NAL.normalizedHeader(0x28), 0x68) // PPS
        XCTAssertEqual(H264NAL.normalizedHeader(0x25), 0x65) // IDR slice
        XCTAssertEqual(H264NAL.normalizedHeader(0x21), 0x41) // referenced slice
        XCTAssertEqual(H264NAL.normalizedHeader(0x01), 0x01) // non-referenced slice stays so
        XCTAssertEqual(H264NAL.normalizedHeader(0x67), 0x67)
        XCTAssertNil(H264NAL.normalizedHeader(0x06)) // SEI
        XCTAssertNil(H264NAL.normalizedHeader(0x09)) // access unit delimiter
    }

    func testAppendAnnexBRewritesHeaderAndDropsSEI() {
        var unit = Data()
        H264NAL.appendAnnexB(Data([0x27, 0x42, 0xC0, 0x1F]), to: &unit)
        H264NAL.appendAnnexB(Data([0x06, 0x05, 0x10]), to: &unit)
        H264NAL.appendAnnexB(Data([0x25, 0x88, 0x84]), to: &unit)
        XCTAssertEqual(unit, Data([0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x1F, 0, 0, 0, 1, 0x65, 0x88, 0x84]))
        XCTAssertEqual(H264NAL.headers(inAnnexB: unit), [0x67, 0x65])
    }
}
