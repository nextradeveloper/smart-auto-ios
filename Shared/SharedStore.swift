import Foundation

/// Quality presets: a multiplier on the profile's 2.5 Mbps, like the Android app's setting.
enum VideoQuality: String, CaseIterable, Identifiable {
    case low, normal, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: return "ต่ำ (ลื่นกว่า)"
        case .normal: return "ปกติ"
        case .high: return "สูง (คมกว่า)"
        }
    }
    var multiplier: Double {
        switch self {
        case .low: return 0.7
        case .normal: return 1.0
        case .high: return 1.6
        }
    }
}

/// Where the extension is in its life, written by the extension and shown by the app.
enum BroadcastState: String, Codable {
    case idle
    case searching
    case connecting
    case waitingForDash
    case streaming
    case reconnecting
    case failed
    case stopped

    var title: String {
        switch self {
        case .idle: return "ยังไม่เริ่ม"
        case .searching: return "กำลังหาจอรถ"
        case .connecting: return "กำลังเชื่อมต่อจอ"
        case .waitingForDash: return "รอจอขอภาพ"
        case .streaming: return "กำลังส่งภาพขึ้นจอ"
        case .reconnecting: return "กำลังเชื่อมต่อใหม่"
        case .failed: return "เชื่อมต่อไม่สำเร็จ"
        case .stopped: return "หยุดส่งภาพแล้ว"
        }
    }
}

struct BroadcastStatus: Codable {
    var state: BroadcastState
    var message: String
    var framesSent: Int
    var fps: Int
    var width: Int
    var height: Int
    var updatedAt: Date

    static let idle = BroadcastStatus(
        state: .idle, message: "", framesSent: 0, fps: 0, width: 0, height: 0, updatedAt: .distantPast
    )
}

/// Settings and status shared through the app group. Every accessor tolerates a missing group
/// (an unsigned build has none) by falling back to the standard defaults and a temp directory.
enum SharedStore {
    private static let defaults: UserDefaults =
        UserDefaults(suiteName: AppConstants.appGroup) ?? .standard

    private static let containerURL: URL =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup)
            ?? FileManager.default.temporaryDirectory

    // MARK: Settings (app -> extension)

    static var profileID: String {
        get { defaults.string(forKey: "profileID") ?? DashProfile.zontesG.id }
        set { defaults.set(newValue, forKey: "profileID") }
    }

    static var quality: VideoQuality {
        get { VideoQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "quality") }
    }

    /// Turns the picture 180 degrees, for the case the landscape guess comes out upside down.
    static var flipPicture: Bool {
        get { defaults.bool(forKey: "flipPicture") }
        set { defaults.set(newValue, forKey: "flipPicture") }
    }

    /// Dash IPv4 address; empty means "the Wi-Fi gateway", which is the dash on its own AP.
    static var dashAddressOverride: String {
        get { defaults.string(forKey: "dashAddressOverride") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "dashAddressOverride") }
    }

    /// The wake-probe identity the dash acknowledged last time; tried first next time.
    static var acceptedProbeIdentity: String? {
        get { defaults.string(forKey: "acceptedProbeIdentity") }
        set { defaults.set(newValue, forKey: "acceptedProbeIdentity") }
    }

    // MARK: Status (extension -> app)

    private static var statusURL: URL { containerURL.appendingPathComponent("status.json") }

    static func writeStatus(_ status: BroadcastStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: statusURL, options: .atomic)
    }

    static func readStatus() -> BroadcastStatus {
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? JSONDecoder().decode(BroadcastStatus.self, from: data) else {
            return .idle
        }
        return status
    }

    // MARK: Log

    static var logURL: URL { containerURL.appendingPathComponent("smartauto.log") }
}

/// A small append-only log in the app group, readable and shareable from the app.
enum EventLog {
    private static let queue = DispatchQueue(label: "smartauto.log")
    private static let maxBytes = 512 * 1024
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func record(_ tag: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)\n"
        NSLog("SmartAuto [%@] %@", tag, message)
        queue.async {
            let url = SharedStore.logURL
            let fm = FileManager.default
            if let attributes = try? fm.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int, size > maxBytes {
                // Keep the newer half so a long ride does not lose its ending.
                if let data = try? Data(contentsOf: url) {
                    try? data.suffix(maxBytes / 2).write(to: url, options: .atomic)
                }
            }
            guard let bytes = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(bytes)
                try? handle.close()
            } else {
                try? bytes.write(to: url, options: .atomic)
            }
        }
    }

    static func read() -> String {
        (try? String(contentsOf: SharedStore.logURL, encoding: .utf8)) ?? ""
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: SharedStore.logURL) }
    }
}
