import Foundation

/// The vehicle identity in a ZONTES Smart pairing QR code. Newer ZONTES Smart releases no longer
/// sign in with an email account: the official app binds a vehicle by scanning the QR code of its
/// PKE module and keeps the vehicle on the phone. That code carries the PKE code and MCU ID,
/// which is all Bluetooth control needs (official 1.12 `BindMotorActivity`, `MotorInfoAdapter`).
struct VehiclePairingCode: Equatable {
    let pkeCode: String
    let mcuID: String
    let imsi: String

    /// The official app's share code: `{"type":"ZontesShare","motoData":"<Base64>"}`, where the
    /// data is AES-256-CBC (zero IV, PKCS7) under this key padded with zeros to 32 bytes.
    static let shareKey = "TAYOBTa1YCWc2gTS"

    static let invalidCode = ZontesError.message(
        "QR Code นี้ไม่ใช่รหัสผูกรถ ZONTES กรุณาสแกน QR Code บนกล่องกุญแจ (PKE) ของรถ หรือ QR แชร์รถจากแอป ZONTES Smart"
    )

    static func parse(_ text: String) throws -> VehiclePairingCode {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("ZontesShare") { return try parseShare(text) }
        return try parseLabel(text)
    }

    /// The PKE label: fields separated by `;`. Index 2 is the PKE code, 7 the MCU ID, 8 the IMSI
    /// (0 and 1 are the firmware and hardware versions).
    private static func parseLabel(_ text: String) throws -> VehiclePairingCode {
        let fields = text.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count >= 8 else { throw invalidCode }
        let pke = fields[2]
        let mcu = fields[7].uppercased()
        guard !pke.isEmpty, pke.count <= 64,
              mcu.count == 32, mcu.allSatisfy(\.isHexDigit)
        else { throw invalidCode }
        return VehiclePairingCode(pkeCode: pke, mcuID: mcu,
                                  imsi: fields.count > 8 ? fields[8] : "")
    }

    private static func parseShare(_ text: String) throws -> VehiclePairingCode {
        guard let outer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let wrapped = outer["motoData"] as? String,
              let sealed = Data(base64Encoded: wrapped, options: .ignoreUnknownCharacters),
              let plain = try? LegacyRemoteProtocol.aesCBC(sealed, key: shareKeyData, encrypt: false),
              let inner = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let label = inner["scanData"] as? String
        else { throw invalidCode }
        return try parseLabel(label)
    }

    static var shareKeyData: Data {
        var key = Data(shareKey.utf8.prefix(32))
        key.append(Data(count: 32 - key.count))
        return key
    }

    /// A session with no account behind it: Bluetooth control only.
    var session: ZontesSession {
        ZontesSession(account: "", userCode: "", signCode: "", accessToken: "", tokenTime: "",
                      carCode: pkeCode, mcuID: mcuID, imsi: imsi, isOwner: true)
    }
}

extension ZontesSession {
    /// Paired from a QR code rather than signed in, so there is no ZONTES account or cloud data.
    var isBluetoothOnly: Bool { accessToken.isEmpty }
}

extension VehicleSnapshot {
    /// What the phone knows about a vehicle paired by QR code. Fuel, range and tyres come only
    /// from the ZONTES cloud; lock state and battery come over Bluetooth.
    static func bluetoothOnly(_ session: ZontesSession) -> VehicleSnapshot {
        VehicleSnapshot(carCode: session.carCode, mcuID: session.mcuID, name: "", remarkName: "",
                        imageURL: nil, isOnline: false, isLocked: nil, fuelPercent: nil,
                        rangeKilometers: nil, batteryVoltage: nil, frontTireKPa: nil,
                        rearTireKPa: nil, maintenanceKilometers: nil, satelliteCount: nil,
                        updatedAt: "", location: nil)
    }
}
