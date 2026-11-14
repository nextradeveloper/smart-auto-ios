import XCTest
@testable import SmartAuto

/// Pairing by QR code, for ZONTES Smart releases without email accounts. All identities are made up.
@MainActor
final class VehiclePairingTests: XCTestCase {
    private let label = "125;001;ZT00TESTPKE00001;1;2;3;4;00112233445566778899aabbccddeeff;520990000000001"

    /// Encrypted by Python's `cryptography` (AES-256-CBC, zero IV, PKCS7, key zero-padded), as the
    /// official app's share screen does; the label inside is the one above.
    private let shareCode = #"{ "type" : "ZontesShare", "motoData" : "SbQI0+RT9BJB+/Q80WECcfMDlB+oEnGYujYq1kY8y8154/cloMuozU4itnBCi4bFDIftlwd76QWcLxcV4floy+oHRjeUnkl/vuz0h3SyvPpfn3nOKStgAe6VntRdqawVXPM/AKaAbMD9s5CLUwx7USHr8sc2LaNWKYb9gUmb4YhQU27lq8H0bvWxfS1C6NdSBzJkGkUux/KyZCJ0tDQ8cQ=="}"#

    func testPKELabelGivesPKECodeAndMCUID() throws {
        let code = try VehiclePairingCode.parse(" \(label)\n")
        XCTAssertEqual(code.pkeCode, "ZT00TESTPKE00001")
        XCTAssertEqual(code.mcuID, "00112233445566778899AABBCCDDEEFF")
        XCTAssertEqual(code.imsi, "520990000000001")
    }

    func testShareCodeFromOfficialAppDecrypts() throws {
        XCTAssertEqual(try VehiclePairingCode.parse(shareCode), try VehiclePairingCode.parse(label))
    }

    func testOtherCodesAreRejected() {
        let rejected = [
            "",
            "https://www.zontes.com",
            "125;001;ZT00TESTPKE00001;1;2", // too few fields
            "125;001;ZT00TESTPKE00001;1;2;3;4;NOT-HEX-0123456789ABCDEF012345;5", // MCU ID not hex
            "125;001;;1;2;3;4;00112233445566778899AABBCCDDEEFF;5", // no PKE code
            #"{"type":"ZontesShare","motoData":"bm90IGVuY3J5cHRlZA=="}"#,
        ]
        for text in rejected {
            XCTAssertThrowsError(try VehiclePairingCode.parse(text), text)
        }
    }

    func testPairedVehicleIsBluetoothOnlyAndNeverAsksTheCloud() async throws {
        var cloudCalls = 0
        let session = try VehiclePairingCode.parse(label).session
        XCTAssertTrue(session.isBluetoothOnly)

        let model = ZontesAppModel(session: session, automaticallyRefresh: true, sessionClearer: {}) { _ in
            cloudCalls += 1
            throw ZontesError.authenticationRequired
        }
        XCTAssertEqual(model.vehicle?.carCode, "ZT00TESTPKE00001")
        XCTAssertEqual(model.vehicle?.mcuID, "00112233445566778899AABBCCDDEEFF")

        await model.refresh()
        await model.refreshQuietly()
        XCTAssertEqual(cloudCalls, 0)
        XCTAssertNotNil(model.session, "no account means nothing can sign the owner out")
        XCTAssertNil(model.message)
    }
}
