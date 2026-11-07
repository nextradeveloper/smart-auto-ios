import Foundation
import Network

/// Where the EasyConn init goes, and which package name the dash accepted in the wake probe.
struct DashEndpoint: Equatable {
    let host: String
    let port: UInt16
    let probePackage: String
}

enum LocateFailure: Error, CustomStringConvertible {
    case noWifiAddress
    case noAcknowledgement(host: String, lastError: String)
    case cancelled

    var description: String {
        switch self {
        case .noWifiAddress:
            return "iPhone ยังไม่ได้ต่อ Wi-Fi ของจอรถ (ไม่พบที่อยู่ IPv4 บน Wi-Fi)"
        case let .noAcknowledgement(host, lastError):
            return "จอที่ \(host) ไม่ตอบ (\(lastError)) ตรวจว่า iPhone ต่อ Wi-Fi ZT_... ของรถอยู่ และเปิดสิทธิ์ Local Network ให้ Smart Auto แล้ว"
        case .cancelled:
            return "ยกเลิกแล้ว"
        }
    }
}

/// Finds the dash the way the Android app does for the Zontes 368G: the dash is the gateway of
/// its own Wi-Fi AP, it never advertises over mDNS, and it answers an EasyConn "wake probe" on
/// TCP 10930. The package name it acknowledges there is the one the EC init must carry.
/// (Android: RideDaemonTransport.sendEasyConnWakeProbe, EasyConnClientIdentity, TBoxPeerAddress.)
enum DashLocator {
    /// Android's ladder, in its order. The first one is the identity proven on real dashes.
    static let probeIdentities = [
        "com.cfmoto.cfmotointernational",
        "net.easyconn.easyride.wws",
        "net.easyconn.carman",
        "com.carbit.easyconnect",
    ]

    private static let cmdProbe: UInt32 = 0x7000_0010
    private static let cmdProbeAck: UInt32 = 0x7000_0011
    private static let headerSize = 16

    /// Blocking; call it off the main thread.
    static func locate(
        log: (String) -> Void,
        isCancelled: () -> Bool = { false }
    ) -> Result<DashEndpoint, LocateFailure> {
        let override = SharedStore.dashAddressOverride
        let host: String
        if !override.isEmpty {
            host = override
            log("Dash address from settings: \(host)")
        } else if let gateway = wifiGatewayGuess() {
            host = gateway
            log("Dash address guessed from Wi-Fi subnet: \(host)")
        } else {
            return .failure(.noWifiAddress)
        }

        var order = probeIdentities
        if let accepted = SharedStore.acceptedProbeIdentity, order.contains(accepted) {
            order.removeAll { $0 == accepted }
            order.insert(accepted, at: 0)
        }

        var lastError = "no answer"
        for (position, identity) in order.enumerated() {
            let attempts = position == 0 ? 3 : 1
            for attempt in 1...attempts {
                if isCancelled() { return .failure(.cancelled) }
                switch probe(host: host, port: AppConstants.easyConnPort, identity: identity) {
                case .acknowledged:
                    log("Dash acknowledged the wake probe as \"\(identity)\" (attempt \(attempt)/\(attempts)).")
                    SharedStore.acceptedProbeIdentity = identity
                    return .success(DashEndpoint(host: host, port: AppConstants.easyConnPort, probePackage: identity))
                case let .noAnswer(reason), let .failed(reason):
                    lastError = reason
                    log("Wake probe as \"\(identity)\" attempt \(attempt)/\(attempts): \(reason)")
                }
                if attempt < attempts { Thread.sleep(forTimeInterval: 1) }
            }
        }
        return .failure(.noAcknowledgement(host: host, lastError: lastError))
    }

    // MARK: Wi-Fi address

    /// The `.1` of the Wi-Fi subnet, which is the dash on its own access point.
    static func wifiGatewayGuess() -> String? {
        guard let (address, mask) = wifiIPv4() else { return nil }
        guard mask != 0, mask != 0xFFFF_FFFF else { return nil }
        let gateway = (address & mask) | 1
        guard gateway != address else { return nil }
        return format(gateway)
    }

    static func wifiIPv4() -> (UInt32, UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard String(cString: entry.pointee.ifa_name) == "en0",
                  let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.pointee.ifa_netmask else { continue }
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            // Skip link-local (169.254/16): that is "no DHCP", not a dash network.
            if address >> 16 == 0xA9FE { continue }
            return (address, mask)
        }
        return nil
    }

    static func wifiAddressDescription() -> String {
        guard let (address, mask) = wifiIPv4() else { return "ไม่มี" }
        return "\(format(address)) / \(format(mask))"
    }

    private static func format(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    // MARK: Wake probe

    enum ProbeOutcome {
        case acknowledged
        case noAnswer(String)
        case failed(String)
    }

    static func probeFrame(identity: String) -> Data {
        let body = Data("{\"phoneType\":\"Android\",\"packageName\":\"\(identity)\"}".utf8)
        let total = UInt32(headerSize + body.count)
        var frame = Data()
        for value in [cmdProbe, total, cmdProbe ^ total, 0] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { frame.append(contentsOf: $0) }
        }
        frame.append(body)
        return frame
    }

    static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start])
            | UInt32(data[start + 1]) << 8
            | UInt32(data[start + 2]) << 16
            | UInt32(data[start + 3]) << 24
    }

    /// One probe: connect (3 s), send the frame, read the 16-byte header and its body (5 s).
    static func probe(host: String, port: UInt16, identity: String) -> ProbeOutcome {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failed("bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)

        let queue = DispatchQueue(label: "smartauto.probe")
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var finished = false
        var outcome: ProbeOutcome = .noAnswer("timeout")

        func finish(_ result: ProbeOutcome) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            outcome = result
            done.signal()
        }

        func readAck() {
            connection.receive(minimumIncompleteLength: headerSize, maximumLength: headerSize) { header, _, _, error in
                if let error { finish(.failed("read: \(error)")); return }
                guard let header, header.count == headerSize else {
                    finish(.noAnswer("closed without an answer")); return
                }
                let cmd = readUInt32LE(header, 0)
                let total = readUInt32LE(header, 4)
                let magic = readUInt32LE(header, 8)
                guard cmd == cmdProbeAck, cmd ^ total == magic else {
                    finish(.noAnswer(String(format: "unexpected reply cmd=0x%08X", cmd))); return
                }
                let bodyLength = Int(total) - headerSize
                guard bodyLength > 0, bodyLength < 64 * 1024 else {
                    finish(.noAnswer("empty acknowledgement")); return
                }
                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, _, _, error in
                    if let error { finish(.failed("read body: \(error)")); return }
                    let text = String(decoding: body ?? Data(), as: UTF8.self)
                    finish(text.contains("true") ? .acknowledged : .noAnswer("refused: \(text)"))
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: probeFrame(identity: identity), completion: .contentProcessed { error in
                    if let error { finish(.failed("send: \(error)")); return }
                    readAck()
                })
            case let .waiting(error):
                finish(.failed("\(error)"))
            case let .failed(error):
                finish(.failed("\(error)"))
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = done.wait(timeout: .now() + 9)
        connection.cancel()
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}
