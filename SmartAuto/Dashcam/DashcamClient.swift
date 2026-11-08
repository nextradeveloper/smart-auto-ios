import Foundation

/// The bike's camera unit (front and rear), on the bike's Wi-Fi at 192.168.3.1:7686.
///
/// The official ZONTES app (1.12, DVRActivity and its fragments) talks to it with JSON POSTs to the
/// root URL: VIDEO.DATE / VIDEO.TIME / VIDEO.INFO.LIST per camera ("front", "rear"),
/// PICTURE.INFO.LIST, LOG.FILE.LIST. There is no live view: a probe of every likely port, RTSP and
/// HTTP path and JSON method (2026-11-08) found none, and 8081 is the dash's firmware-update port.
struct DashcamClient {
    static let host = "192.168.3.1"
    static let base = URL(string: "http://192.168.3.1:7686")!

    enum Camera: String, CaseIterable, Identifiable {
        case front, rear
        var id: String { rawValue }
        var title: String { self == .front ? "หน้า" : "หลัง" }
    }

    struct Video: Identifiable, Hashable {
        let title: String
        let name: String
        let playURL: URL
        let thumbURL: URL?
        var id: String { playURL.absoluteString }
    }

    struct Picture: Identifiable, Hashable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    // MARK: Recordings

    func dates(_ camera: Camera) async throws -> [String] {
        let json = try await Self.call(["METHOD": "VIDEO.DATE", "previewType": camera.rawValue])
        return Self.strings(json["dateList"], key: "date")
    }

    func times(_ camera: Camera, date: String) async throws -> [String] {
        let json = try await Self.call(["METHOD": "VIDEO.TIME", "date": date, "previewType": camera.rawValue])
        return Self.strings(json["timeBeanList"], key: "time")
    }

    func videos(_ camera: Camera, date: String, time: String) async throws -> [Video] {
        let json = try await Self.call(["METHOD": "VIDEO.INFO.LIST", "date": date, "time": time, "index": 0,
                                        "num": 120, "previewType": camera.rawValue, "sort": "des"])
        return Self.objects(json["videoBeanList"]).compactMap { item in
            guard let play = Self.url(item["playUrl"]) else { return nil }
            return Video(title: item["title"] as? String ?? "", name: item["name"] as? String ?? "",
                         playURL: play, thumbURL: Self.url(item["thumbUrl"]))
        }
    }

    func pictures() async throws -> [Picture] {
        let json = try await Self.call(["METHOD": "PICTURE.INFO.LIST", "index": 0, "num": 100,
                                        "previewType": "all", "sort": "des"])
        return Self.objects(json["pictureBeanList"]).compactMap { Self.url($0["pictureUrl"]).map(Picture.init) }
    }

    /// Downloads a recording or photo to a temporary file named like the original.
    func download(_ url: URL) async throws -> URL {
        let (temporary, response) = try await Self.session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ZontesError.message("ดาวน์โหลดไม่สำเร็จ") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    // MARK: Wire

    static func call(_ body: [String: Any]) async throws -> [String: Any] {
        let method = body["METHOD"] as? String ?? "?"
        let raw: Data
        do {
            raw = try await post(body)
        } catch {
            EventLog.record("CAM", "\(method) failed: \(error.localizedDescription)")
            throw error
        }
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            EventLog.record("CAM", "\(method) unreadable reply: \(String(decoding: raw.prefix(300), as: UTF8.self))")
            throw ZontesError.message("กล้องตอบกลับไม่ถูกต้อง")
        }
        Reply.logOnce(method, raw)
        return json
    }

    /// The first reply to each method, so a log shows the camera's real format.
    private enum Reply {
        private static let lock = NSLock()
        private static var seen: Set<String> = []

        static func logOnce(_ method: String, _ raw: Data) {
            lock.lock()
            let first = seen.insert(method).inserted
            lock.unlock()
            if first { EventLog.record("CAM", "\(method) reply: \(String(decoding: raw.prefix(500), as: UTF8.self))") }
        }
    }

    /// A list of strings however the camera writes it: strings, numbers, or objects carrying `key`.
    private static func strings(_ value: Any?, key: String) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            switch item {
            case let text as String:
                if text.hasPrefix("{"), let data = text.data(using: .utf8),
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    return object[key].map { "\($0)" }
                }
                return text
            case let number as NSNumber:
                return number.stringValue
            case let object as [String: Any]:
                return object[key].map { "\($0)" }
            default:
                return nil
            }
        }
    }

    static func post(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ZontesError.message("กล้องไม่ตอบ") }
            return data
        } catch let error as ZontesError {
            throw error
        } catch {
            throw ZontesError.message("ติดต่อกล้องไม่ได้ ต่อ Wi-Fi ของรถก่อน")
        }
    }

    /// The camera returns lists either as JSON objects or as JSON strings of objects.
    private static func objects(_ value: Any?) -> [[String: Any]] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            if let object = item as? [String: Any] { return object }
            if let text = item as? String, let data = text.data(using: .utf8) {
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            return nil
        }
    }

    /// The camera writes "192.168.3.1:7686/..." without a scheme, or a path.
    private static func url(_ value: Any?) -> URL? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        if text.hasPrefix("/") { text = base.absoluteString + text }
        if !text.contains("://") { text = "http://" + text }
        return URL(string: text.replacingOccurrences(of: " ", with: "%20"))
    }
}
