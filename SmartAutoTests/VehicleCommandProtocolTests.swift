import XCTest
@testable import SmartAuto

final class VehicleCommandProtocolTests: XCTestCase {
    func testLegacyBluetoothFactoryPasswordPacket() throws {
        for action in ["1", "2", "5", "6"] {
            let packet = try LegacyBluetoothProtocol.packet(
                action: action,
                pke: "123456789000123",
                mcu: "12345678901234567890123456789012",
                challenge: "12345678",
                password: "000123"
            )
            XCTAssertEqual(String(decoding: packet, as: UTF8.self),
                           "*BT,123456789000123,10,001,\(action),238cafd4a6d060389c3e6bd751b04a43#")
        }
        XCTAssertThrowsError(try LegacyBluetoothProtocol.packet(action: "1", pke: "123456789000123", mcu: "bad", challenge: "12345678", password: "000123"))
    }
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
