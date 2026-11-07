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
        let carCode = vehicle.carCode.isEmpty ? session.carCode : vehicle.carCode
        let mcuID = vehicle.mcuID.isEmpty ? session.mcuID : vehicle.mcuID
        guard !session.userCode.isEmpty, !carCode.isEmpty else {
            throw ZontesError.missingVehicle
        }

        let proof = try CommandProof.make(mcuID: mcuID)
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
        }
        let payload = "\(prefix),\(session.userCode),\(carCode),\(proof)"
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let handshake = "*UL,\(session.userCode),\(deviceID),0.0,0.0#"

        try await withCheckedThrowingContinuation { continuation in
            let operation = PendingVehicleCommand(
                handshake: handshake,
                payload: payload,
                responseCode: responseCode,
                continuation: continuation
            )
            operation.start()
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
    private let handshake: Data
    private let payload: Data
    private let responseCode: String
    private let continuation: CheckedContinuation<Void, Error>
    private let lock = NSLock()
    private var finished = false
    private var responseBuffer = ""

    init(
        handshake: String,
        payload: String,
        responseCode: String,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.handshake = Data(handshake.utf8)
        self.payload = Data(payload.utf8)
        self.responseCode = responseCode
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveResponses()
                self.sendHandshake()
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

    private func sendHandshake() {
        connection.send(content: handshake, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.sendCommand()
            }
        })
    }

    private func sendCommand() {
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
            }
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
        while let terminator = responseBuffer.firstIndex(of: "#") {
            let frame = String(responseBuffer[...terminator])
            responseBuffer.removeSubrange(...terminator)
            let fields = frame
                .dropLast()
                .split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 3,
                  fields[0] == "*AO",
                  fields[1] == responseCode
            else { continue }

            if fields[2] == "1" {
                finish(.success(()))
            } else {
                finish(.failure(ZontesError.commandRejected))
            }
            return
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}

private enum CommandProof {
    private static let applicationKey = Data("TAYOBTa1YCWc2gTS".utf8)

    static func make(mcuID: String) throws -> String {
        let cleanMCU = mcuID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mcuBytes = Data(hex: cleanMCU), mcuBytes.count == 16 else {
            throw ZontesError.invalidVehicleKey
        }

        let nonceText = (0 ..< 8).map { _ in String(Int.random(in: 0 ... 9)) }.joined()
        guard let nonce = Data(hex: nonceText), nonce.count == 4 else {
            throw ZontesError.invalidVehicleKey
        }
        let encryptedMCU = try aesECBEncrypt(mcuBytes, key: applicationKey)
        guard encryptedMCU.count == 16 else { throw ZontesError.invalidVehicleKey }

        var derivedKey = Data(encryptedMCU.prefix(12))
        for index in 0 ..< 4 {
            derivedKey.append(encryptedMCU[12 + index] ^ nonce[index])
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
        formatter.dateFormat = "yyyyMMddHHmmss"

        var timestamp = Data(repeating: 0, count: 16)
        let timeBytes = Data(formatter.string(from: Date()).utf8)
        timestamp.replaceSubrange(0 ..< min(14, timeBytes.count), with: timeBytes.prefix(14))
        let encryptedTime = try aesECBEncrypt(timestamp, key: derivedKey)
        return nonceText + "," + encryptedTime.hexString
    }

    private static func aesECBEncrypt(_ input: Data, key: Data) throws -> Data {
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
        if moved < output.count {
            output.removeSubrange(moved ..< output.count)
        }
        return output
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
