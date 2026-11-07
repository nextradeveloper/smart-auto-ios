import Foundation
import Network
import UIKit

@_silgen_name("CCCrypt")
private func commonCrypt(
    _ operation: UInt32,
    _ algorithm: UInt32,
    _ options: UInt32,
    _ key: UnsafeRawPointer?,
    _ keyLength: Int,
    _ iv: UnsafeRawPointer?,
    _ dataIn: UnsafeRawPointer?,
    _ dataInLength: Int,
    _ dataOut: UnsafeMutableRawPointer?,
    _ dataOutAvailable: Int,
    _ dataOutMoved: UnsafeMutablePointer<Int>?
) -> Int32

final class VehicleCommandClient {
    static let shared = VehicleCommandClient()

    private init() {}

    func send(
        _ command: VehicleCommand,
        session: ZontesSession,
        vehicle: VehicleSnapshot
    ) async throws {
        let pkeCode = vehicle.carCode.isEmpty ? session.carCode : vehicle.carCode
        let mcuID = vehicle.mcuID.isEmpty ? session.mcuID : vehicle.mcuID
        guard !session.userCode.isEmpty, !pkeCode.isEmpty else {
            throw ZontesError.missingVehicle
        }

        let prefix: String
        let responseCode: String
        switch command {
        case .lock:
            prefix = "*ULoc"
            responseCode = "1"
        case .unlock:
            prefix = "*UClear"
            responseCode = "2"
        case .find:
            prefix = "*UF"
            responseCode = "3"
        case .seat, .fuelLid:
            throw ZontesError.message("คำสั่งนี้ต้องเชื่อมต่อ Bluetooth กับรถ")
        }

        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let packets = try LegacyRemoteProtocol.makePackets(
            commandPrefix: prefix,
            userCode: session.userCode,
            deviceID: deviceID,
            mcuID: mcuID,
            pkeCode: pkeCode
        )

        try await withCheckedThrowingContinuation { continuation in
            let operation = PendingVehicleCommand(
                authentication: packets.authentication,
                command: packets.command,
                responseCode: responseCode,
                continuation: continuation
            )
            operation.start()
        }
    }
}

struct LegacyRemotePackets {
    let authentication: Data
    let command: Data
}

enum LegacyRemoteProtocol {
    private static let applicationKey = Data("TAYOBTa1YCWc2gTS".utf8)

    static func makePackets(
        commandPrefix: String,
        userCode: String,
        deviceID: String,
        mcuID: String,
        pkeCode: String,
        nonce: String? = nil,
        timestamp: String? = nil
    ) throws -> LegacyRemotePackets {
        guard [userCode, deviceID, pkeCode].allSatisfy(isValidField) else {
            throw ZontesError.invalidVehicleKey
        }
        let proof = try makeProof(
            mcuID: mcuID,
            nonce: nonce ?? randomNonce(),
            timestamp: timestamp ?? currentTimestamp()
        )
        return LegacyRemotePackets(
            authentication: Data("*UL,\(userCode),\(deviceID),0.0,0.0#".utf8),
            command: Data("\(commandPrefix),\(userCode),\(pkeCode),\(proof)".utf8)
        )
    }

    private static func makeProof(mcuID: String, nonce: String, timestamp: String) throws -> String {
        guard let mcuBytes = Data(hex: mcuID), mcuBytes.count == 16,
              let nonceBytes = Data(hex: nonce), nonceBytes.count == 4,
              nonce.utf8.count == 8,
              nonce.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              timestamp.utf8.count == 14,
              timestamp.utf8.allSatisfy({ (48 ... 57).contains($0) })
        else { throw ZontesError.invalidVehicleKey }

        let encryptedMCU = try aesECBEncrypt(mcuBytes, key: applicationKey)
        var derivedKey = [UInt8](encryptedMCU)
        for index in 0 ..< 4 {
            derivedKey[12 + index] ^= nonceBytes[index]
        }

        var timeBlock = Data(timestamp.utf8)
        timeBlock.append(contentsOf: [0, 0])
        let encryptedTime = try aesECBEncrypt(timeBlock, key: Data(derivedKey))
        return nonce + "," + encryptedTime.hexString
    }

    static func aesECBEncrypt(_ input: Data, key: Data) throws -> Data {
        guard key.count == 16, input.count.isMultiple(of: 16) else {
            throw ZontesError.invalidVehicleKey
        }
        let outputCapacity = input.count + 16
        var output = Data(count: outputCapacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    commonCrypt(
                        0,
                        0,
                        2,
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        inputBytes.baseAddress,
                        input.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &moved
                    )
                }
            }
        }
        guard status == 0 else { throw ZontesError.invalidVehicleKey }
        output.removeSubrange(moved ..< output.count)
        return output
    }

    private static func randomNonce() -> String {
        (0 ..< 8).map { _ in String(Int.random(in: 0 ... 9)) }.joined()
    }

    private static func currentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }

    private static func isValidField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (0x21 ... 0x7e).contains($0) && $0 != 0x2c && $0 != 0x23
        }
    }
}

private final class PendingVehicleCommand {
    private let queue = DispatchQueue(label: "smartauto.zontes.command")
    private let connection = NWConnection(
        host: NWEndpoint.Host("www.sharpon.com"),
        port: NWEndpoint.Port(rawValue: 4510)!,
        using: .tcp
    )
    private let authentication: Data
    private let command: Data
    private let responseCode: String
    private let continuation: CheckedContinuation<Void, Error>
    private let finishLock = NSLock()
    private var finished = false
    private var commandSubmitted = false
    private var responseBuffer = ""

    init(
        authentication: Data,
        command: Data,
        responseCode: String,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.authentication = authentication
        self.command = command
        self.responseCode = responseCode
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveResponses()
                self.sendAuthenticationThenCommand()
            case let .failed(error):
                self.finish(.failure(error))
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.finish(.failure(ZontesError.commandTimedOut))
        }
    }

    private func sendAuthenticationThenCommand() {
        connection.send(content: authentication, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }

            // The official 1.12 client writes the command immediately after the
            // login frame. Waiting for a newer *BR frame makes this protocol stall.
            self.commandSubmitted = true
            self.connection.send(content: self.command, completion: .contentProcessed { [weak self] error in
                if let error { self?.finish(.failure(error)) }
            })
        })
    }

    private func receiveResponses() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            if let data, !data.isEmpty {
                self.responseBuffer += String(decoding: data, as: UTF8.self)
                self.consumeCompleteFrames()
            }
            if !isComplete, !self.finished {
                self.receiveResponses()
            } else if isComplete, !self.finished {
                self.finish(.failure(ZontesError.commandConnectionClosed))
            }
        }
    }

    private func consumeCompleteFrames() {
        if responseBuffer.count > 65_536 {
            finish(.failure(ZontesError.invalidResponse))
            return
        }

        while let terminator = responseBuffer.firstIndex(of: "#") {
            let raw = String(responseBuffer[...terminator])
            responseBuffer.removeSubrange(...terminator)
            guard let start = raw.lastIndex(of: "*") else { continue }
            let fields = raw[start...]
                .dropLast()
                .split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            guard commandSubmitted,
                  fields.count == 3,
                  fields[0] == "*AO",
                  fields[1] == responseCode
            else { continue }

            finish(fields[2] == "1" ? .success(()) : .failure(ZontesError.commandRejected))
            return
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        finishLock.lock()
        guard !finished else {
            finishLock.unlock()
            return
        }
        finished = true
        finishLock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
