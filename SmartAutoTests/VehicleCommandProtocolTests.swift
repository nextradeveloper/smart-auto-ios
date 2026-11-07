import XCTest
@testable import SmartAuto

final class VehicleCommandProtocolTests: XCTestCase {
    func testOfficial112PacketVector() throws {
        let packets = try LegacyRemoteProtocol.makePackets(
            commandPrefix: "*ULoc",
            userCode: "USER123",
            deviceID: "DEVICE123",
            mcuID: "12345678901234567890123456789012",
            pkeCode: "PKE123",
            nonce: "89012345",
            timestamp: "20260909123456"
        )

        XCTAssertEqual(
            String(decoding: packets.authentication, as: UTF8.self),
            "*UL,USER123,DEVICE123,0.0,0.0#"
        )
        XCTAssertEqual(
            String(decoding: packets.command, as: UTF8.self),
            "*ULoc,USER123,PKE123,89012345,9c9daac6552669de14122912ba529af0"
        )
    }
}
