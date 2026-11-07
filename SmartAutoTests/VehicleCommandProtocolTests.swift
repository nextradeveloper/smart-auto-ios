import XCTest
@testable import SmartAuto

final class VehicleCommandProtocolTests: XCTestCase {
    func testLegacyBluetoothResponsesWithVoltageAndStatus() {
        let pke = "123456789000123"
        func parse(_ frame: String, action: String = "1", challenge: Bool = true) -> LegacyBluetoothProtocol.Response {
            let fields = frame.dropLast().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return LegacyBluetoothProtocol.response(fields: fields, pke: pke, action: action, awaitingChallenge: challenge)
        }
        XCTAssertEqual(parse("*AT,\(pke),10,008,89ABCDEF,126#"), .challenge("89ABCDEF"))
        XCTAssertEqual(parse("*AT,\(pke),10,008,89ABCDEF#"), .challenge("89ABCDEF"))
        XCTAssertEqual(parse("*AT,OTHER,10,008,89ABCDEF,126#"), .ignored)
        XCTAssertEqual(parse("*AT,\(pke),10,008,XYZ,126#"), .ignored)
        XCTAssertEqual(parse("*AT,\(pke),10,001,1,1#", challenge: false), .acknowledged)
        XCTAssertEqual(parse("*AT,\(pke),10,001,1,0#", challenge: false), .rejected)
        XCTAssertEqual(parse("*AT,\(pke),10,001,2,1#", challenge: false), .ignored)
        XCTAssertEqual(parse("*AT,\(pke),10,001,1,1,126#", challenge: false), .acknowledged)
        XCTAssertEqual(parse("*AT,\(pke),10,001,6,0#", action: "6", challenge: false), .rejected)
        XCTAssertEqual(parse("*AT,\(pke),10,001,7,1#", action: "6", challenge: false), .ignored)
    }

    func testLegacyBluetoothReadings() {
        let pke = "123456789000123"
        func read(_ frame: String) -> LegacyBluetoothProtocol.Reading? {
            let fields = frame.dropLast().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return LegacyBluetoothProtocol.reading(fields: fields, pke: pke)
        }
        XCTAssertEqual(read("*AT,\(pke),10,008,89ABCDEF,126#"), LegacyBluetoothProtocol.Reading(voltage: 12.6))
        XCTAssertEqual(read("*AT,\(pke),10,008,89ABCDEF,131,1#"), LegacyBluetoothProtocol.Reading(voltage: 13.1))
        XCTAssertNil(read("*AT,\(pke),10,008,89ABCDEF#"))
        XCTAssertNil(read("*AT,\(pke),10,008,89ABCDEF,0#"))
        XCTAssertEqual(read("*AT,\(pke),10,001,7,1#"), LegacyBluetoothProtocol.Reading(locked: true))
        XCTAssertEqual(read("*AT,\(pke),10,001,7,2#"), LegacyBluetoothProtocol.Reading(locked: false))
        XCTAssertNil(read("*AT,\(pke),10,001,1,1#"))
        XCTAssertNil(read("*AT,OTHER,10,001,7,1#"))
    }

    // Vectors from the official 1.12 vf9.a(), reimplemented outside the app: the
    // Bluetooth password is part of the key.
    func testLegacyBluetoothPasswordPacket() throws {
        let pke = "123456789000123"
        let mcu = "12345678901234567890123456789012"
        for action in ["1", "6"] {
            let packet = try LegacyBluetoothProtocol.packet(action: action, pke: pke, mcu: mcu, challenge: "12345678", password: "135790")
            XCTAssertEqual(String(decoding: packet, as: UTF8.self),
                           "*BT,\(pke),10,001,\(action),6c022e77839dcbf88e11afd0556729dc#")
        }
        let upper = try LegacyBluetoothProtocol.packet(action: "2", pke: pke, mcu: mcu, challenge: "89ABCDEF", password: "135790")
        XCTAssertEqual(String(decoding: upper, as: UTF8.self),
                       "*BT,\(pke),10,001,2,de0b9eaaaa81e0e2b3f1a535aaaf04ab#")
        XCTAssertThrowsError(try LegacyBluetoothProtocol.packet(action: "7", pke: pke, mcu: mcu, challenge: "12345678", password: "135790"))

        let fixed = try LegacyBluetoothProtocol.packet(action: "1", pke: pke, mcu: mcu, challenge: "12345678", password: LegacyBluetoothProtocol.password)
        XCTAssertEqual(String(decoding: fixed, as: UTF8.self),
                       "*BT,\(pke),10,001,1,6ce19362ae5a0b4008b471b4a4707bf8#")
    }

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
